#!/usr/bin/env python3
"""Pins manual unsubscribe to one durable, retryable background transaction."""

import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
LOCAL_CHANGES = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
SUBSCRIPTIONS_H = (ROOT / "Classes" / "Model" / "SubscriptionManager.h").read_text()
SUBSCRIPTIONS_M = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
FEED_UI = (ROOT / "Classes" / "FeedViewController.m").read_text()
LIST_UI = (ROOT / "Classes" / "SubscriptionsTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


@dataclass
class DurableState:
    subscribed: bool = True
    cleanup_revision: Optional[str] = None
    active_operation: Optional[str] = None
    tombstone_operation: Optional[str] = None


class IsolatedUnsubscribeTransaction:
    def __init__(self, state: DurableState):
        self.state = state
        self.side_effect_calls = 0

    def commit(self, *, save_fails: bool, participated: bool = True) -> bool:
        candidate = DurableState(
            subscribed=False,
            cleanup_revision="cleanup-r1",
            active_operation="delete" if participated else None,
            tombstone_operation="save" if participated else None,
        )
        if save_fails:
            return False
        self.state = candidate
        return True

    def drain_cleanup(self, *, cleanup_fails: bool) -> None:
        if self.state.cleanup_revision is None or self.state.subscribed:
            return
        self.side_effect_calls += 1
        if not cleanup_fails:
            self.state.cleanup_revision = None


class LocalSubscriptionUnsubscribeCheckpointTests(unittest.TestCase):
    def test_save_failure_leaves_every_durable_value_and_side_effect_unchanged(self):
        transaction = IsolatedUnsubscribeTransaction(DurableState())
        self.assertFalse(transaction.commit(save_fails=True))
        transaction.drain_cleanup(cleanup_fails=False)
        self.assertEqual(transaction.state, DurableState())
        self.assertEqual(transaction.side_effect_calls, 0)

    def test_success_survives_kill_and_cleanup_failure_is_retryable(self):
        transaction = IsolatedUnsubscribeTransaction(DurableState())
        self.assertTrue(transaction.commit(save_fails=False))
        self.assertEqual(transaction.state.subscribed, False)
        self.assertEqual(transaction.state.cleanup_revision, "cleanup-r1")
        self.assertEqual(transaction.state.active_operation, "delete")
        self.assertEqual(transaction.state.tombstone_operation, "save")

        # A process death before cleanup changes no durable state. The restarted drain may fail
        # and must retain the exact checkpoint for another retry.
        restarted = IsolatedUnsubscribeTransaction(transaction.state)
        restarted.drain_cleanup(cleanup_fails=True)
        self.assertEqual(restarted.state.cleanup_revision, "cleanup-r1")
        restarted.drain_cleanup(cleanup_fails=False)
        self.assertIsNone(restarted.state.cleanup_revision)
        self.assertEqual(restarted.side_effect_calls, 2)

    def test_production_commits_before_side_effects_and_reports_ui_result(self):
        self.assertIn(
            "- (void)unsubscribeFeed:(CDFeed*)feed completion:(void (^)(NSError* error))completion;",
            SUBSCRIPTIONS_H,
        )
        unsubscribe = body(
            SUBSCRIPTIONS_M,
            "- (void)unsubscribeFeed:(CDFeed*)feed\n           completion:",
        )
        self.assertIn("commitLocalSubscriptionUnsubscribeForFeed:feed", unsubscribe)
        self.assertNotIn("performUnsubscribeSideEffects", unsubscribe)
        self.assertNotIn("[DMANAGER unsubscribeFeed:feed]", unsubscribe)

        worker = body(
            REMOTE,
            "nonisolated static func commitLocalSubscriptionUnsubscribeInBackground(",
        )
        self.assertLess(
            worker.index("feed.subscribed = false"),
            worker.index("persistPendingSubscriptionCleanupIntent"),
        )
        self.assertIn("pendingSnapshots: []", worker)
        self.assertLess(
            worker.index("persistPendingSubscriptionCleanupIntent"),
            worker.index("journalBackgroundSubscriptionChanges"),
        )
        self.assertLess(
            worker.index("journalBackgroundSubscriptionChanges"),
            worker.index("prepareBackgroundLocalOutboxCommit"),
        )
        self.assertLess(
            worker.index("prepareBackgroundLocalOutboxCommit"),
            worker.index("try context.save()"),
        )
        self.assertEqual(worker.count("try context.save()"), 1)
        self.assertIn("cancelBackgroundLocalOutboxCommit", worker)
        self.assertIn("context.rollback()", worker)
        self.assertIn("managedObjectID(", worker)
        self.assertIn("forURIRepresentation: feedObjectURI", worker)
        self.assertNotIn("objectContext", worker)

        entry = body(REMOTE, "func commitLocalSubscriptionUnsubscribe(")
        self.assertLess(
            entry.index("Task.detached(priority: .utility)"),
            entry.index("commitLocalSubscriptionUnsubscribeInBackground"),
        )
        self.assertIn("prepareBackgroundLocalSubscriptionMerge", entry)
        self.assertIn("commitBackgroundLocalSubscriptionMergePlan", entry)
        self.assertIn("drainPendingSubscriptionCleanupIntentsIfNeeded", entry)
        self.assertLess(
            entry.index("commitBackgroundLocalSubscriptionMergePlan"),
            entry.index("completion(nil)"),
        )

        detail = body(FEED_UI, "- (void) unsubscribeAction:")
        self.assertIn("unsubscribeFeed:self.feed", detail)
        self.assertIn("completion:^(NSError* error)", detail)
        self.assertNotIn("afterDelay:0.3", detail)
        self.assertIn("presentError:error", detail)
        self.assertLess(detail.index("if (error)"), detail.index("popToRootViewControllerAnimated"))

        listing = body(
            LIST_UI,
            "- (void)tableView:(UITableView *)tableView commitEditingStyle:",
        )
        self.assertIn("unsubscribeFeed:feed", listing)
        self.assertIn("completion:^(NSError* error)", listing)
        self.assertIn("presentError:error", listing)
        self.assertGreaterEqual(listing.count("self->_flags.userAction = 0"), 1)
        success_start = listing.index("else", listing.index("presentError:error"))
        self.assertGreater(listing.index("performFetch:nil", success_start), success_start)
        self.assertGreater(listing.index("reloadDataAndTable:YES", success_start), success_start)

    def test_background_journal_encodes_both_subscription_states(self):
        snapshot = body(
            LOCAL_CHANGES,
            "private struct ICBackgroundSubscriptionJournalSnapshot",
        )
        self.assertIn("let subscribed: Bool", snapshot)
        self.assertIn("let payloadHash: String?", snapshot)

        journal = body(
            LOCAL_CHANGES,
            "nonisolated static func journalBackgroundSubscriptionChanges(",
        )
        self.assertIn("snapshot.subscribed ? localOutboxSaveOperation", journal)
        self.assertIn("snapshot.subscribed ? localOutboxDeleteOperation", journal)
        self.assertIn("localState: snapshot.subscribed", journal)
        self.assertIn("payloadHash: snapshot.payloadHash", journal)
        self.assertIn('"deleted": true', journal)
        self.assertNotIn("guard feed.subscribed,", journal[: journal.index("if !credentialIntents.isEmpty")])
        self.assertIn("subscriptionsSyncHasParticipatedKey", journal)

        start = body(MANAGER, "@objc func start()")
        self.assertIn(
            "name: .NSManagedObjectContextObjectsDidChange, object: databaseManager.objectContext",
            start,
        )
        merge = body(
            LOCAL_CHANGES,
            "func commitBackgroundLocalSubscriptionMergePlan(",
        )
        self.assertLess(
            merge.index("isApplyingRemoteChange = true"),
            merge.index("NSManagedObjectContext.mergeChanges"),
        )


if __name__ == "__main__":
    unittest.main()
