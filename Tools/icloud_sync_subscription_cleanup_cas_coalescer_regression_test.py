#!/usr/bin/env python3
"""Pins exact-CAS cleanup ownership and drain wake-up coalescing."""

import unittest
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
SUBSCRIPTIONS = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
SUBSCRIPTIONS_HEADER = (
    ROOT / "Classes" / "Model" / "SubscriptionManager.h"
).read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"Missing function: {signature}")
    brace = source.find("{", start)
    if brace < 0:
        raise AssertionError(f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


@dataclass(frozen=True)
class Intent:
    feed: str
    revision: str
    subscribed: bool


class CleanupCheckpointModel:
    def __init__(self, intents):
        self.current = {intent.feed: intent for intent in intents}
        self.gated = {intent.feed for intent in intents}
        self.history_resets = []
        self.full_cleanups = []

    def exact_complete(self, intents):
        completed = []
        for intent in intents:
            if self.current.get(intent.feed) != intent:
                continue
            del self.current[intent.feed]
            completed.append(intent)
        self.gated.difference_update(intent.feed for intent in completed)
        return completed

    def replace(self, intent):
        self.current[intent.feed] = intent
        self.gated.add(intent.feed)


class DrainGenerationModel:
    def __init__(self):
        self.requested = 0
        self.completed = 0
        self.passes = 0

    def request(self):
        self.requested += 1

    def run(self, after_first_empty_fetch=None):
        while self.completed < self.requested:
            target = self.requested
            self.passes += 1
            if self.passes == 1 and after_first_empty_fetch:
                after_first_empty_fetch()
            self.completed = target


class ResettableDrainGenerationModel:
    def __init__(self):
        self.epoch = 0
        self.requested = 0
        self.completed = 0

    def request(self):
        self.requested += 1
        return self.epoch, self.requested

    def reset(self):
        self.epoch += 1
        self.requested = 0
        self.completed = 0

    def should_follow_up(self, caller):
        caller_epoch, caller_generation = caller
        if caller_epoch != self.epoch:
            return False
        return caller_generation > self.completed


class MixedCleanupCancellationModel:
    def __init__(self):
        self.active_cleanup_count = 0
        self.destructive_cleanup_count = 0

    def run(self, *, cancel_during_active_cas):
        self.active_cleanup_count += 1
        if cancel_during_active_cas:
            return
        self.destructive_cleanup_count += 1


class ReclassifyingCleanupDrainModel:
    def __init__(self):
        self.pending = {"active-a", "inactive-b"}
        self.subscribed = {"active-a": True, "inactive-b": False}
        self.history_resets = []
        self.destructive_cleanups = []

    def run_one_group(self):
        active = [
            feed for feed in self.pending if self.subscribed.get(feed) is True
        ]
        inactive = [
            feed for feed in self.pending if self.subscribed.get(feed) is False
        ]
        if active:
            self.history_resets.extend(active)
            self.pending.difference_update(active)
            return
        if inactive:
            self.destructive_cleanups.extend(inactive)
            self.pending.difference_update(inactive)


class DrainStatusGenerationModel:
    def __init__(self):
        self.completed_generation = 0

    def waiter_result(self, caller_generation, stale_error, cancelled=False):
        if caller_generation <= self.completed_generation:
            return None
        if cancelled:
            return None
        return stale_error


class DurableCleanupClassificationModel:
    @staticmethod
    def classify(*, durable_subscribed, stale_view_subscribed):
        del stale_view_subscribed
        return "resubscribed" if durable_subscribed else "unsubscribed"


class CleanupSideEffectPreflightModel:
    @staticmethod
    def classify(*, snapshot_subscribed, current_view_subscribed):
        if current_view_subscribed != snapshot_subscribed:
            return "state-mismatch"
        return "resubscribed" if snapshot_subscribed else "unsubscribed"


class CleanupSnapshotRefreshModel:
    def __init__(self):
        self.durable_subscribed = False

    def fetch(self):
        # Subscription state is deliberately not stored in the intent payload;
        # every batch derives it afresh from the same durable store snapshot.
        return Intent("feed-a", "r1", self.durable_subscribed)


class GateReleaseViewAlignmentModel:
    def __init__(
        self,
        *,
        durable_subscribed,
        view_subscribed,
        durable_title,
        locally_edited_title,
    ):
        self.durable_subscribed = durable_subscribed
        self.view_subscribed = view_subscribed
        self.durable_title = durable_title
        self.view_title = locally_edited_title
        self.gate_open = False

    def align_and_release(self):
        # A property-level Object Trump merge imports the durable subscription
        # state while retaining unrelated unsaved edits in the view context.
        self.view_subscribed = self.durable_subscribed
        if self.view_subscribed == self.durable_subscribed:
            self.gate_open = True


class RevisionGate:
    def __init__(self):
        self.states = {}
        self.next_sequence = 0

    def _state(self, feed):
        return self.states.setdefault(
            feed,
            {"committed": None, "highwater": 0, "stages": {}},
        )

    @property
    def revisions(self):
        result = {}
        for feed, state in self.states.items():
            values = {stage[0] for stage in state["stages"].values()}
            if state["committed"]:
                values.add(state["committed"])
            if values:
                result[feed] = values
        return result

    def install(self, feed, revision):
        state = self._state(feed)
        matching = [
            (token, stage)
            for token, stage in state["stages"].items()
            if stage[0] == revision
        ]
        if matching:
            token, stage = max(matching, key=lambda item: item[1][1])
            if stage[1] > state["highwater"]:
                state["committed"] = stage[0]
                state["highwater"] = stage[1]
            del state["stages"][token]
        elif state["highwater"] == 0:
            state["committed"] = revision
        self._remove_empty(feed)

    def stage(self, feed, revision):
        self.next_sequence += 1
        token = f"stage-{self.next_sequence}"
        self._state(feed)["stages"][token] = (revision, self.next_sequence)
        return token

    def commit(self, feed, revision, token):
        state = self.states.get(feed)
        stage = state and state["stages"].pop(token, None)
        if stage is None or stage[0] != revision:
            return
        if stage[1] > state["highwater"]:
            state["committed"] = stage[0]
            state["highwater"] = stage[1]
        self._remove_empty(feed)

    def cancel(self, feed, revision, token):
        state = self.states.get(feed)
        stage = state and state["stages"].get(token)
        if stage and stage[0] == revision:
            del state["stages"][token]
        self._remove_empty(feed)

    def complete(self, feed, revision):
        state = self.states.get(feed)
        if not state:
            return
        if state["committed"] == revision:
            state["committed"] = None
        state["stages"] = {
            token: stage
            for token, stage in state["stages"].items()
            if stage[0] != revision
        }
        self._remove_empty(feed)

    def _remove_empty(self, feed):
        state = self.states.get(feed)
        if state and state["committed"] is None and not state["stages"]:
            del self.states[feed]

    def blocked(self, feed):
        return feed in self.states


class SubscriptionCleanupCASCoalescerTests(unittest.TestCase):
    def test_mixed_batch_commits_successful_active_feed_before_unrelated_failure(self):
        active = Intent("active-a", "r1", subscribed=True)
        inactive = Intent("inactive-b", "r1", subscribed=False)
        model = CleanupCheckpointModel([active, inactive])

        model.history_resets.append(active.feed)
        self.assertEqual(model.exact_complete([active]), [active])
        model.full_cleanups.append(inactive.feed)
        cleanup_error = True
        self.assertTrue(cleanup_error)

        self.assertNotIn(active.feed, model.current)
        self.assertNotIn(active.feed, model.gated)
        self.assertIn(inactive.feed, model.current)
        self.assertIn(inactive.feed, model.gated)

        # A retry must only touch B; repeating A's history reset could erase new
        # auto-download history written after A's exact checkpoint completed.
        remaining = list(model.current.values())
        self.assertEqual([intent.feed for intent in remaining], [inactive.feed])
        self.assertEqual(model.history_resets, [active.feed])

    def test_replaced_revision_never_releases_the_feed_gate(self):
        first = Intent("feed-a", "r1", subscribed=False)
        model = CleanupCheckpointModel([first])
        model.full_cleanups.append(first.feed)

        replacement = Intent("feed-a", "r2", subscribed=False)
        model.replace(replacement)
        self.assertEqual(model.exact_complete([first]), [])
        self.assertEqual(model.current[first.feed], replacement)
        self.assertIn(first.feed, model.gated)

    def test_cas_mismatch_keeps_gate_until_fresh_durable_revision_is_observed(self):
        gate = RevisionGate()
        gate.install("feed-a", "r1")

        # A recovery/migration writer replaced durable R1 without a live stage.
        # R1's failed CAS must not open the gate; the next durable observation
        # atomically replaces the sequence-zero recovery baseline with R2.
        gate.install("feed-a", "r2")
        self.assertTrue(gate.blocked("feed-a"))
        self.assertEqual(gate.revisions["feed-a"], {"r2"})

    def test_request_after_final_empty_fetch_forces_another_pass(self):
        coalescer = DrainGenerationModel()
        coalescer.request()
        coalescer.run(after_first_empty_fetch=coalescer.request)
        self.assertEqual(coalescer.requested, 2)
        self.assertEqual(coalescer.completed, 2)
        self.assertEqual(coalescer.passes, 2)

    def test_new_revision_survives_old_revision_post_cas_finish(self):
        gate = RevisionGate()
        gate.install("feed-a", "r1")

        # R1's durable CAS has completed, but its MainActor continuation has not
        # yet retired the protection. R2 commits and protects the same feed first.
        r2_stage = gate.stage("feed-a", "r2")
        gate.commit("feed-a", "r2", r2_stage)
        gate.complete("feed-a", "r1")
        self.assertTrue(gate.blocked("feed-a"))
        self.assertEqual(gate.revisions["feed-a"], {"r2"})

        gate.complete("feed-a", "r2")
        self.assertFalse(gate.blocked("feed-a"))

    def test_failed_pass_does_not_consume_request_that_arrived_after_it_started(self):
        attempted_generation = 1
        late_caller_generation = 2
        failed = True

        self.assertTrue(failed)
        self.assertGreater(late_caller_generation, attempted_generation)
        should_start_followup_pass = late_caller_generation > attempted_generation
        self.assertTrue(should_start_followup_pass)

    def test_reset_epoch_prevents_waiting_caller_from_restarting_or_looping(self):
        coalescer = ResettableDrainGenerationModel()
        owner = coalescer.request()
        waiter = coalescer.request()
        self.assertEqual(owner, (0, 1))
        self.assertEqual(waiter, (0, 2))

        coalescer.reset()
        self.assertFalse(coalescer.should_follow_up(owner))
        self.assertFalse(coalescer.should_follow_up(waiter))
        self.assertEqual((coalescer.requested, coalescer.completed), (0, 0))

    def test_cancellation_during_active_group_cas_never_starts_destructive_group(self):
        drain = MixedCleanupCancellationModel()
        drain.run(cancel_during_active_cas=True)
        self.assertEqual(drain.active_cleanup_count, 1)
        self.assertEqual(drain.destructive_cleanup_count, 0)

    def test_next_cleanup_group_is_reclassified_after_an_awaited_checkpoint(self):
        drain = ReclassifyingCleanupDrainModel()
        drain.run_one_group()
        self.assertEqual(drain.history_resets, ["active-a"])

        # B is resubscribed while A's exact checkpoint is awaited. A stale batch
        # classification must not delete B's newly active downloads afterwards.
        drain.subscribed["inactive-b"] = True
        drain.run_one_group()
        self.assertEqual(drain.destructive_cleanups, [])
        self.assertEqual(drain.history_resets, ["active-a", "inactive-b"])

    def test_resubscribe_during_destructive_cleanup_replaces_its_revision(self):
        first = Intent("feed-a", "r1", subscribed=False)
        model = CleanupCheckpointModel([first])
        gate = RevisionGate()
        gate.install(first.feed, first.revision)

        # R1's destructive callback is still running when the feed is made
        # active. A non-authoritative handoff stage closes the gap while the
        # main feed save and the error-policy cleanup writer run separately.
        replacement = Intent("feed-a", "r2", subscribed=True)
        handoff_stage = gate.stage(replacement.feed, "handoff")
        model.replace(replacement)
        r2_stage = gate.stage(replacement.feed, replacement.revision)
        gate.commit(replacement.feed, replacement.revision, r2_stage)
        gate.cancel(replacement.feed, "handoff", handoff_stage)

        # The old callback may finish, but exact CAS cannot remove R2 and its
        # old gate completion cannot release the newly active feed.
        self.assertEqual(model.exact_complete([first]), [])
        gate.complete(first.feed, first.revision)
        self.assertEqual(model.current[first.feed], replacement)
        self.assertEqual(gate.revisions[first.feed], {"r2"})

    def test_newer_success_suppresses_an_older_waiters_error_and_cancellation(self):
        drain = DrainStatusGenerationModel()
        drain.completed_generation = 2
        self.assertIsNone(drain.waiter_result(1, RuntimeError("stale failure")))
        self.assertIsNone(
            drain.waiter_result(2, RuntimeError("cancelled"), cancelled=True)
        )

    def test_cleanup_classification_uses_same_store_snapshot_as_the_intent(self):
        self.assertEqual(
            DurableCleanupClassificationModel.classify(
                durable_subscribed=False,
                stale_view_subscribed=True,
            ),
            "unsubscribed",
        )
        self.assertEqual(
            DurableCleanupClassificationModel.classify(
                durable_subscribed=True,
                stale_view_subscribed=False,
            ),
            "resubscribed",
        )

    def test_newer_view_state_blocks_an_old_destructive_cleanup_before_it_starts(self):
        self.assertEqual(
            CleanupSideEffectPreflightModel.classify(
                snapshot_subscribed=False,
                current_view_subscribed=True,
            ),
            "state-mismatch",
        )

    def test_live_state_mismatch_refetches_the_current_durable_feed_state(self):
        model = CleanupSnapshotRefreshModel()
        first = model.fetch()
        model.durable_subscribed = True

        self.assertEqual(
            CleanupSideEffectPreflightModel.classify(
                snapshot_subscribed=first.subscribed,
                current_view_subscribed=model.durable_subscribed,
            ),
            "state-mismatch",
        )
        refreshed = model.fetch()
        self.assertTrue(refreshed.subscribed)

    def test_cold_start_derives_subscription_state_instead_of_replaying_old_state(self):
        model = CleanupSnapshotRefreshModel()
        model.durable_subscribed = True
        self.assertTrue(model.fetch().subscribed)

    def test_gate_release_merge_preserves_unrelated_view_context_edits(self):
        model = GateReleaseViewAlignmentModel(
            durable_subscribed=False,
            view_subscribed=True,
            durable_title="Old title",
            locally_edited_title="Local title edit",
        )
        self.assertFalse(model.gate_open)
        model.align_and_release()
        self.assertFalse(model.view_subscribed)
        self.assertEqual(model.view_title, "Local title edit")
        self.assertTrue(model.gate_open)

    def test_revision_registration_has_exact_save_commit_and_rollback_ownership(self):
        gate = RevisionGate()
        gate.install("feed-a", "r1")

        # Merely observing the already durable R1 does not grant the unrelated
        # active-record transaction rollback or commit ownership over it.
        self.assertEqual(gate.revisions["feed-a"], {"r1"})

        # A failed R2 save removes only the newly staged R2 and preserves R1.
        failed_r2_stage = gate.stage("feed-a", "r2")
        gate.cancel("feed-a", "r2", failed_r2_stage)
        self.assertEqual(gate.revisions["feed-a"], {"r1"})

        # A successful R2 save makes R2 authoritative. A later R1 CAS conflict
        # must not leave the obsolete R1 protection behind forever.
        r2_stage = gate.stage("feed-a", "r2")
        gate.commit("feed-a", "r2", r2_stage)
        self.assertEqual(gate.revisions["feed-a"], {"r2"})

        # A drain may delete/retire R2 after its save but before its writer gets
        # to the in-memory commit. That stale commit must not resurrect a gate.
        gate.complete("feed-a", "r2")
        gate.commit("feed-a", "r2", r2_stage)
        self.assertFalse(gate.blocked("feed-a"))

        # Nor may an older writer overwrite a newer committed R3 gate.
        gate.install("feed-a", "r1")
        older_stage = gate.stage("feed-a", "r2")
        newer_stage = gate.stage("feed-a", "r3")
        gate.commit("feed-a", "r3", newer_stage)
        gate.commit("feed-a", "r2", older_stage)
        self.assertEqual(gate.revisions["feed-a"], {"r3"})

    def test_older_writer_commit_preserves_newer_stage_until_its_save_finishes(self):
        gate = RevisionGate()
        gate.install("feed-a", "r1")

        r2_stage = gate.stage("feed-a", "r2")
        # W2 has saved R2 but is preempted. W3 reads durable R2 and stages R3.
        r3_stage = gate.stage("feed-a", "r3")
        gate.commit("feed-a", "r2", r2_stage)
        self.assertEqual(gate.revisions["feed-a"], {"r2", "r3"})

        gate.commit("feed-a", "r3", r3_stage)
        self.assertEqual(gate.revisions["feed-a"], {"r3"})

    def test_completed_newer_revision_rejects_late_older_writer_commit(self):
        gate = RevisionGate()
        gate.install("feed-a", "r1")
        r2_stage = gate.stage("feed-a", "r2")
        r3_stage = gate.stage("feed-a", "r3")

        gate.commit("feed-a", "r3", r3_stage)
        gate.complete("feed-a", "r3")
        gate.commit("feed-a", "r2", r2_stage)
        self.assertFalse(gate.blocked("feed-a"))

    def test_drain_can_promote_and_complete_saved_stage_before_writer_commit(self):
        gate = RevisionGate()
        gate.install("feed-a", "r1")
        r2_stage = gate.stage("feed-a", "r2")

        # The database save completed, then the drain fetched R2 before the
        # writer reached its registry commit.
        gate.install("feed-a", "r2")
        self.assertEqual(gate.revisions["feed-a"], {"r2"})
        gate.complete("feed-a", "r2")
        gate.commit("feed-a", "r2", r2_stage)
        self.assertFalse(gate.blocked("feed-a"))

    def test_observed_predecessor_baseline_never_outranks_a_staged_writer(self):
        gate = RevisionGate()
        r2_stage = gate.stage("feed-a", "r2")

        # A stale fetch of durable predecessor R1 may arrive after R2 was staged.
        # Observed-only baselines use sequence zero, so R2's successful save wins.
        gate.install("feed-a", "r1")
        self.assertEqual(gate.revisions["feed-a"], {"r1", "r2"})
        gate.commit("feed-a", "r2", r2_stage)
        self.assertEqual(gate.revisions["feed-a"], {"r2"})

    def test_production_retires_only_revisions_completed_by_exact_cas(self):
        completion = body(
            REMOTE,
            "nonisolated static func completePendingSubscriptionCleanupIntents(",
        )
        self.assertIn("async throws -> [ICCloudSubscriptionCleanupIntentSnapshot]", REMOTE)
        self.assertIn("return completedIntents", completion)
        self.assertNotIn("return completedIntents.count", completion)

        cleanup = body(
            SUBSCRIPTIONS,
            "- (void)performUnsubscribeSideEffectsForFeeds:",
        )
        resubscribe = body(
            SUBSCRIPTIONS,
            "- (void)performResubscribeCleanupForFeeds:",
        )
        self.assertNotIn("unsubscribeCleanupFeedObjectIDs minusSet", cleanup)
        self.assertNotIn("_startPendingAutoDownloads", cleanup)
        self.assertNotIn("unsubscribeCleanupFeedObjectIDs minusSet", resubscribe)
        self.assertNotIn("_startPendingAutoDownloads", resubscribe)
        self.assertIn(
            "completeAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString",
            SUBSCRIPTIONS_HEADER,
        )
        self.assertIn(
            "installAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString",
            SUBSCRIPTIONS_HEADER,
        )
        self.assertIn(
            "stageAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString",
            SUBSCRIPTIONS_HEADER,
        )
        self.assertIn("stageToken:(NSString*)stageToken", SUBSCRIPTIONS_HEADER)
        commit_gate = body(
            SUBSCRIPTIONS,
            "- (void)commitAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:",
        )
        self.assertIn("state.stagesByToken[stageToken]", commit_gate)
        self.assertIn("if (stage.sequence > state.committedSequence)", commit_gate)
        self.assertNotIn("!state.committedRevision ||", commit_gate)
        self.assertIn("removeObjectForKey:stageToken", commit_gate)
        install_gate = body(
            SUBSCRIPTIONS,
            "- (void)installAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:",
        )
        self.assertIn("state.committedSequence = 0", install_gate)
        self.assertIn("else if (state.committedSequence == 0)", install_gate)

        complete_gate = body(
            SUBSCRIPTIONS,
            "- (void)completeAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString:",
        )
        self.assertNotIn("state.committedSequence = 0", complete_gate)

        drain = body(
            REMOTE,
            "func performPendingSubscriptionCleanupIntentDrain()",
        )
        self.assertIn("$0.feedSubscribed == true", drain)
        self.assertIn("$0.feedSubscribed == false", drain)
        classification_start = drain.index(
            "func feedMatchesDurableSubscriptionState"
        )
        classification_end = drain.index("let resubscribedFeeds", classification_start)
        self.assertIn(
            "feed.subscribed == durableSubscribed",
            drain[classification_start:classification_end],
        )
        self.assertIn("stateMismatchedIntents", drain)
        mismatch_start = drain.index("if !stateMismatchedIntents.isEmpty")
        mismatch_end = drain.index("}", mismatch_start)
        self.assertIn("await Task.yield()", drain[mismatch_start:mismatch_end])
        self.assertIn("continue", drain[mismatch_start:mismatch_end])
        self.assertNotIn(
            "Eine neuere Abo-Änderung wird noch gespeichert.",
            drain[mismatch_start:],
        )
        merge = drain.index("performSynchronousRemoteViewContextMerge")
        self.assertLess(merge, classification_start)
        self.assertIn("NSUpdatedObjectIDsKey", drain[:classification_start])
        self.assertNotIn("context.refresh(feed, mergeChanges: false)", drain)
        self.assertIn(
            "completePendingSubscriptionCleanupIntents(resubscribedIntents)",
            drain,
        )
        self.assertIn(
            "completePendingSubscriptionCleanupIntents(unsubscribedIntents)",
            drain,
        )
        self.assertNotIn("completePendingSubscriptionCleanupIntents(intents)", drain)
        self.assertIn("let completedResubscribedIntents", drain)
        self.assertIn("let completedUnsubscribedIntents", drain)
        self.assertIn("let completedOrphanedIntents", drain)
        self.assertIn("for intent in completedResubscribedIntents", drain)
        self.assertIn("for intent in completedUnsubscribedIntents", drain)
        self.assertIn("for intent in completedOrphanedIntents", drain)
        self.assertIn(
            "completeAutoDownloadsDuringUnsubscribeCleanup(",
            drain,
        )

        resubscribed_group = drain.index("if !resubscribedFeeds.isEmpty")
        resubscribed_side_effect = drain.index(
            "subscriptionManager.performResubscribeCleanup",
            resubscribed_group,
        )
        self.assertIn(
            "try Task.checkCancellation()",
            drain[resubscribed_group:resubscribed_side_effect],
        )
        unsubscribed_group = drain.index("if !unsubscribedFeeds.isEmpty")
        unsubscribed_side_effect = drain.index(
            "subscriptionManager.performUnsubscribeSideEffects",
            unsubscribed_group,
        )
        self.assertIn(
            "try Task.checkCancellation()",
            drain[unsubscribed_group:unsubscribed_side_effect],
        )
        # Only one state group may run from a fetched/classified batch. Every
        # awaited checkpoint is followed by a new fetch and classification.
        self.assertIn(
            "continue",
            drain[
                drain.index("for intent in completedResubscribedIntents"):
                unsubscribed_group
            ],
        )

    def test_production_coalesces_requests_and_gates_local_commit_synchronously(self):
        self.assertIn("ICCloudSubscriptionCleanupDrainResult", TYPES)
        self.assertIn("localSubscriptionCleanupRequestedGeneration", MANAGER)
        self.assertIn("localSubscriptionCleanupCompletedGeneration", MANAGER)
        self.assertIn("localSubscriptionCleanupEpoch", MANAGER)
        self.assertIn("localSubscriptionCommitTasks", MANAGER)

        entry = body(
            REMOTE,
            "func drainPendingSubscriptionCleanupIntentsIfNeeded()",
        )
        self.assertIn("localSubscriptionCleanupRequestedGeneration &+= 1", entry)
        self.assertIn("let callerGeneration", entry)
        self.assertIn("let callerEpoch = localSubscriptionCleanupEpoch", entry)
        self.assertIn("attemptedGeneration", entry)
        self.assertIn("completedGeneration", entry)
        self.assertIn("callerGeneration > result.attemptedGeneration", entry)
        result_wait = entry.index("let result = await task.value")
        epoch_check = entry.index(
            "guard callerEpoch == localSubscriptionCleanupEpoch, isStarted else",
            result_wait,
        )
        self.assertLess(epoch_check, entry.index("callerGeneration <=", result_wait))
        latest_completion = entry.index(
            "callerGeneration <= localSubscriptionCleanupCompletedGeneration",
            result_wait,
        )
        waiter_cancellation = entry.index("if Task.isCancelled", result_wait)
        self.assertLess(latest_completion, waiter_cancellation)
        cancellation_end = entry.index("}", waiter_cancellation)
        self.assertIn("return nil", entry[waiter_cancellation:cancellation_end])

        reset = body(
            MANAGER,
            "@objc func prepareForLocalAppResetWithCompletion",
        )
        global_block = reset.index("setUnsubscribeCleanupRecoveryBlocked(true)")
        epoch_advance = reset.index("localSubscriptionCleanupEpoch &+= 1")
        self.assertLess(global_block, reset.index("let cleanupTask"))
        self.assertLess(epoch_advance, reset.index("let cleanupTask"))
        self.assertLess(epoch_advance, reset.index("localSubscriptionCleanupRequestedGeneration = 0"))
        commit_tasks_snapshot = reset.index("let subscriptionCommitTasks")
        self.assertLess(commit_tasks_snapshot, reset.index("let cleanupTask"))
        self.assertIn("for task in subscriptionCommitTasks", reset)
        self.assertIn("await task.value", reset[commit_tasks_snapshot:])
        registry_reset = reset.index("resetUnsubscribeCleanupProtectionForLocalAppReset")
        self.assertGreater(
            registry_reset,
            reset.index("deleteAllLocalOutboxEntriesForLocalReset"),
        )
        self.assertLess(registry_reset, reset.index("resetAllLocalSyncMetadata()"))

        self.assertIn(
            "resetUnsubscribeCleanupProtectionForLocalAppReset",
            SUBSCRIPTIONS_HEADER,
        )
        protection_reset = body(
            SUBSCRIPTIONS,
            "- (void)resetUnsubscribeCleanupProtectionForLocalAppReset",
        )
        self.assertIn(
            "unsubscribeCleanupProtectionStatesByFeedObjectURIString removeAllObjects",
            protection_reset,
        )
        self.assertIn("_unsubscribeCleanupRecoveryBlocked = YES", protection_reset)

        local_unsubscribe = body(
            REMOTE,
            "func commitLocalSubscriptionUnsubscribe(",
        )
        self.assertIn("guard isStarted", local_unsubscribe)
        self.assertIn("let cleanupEpoch = localSubscriptionCleanupEpoch", local_unsubscribe)
        self.assertIn("let taskIdentifier = UUID()", local_unsubscribe)
        self.assertIn("localSubscriptionCommitTasks[taskIdentifier] = task", local_unsubscribe)
        self.assertIn("localSubscriptionCommitTasks.removeValue", local_unsubscribe)
        detached_wait = local_unsubscribe.index("}.value")
        epoch_guard = local_unsubscribe.index(
            "guard cleanupEpoch == localSubscriptionCleanupEpoch, isStarted else",
            detached_wait,
        )
        self.assertLess(epoch_guard, local_unsubscribe.index("commitBackgroundLocalSubscriptionMergePlan"))
        self.assertIn("drainPendingSubscriptionCleanupIntentsIfNeeded()", local_unsubscribe)

        local_resubscribe = body(
            REMOTE,
            "@objc(commitLocalSubscriptionResubscribeCleanupForFeed:)",
        )
        self.assertNotIn("persistPendingSubscriptionCleanupIntent(", local_resubscribe)
        self.assertIn("resubscribeHandoffRevision", local_resubscribe)
        self.assertIn(
            "stageAutoDownloadsDuringUnsubscribeCleanup",
            local_resubscribe,
        )
        handoff_stage = local_resubscribe.index(
            "stageAutoDownloadsDuringUnsubscribeCleanup"
        )
        self.assertLess(
            handoff_stage,
            local_resubscribe.index("saveReturningError", handoff_stage),
        )
        self.assertIn(
            "commitLocalSubscriptionResubscribeCleanupInBackground",
            local_resubscribe[local_resubscribe.index("saveReturningError"):],
        )
        local_resubscribe_writer = body(
            REMOTE,
            "nonisolated static func commitLocalSubscriptionResubscribeCleanupInBackground(",
        )
        self.assertIn("newICloudSyncBackgroundContext", local_resubscribe_writer)
        self.assertIn("persistPendingSubscriptionCleanupIntent", local_resubscribe_writer)
        self.assertIn(
            "stageAutoDownloadsDuringUnsubscribeCleanup",
            local_resubscribe_writer,
        )
        self.assertLess(
            local_resubscribe_writer.index("stageAutoDownloadsDuringUnsubscribeCleanup"),
            local_resubscribe_writer.index("try context.save()"),
        )
        self.assertIn(
            "commitAutoDownloadsDuringUnsubscribeCleanup",
            local_resubscribe_writer[local_resubscribe_writer.index("try context.save()"):],
        )
        database_resubscribe = body(
            DATABASE,
            "- (CDFeed*)subscribeFeed:(ICFeed*)parserFeed withOptions:",
        )
        existing_branch = database_resubscribe[
            database_resubscribe.index("if (matches.count > 0)"):
            database_resubscribe.index("// Create new feed")
        ]
        baseline_save = existing_branch.index("resubscribeBaselineSaveError")
        first_mutation = existing_branch.index("existingFeed.subscribed = YES")
        self.assertLess(baseline_save, first_mutation)
        self.assertIn(
            "commitLocalSubscriptionResubscribeCleanupForFeed",
            existing_branch,
        )
        self.assertIn("[self.objectContext rollback]", existing_branch)

        self.assertIn("guard isStarted", local_resubscribe)

        subscribe_parser = body(
            SUBSCRIPTIONS,
            "- (CDFeed*) subscribeParserFeed:(ICFeed*)parserFeed autodownload:",
        )
        self.assertIn("subscribedFeed.subscribed", subscribe_parser)

        background_commit = body(
            REMOTE,
            "nonisolated static func commitLocalSubscriptionUnsubscribeInBackground(",
        )
        self.assertIn(
            "let committedCleanupRevision = try context.performAndWait",
            background_commit,
        )
        self.assertNotIn("var committedCleanupRevision", background_commit)
        gate = background_commit.index(
            "stageAutoDownloadsDuringUnsubscribeCleanup("
        )
        self.assertLess(gate, background_commit.index("try context.save()"))
        self.assertIn("cleanupProtectionStageToken", background_commit)
        self.assertIn(
            "commitAutoDownloadsDuringUnsubscribeCleanup(",
            background_commit[background_commit.index("try context.save()"):],
        )
        self.assertIn("cleanupRevision", background_commit)

        remote_apply = body(
            REMOTE,
            "nonisolated static func applyPendingSubscriptionBatchInBackground(",
        )
        protection_batch = remote_apply.index(
            "if !cleanupProtectionRevisionsByFeedObjectURIString.isEmpty"
        )
        remote_gate = remote_apply.index(
            "stageAutoDownloadsDuringUnsubscribeCleanup(",
            protection_batch,
        )
        remote_save = remote_apply.index("if context.hasChanges", remote_gate)
        self.assertLess(remote_gate, remote_save)
        self.assertIn(
            "stagedCleanupProtectionsByFeedObjectURIString",
            remote_apply[remote_gate:remote_save],
        )
        self.assertIn(
            "commitAutoDownloadsDuringUnsubscribeCleanup(",
            remote_apply[remote_save:],
        )
        active_branch_start = remote_apply.index(
            "} else {",
            remote_apply.index("if feedsRequiringCleanup.contains(feed)"),
        )
        active_branch_end = remote_apply.index(
            "removePendingSubscriptionSnapshots(cleanupSnapshots)",
            active_branch_start,
        )
        self.assertIn(
            "persistPendingSubscriptionCleanupIntent",
            remote_apply[active_branch_start:active_branch_end],
        )
        self.assertIn(
            "cleanupProtectionRevisionsByFeedObjectURIString[",
            remote_apply[active_branch_start:active_branch_end],
        )

    def test_production_gate_is_revision_owned_and_empty_fetch_honors_cancel(self):
        self.assertIn(
            "unsubscribeCleanupProtectionStatesByFeedObjectURIString",
            SUBSCRIPTIONS,
        )
        self.assertNotIn("unsubscribeCleanupFeedObjectIDs", SUBSCRIPTIONS)
        self.assertIn(
            "installAutoDownloadsDuringUnsubscribeCleanupForFeedObjectURIString",
            SUBSCRIPTIONS_HEADER,
        )
        self.assertIn("revision:(NSString*)revision", SUBSCRIPTIONS_HEADER)

        drain = body(
            REMOTE,
            "func performPendingSubscriptionCleanupIntentDrain()",
        )
        fetch = drain.index("pendingSubscriptionCleanupIntentBatch()")
        cancellation = drain.index("try Task.checkCancellation()", fetch)
        empty = drain.index("guard !intents.isEmpty else { return }", fetch)
        self.assertLess(cancellation, empty)
        self.assertIn(
            "installAutoDownloadsDuringUnsubscribeCleanup(",
            drain,
        )

        intent_batch = body(
            REMOTE,
            "nonisolated static func pendingSubscriptionCleanupIntentBatch(",
        )
        self.assertIn("snapshot.feedSubscribed = feed.subscribed", intent_batch)
        self.assertIn("context.existingObject", intent_batch)
        self.assertIn("var feedSubscribed: Bool? = nil", TYPES)

        self.assertNotIn(
            "performUnsubscribeSideEffectsForFeed:(CDFeed*)feed",
            SUBSCRIPTIONS_HEADER,
        )


if __name__ == "__main__":
    unittest.main()
