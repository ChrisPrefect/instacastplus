#!/usr/bin/env python3
"""Pins linearizable Episode/Subscription apply commits across OFF/account transitions."""

import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing function: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


class CommitLeaseModel:
    """Deterministic interleaving model for the production lease contract."""

    def __init__(self):
        self.enabled = True
        self.epoch = 0
        self.transition_closed = False
        self.active = set()
        self.consumed = []
        self._condition = threading.Condition()

    def begin_apply(self):
        return self.epoch if self.enabled else None

    def toggle(self, enabled):
        with self._condition:
            if self.enabled != enabled:
                self.epoch += 1
            self.enabled = enabled

    def acquire(self, epoch):
        with self._condition:
            if not self.enabled or self.epoch != epoch or self.transition_closed:
                return None
            token = object()
            self.active.add(token)
            return token

    def consume(self, token):
        with self._condition:
            if token not in self.active:
                return False
            self.consumed.append(token)
            self.active.remove(token)
            self._condition.notify_all()
            return True

    def begin_transition(self):
        with self._condition:
            self.transition_closed = True
            while self.active:
                self._condition.wait()


class ICloudRemoteApplyCommitLeaseRegressionTests(unittest.TestCase):
    def test_toggle_before_linearization_rejects_commit(self):
        gate = CommitLeaseModel()
        epoch = gate.begin_apply()
        gate.toggle(False)
        self.assertIsNone(gate.acquire(epoch))

    def test_toggle_after_linearization_keeps_commit_consumable(self):
        gate = CommitLeaseModel()
        epoch = gate.begin_apply()
        token = gate.acquire(epoch)
        self.assertIsNotNone(token)
        gate.toggle(False)
        self.assertTrue(gate.consume(token))

    def test_account_transition_closes_new_commits_and_waits_for_consume(self):
        gate = CommitLeaseModel()
        epoch = gate.begin_apply()
        token = gate.acquire(epoch)
        transition_finished = threading.Event()

        def transition():
            gate.begin_transition()
            transition_finished.set()

        thread = threading.Thread(target=transition)
        thread.start()
        self.assertFalse(transition_finished.wait(0.02))
        self.assertIsNone(gate.acquire(epoch))
        self.assertTrue(gate.consume(token))
        self.assertTrue(transition_finished.wait(1))
        thread.join()

    def test_gate_uses_tokenized_nonblocking_leases(self):
        self.assertIn("struct ICiCloudRemoteApplyCommitLease", TYPES)
        self.assertIn("activeRemoteApplyCommitLeases", MANAGER)
        self.assertIn("acquireEpisodeApplyCommitLease", MANAGER)
        self.assertIn("acquireSubscriptionApplyCommitLease", MANAGER)
        self.assertIn("releaseRemoteApplyCommitLease", MANAGER)
        self.assertIn("beginRemoteApplyAccountTransition", MANAGER)
        self.assertIn("awaitRemoteApplyCommitLeases", MANAGER)

    def test_account_transition_async_barrier_surrounds_cleanup(self):
        acquire = body(REMOTE, "func acquireICloudAccountTransition() async")
        release = body(REMOTE, "func releaseICloudAccountTransition()")
        self.assertIn("beginRemoteApplyAccountTransition", acquire)
        self.assertIn("awaitRemoteApplyCommitLeases", acquire)
        self.assertIn("endRemoteApplyAccountTransition", release)

    def test_delete_all_holds_commit_barrier_across_zone_and_local_cleanup(self):
        delete_all = body(MANAGER, "@objc func deleteAllICloudDataWithCompletion")
        acquire = delete_all.find("await acquireICloudAccountTransition()")
        zone_delete = delete_all.find("database.deleteRecordZone")
        local_reset = delete_all.find("resetAllLocalSyncMetadata(")
        self.assertTrue(0 <= acquire < zone_delete < local_reset)
        self.assertIn("defer { releaseICloudAccountTransition() }", delete_all[acquire:])

    def test_factory_reset_drains_producers_then_holds_barrier_across_cleanup(self):
        reset = body(MANAGER, "@objc func prepareForLocalAppResetWithCompletion")
        close_gate = reset.find("updateSyncEngineCallbackGate()")
        await_tasks = reset.find("for task in tasks { await task.value }")
        acquire = reset.find("await acquireICloudAccountTransition()")
        pending_cleanup = reset.find("deleteAllPendingEpisodeStates()")
        local_reset = reset.find("resetAllLocalSyncMetadata()")
        self.assertTrue(
            0 <= close_gate < await_tasks < acquire < pending_cleanup < local_reset
        )
        protected = reset[acquire:]
        first_recovery = protected.find("recoverAfterFailedLocalAppReset")
        second_cleanup = protected.find("deleteAllLocalOutboxEntriesForLocalReset")
        second_recovery = protected.find("recoverAfterFailedLocalAppReset", first_recovery + 1)
        success_release = protected.rfind("releaseICloudAccountTransition()")
        success_completion = protected.rfind("completion(nil)")
        release_positions = [
            index for index in range(len(protected))
            if protected.startswith("releaseICloudAccountTransition()", index)
        ]
        self.assertEqual(len(release_positions), 3)
        self.assertTrue(
            release_positions[0] < first_recovery < second_cleanup
            < release_positions[1] < second_recovery < local_reset - acquire
            < success_release < success_completion
        )

    def test_episode_worker_transfers_lease_across_save_and_consume_releases_it(self):
        worker = body(REMOTE, "nonisolated static func applyPendingEpisodeStateBatchInBackground(")
        consume = body(REMOTE, "func consumeEpisodeApplyBatchResult(")
        acquire = worker.rfind("acquireEpisodeApplyCommitLease")
        save = worker.rfind("context.save()")
        result = worker.rfind("ICCloudEpisodeApplyBatchResult(")
        self.assertTrue(0 <= acquire < save < result)
        self.assertIn("commitLease: commitLease", worker[result:])
        self.assertIn("releaseRemoteApplyCommitLease", worker[save:])
        self.assertIn("result.commitLease", consume)
        self.assertIn("defer", consume)
        self.assertIn("releaseRemoteApplyCommitLease", consume)

    def test_subscription_worker_transfers_lease_across_save_and_consume_releases_it(self):
        worker = body(REMOTE, "nonisolated static func applyPendingSubscriptionBatchInBackground(")
        consume = body(REMOTE, "func consumeSubscriptionApplyBatchResult(")
        acquire = worker.rfind("acquireSubscriptionApplyCommitLease")
        save = worker.rfind("context.save()")
        result = worker.rfind("ICCloudSubscriptionApplyBatchResult(")
        self.assertTrue(0 <= acquire < save < result)
        self.assertIn("commitLease: commitLease", worker[result:])
        self.assertIn("releaseRemoteApplyCommitLease", worker[save:])
        self.assertIn("result.commitLease", consume)
        self.assertIn("defer", consume)
        self.assertIn("releaseRemoteApplyCommitLease", consume)

    def test_episode_off_on_epoch_is_captured_before_worker(self):
        self.assertIn("episodeApplyEpoch", MANAGER)
        self.assertIn("beginEpisodeApply", MANAGER)
        worker = REMOTE[
            REMOTE.index("nonisolated static func applyPendingEpisodeStateBatchInBackground("):
            REMOTE.index("nonisolated static func episodeOutboxSnapshot(")
        ]
        self.assertIn("episodeEpoch: UInt64", worker)
        self.assertIn("epoch: episodeEpoch", worker)


if __name__ == "__main__":
    unittest.main()
