#!/usr/bin/env python3
"""Pins atomic EpisodeState commits and remote-origin lifetime across background saves."""

import copy
import re
import unittest

from _icloud_sync_episode_apply_test_support import (
    common_episode_background_worker,
    function,
    transitive_source,
)


class AtomicEpisodeStoreModel:
    def __init__(self):
        self.episode = {"starred": False, "played": False, "position": 10}
        self.metadata_date = 1
        self.metadata_marker = None
        self.pending = {"episode_a": b"remote-v2"}
        self.outbox = {"episode_a": "local-r1"}

    def apply(self, *, valid: bool, save_succeeds: bool):
        transaction = copy.deepcopy(self.__dict__)
        transaction["episode"]["starred"] = True
        transaction["metadata_date"] = 2
        transaction["metadata_marker"] = "resolvedOutboxRevision:v1:local-r1"
        transaction["pending"].pop("episode_a")
        if not valid or not save_succeeds:
            return False
        self.__dict__.update(transaction)
        return True


class OriginGateModel:
    def __init__(self):
        self.awaiting_merge = set()
        self.local_captures = []

    def register_before_save(self, object_id: str):
        self.awaiting_merge.add(object_id)

    def save_finished(self):
        pass

    def observe_remote_merge(self, object_id: str):
        if object_id in self.awaiting_merge:
            self.awaiting_merge.remove(object_id)
            return "suppressed"
        return "captured"

    def observe_local_edit(self, object_id: str):
        self.local_captures.append(object_id)


class ICloudEpisodeApplyTransactionLifecycleRegressionTests(unittest.TestCase):
    def require_worker(self):
        worker = common_episode_background_worker()
        self.assertIsNotNone(
            worker,
            "No shared background EpisodeState transaction exists for lifecycle validation.",
        )
        return worker

    def test_pending_payload_episode_clock_and_outbox_marker_commit_atomically(self):
        worker = self.require_worker()
        body = worker.body
        closure = transitive_source(worker.name)
        for token in (
            "pendingEpisodeStateEntityName",
            "payloadData",
            "context.delete",
            "context.save()",
            "syncItemMetadata",
        ):
            self.assertIn(
                token,
                closure,
                f"The background transaction does not atomically own {token}.",
            )
        self.assertTrue(
            "localOutboxEntityName" in closure or "outbox" in closure.lower(),
            "Exact local-outbox resolution must join the EpisodeState transaction.",
        )
        self.assertLess(
            closure.find("context.delete"),
            closure.rfind("context.save()"),
            "The exact staged payload must be deleted by the same successful transaction.",
        )
        self.assertFalse(
            "removePendingEpisodeStates" in body,
            "A post-commit pending-row delete recreates a crash window outside the transaction.",
        )

    def test_failed_save_rolls_back_in_memory_mutations_and_keeps_pending(self):
        worker = self.require_worker()
        body = worker.body
        save = body.find("context.save()")
        self.assertNotEqual(save, -1)
        failure_tail = body[save:]
        self.assertTrue(
            "context.rollback()" in failure_tail or "rollbackRemoteEpisode" in failure_tail,
            "A failed background save must roll back the mutated context before returning.",
        )

        model = AtomicEpisodeStoreModel()
        before = copy.deepcopy(model.__dict__)
        self.assertFalse(model.apply(valid=True, save_succeeds=False))
        self.assertEqual(model.__dict__, before)

    def test_account_generation_and_episode_toggle_are_revalidated_before_save(self):
        worker = self.require_worker()
        declaration_and_body = worker.declaration + worker.body
        save = declaration_and_body.find("context.save()")
        self.assertNotEqual(save, -1)
        before_save = declaration_and_body[:save]
        self.assertRegex(before_save, r"generation|Generation")
        self.assertRegex(before_save, r"accountRecordName|AccountRecordName")
        self.assertRegex(
            before_save,
            r"episodesSyncEnabled|episodesEnabled|validityGate|isValid|canCommit",
        )
        self.assertRegex(before_save, r"guard|throw|CancellationError")

        model = AtomicEpisodeStoreModel()
        before = copy.deepcopy(model.__dict__)
        self.assertFalse(model.apply(valid=False, save_succeeds=True))
        self.assertEqual(model.__dict__, before)

    def test_concurrent_local_edit_uses_conflict_detection_not_object_trump(self):
        worker = self.require_worker()
        closure = transitive_source(worker.name)
        self.assertTrue(
            "NSErrorMergePolicy" in closure
            or "errorMergePolicyType" in closure
            or "optimistic" in closure.lower(),
            "Object-trump would silently overwrite a local edit committed during remote apply.",
        )
        self.assertFalse(
            "NSMergeByPropertyObjectTrumpMergePolicy" in closure,
            "The background transaction must not silently win over concurrent local edits.",
        )

    def test_remote_origin_registration_belongs_to_worker_and_survives_until_merge(self):
        worker = self.require_worker()
        body = worker.body
        registration_markers = (
            "registerRemoteAppliedObjectIDs",
            "registerRemoteEpisode",
            "remoteOriginGate.register",
            "remoteAppliedObjectIDs.formUnion",
        )
        registration = next((body.find(marker) for marker in registration_markers if marker in body), -1)
        save = body.find("context.save()")
        self.assertGreaterEqual(registration, 0, "The worker never registers its exact changed object IDs.")
        self.assertLess(registration, save, "Origin IDs must be registered before the background save notification.")
        self.assertFalse(
            "remoteAppliedObjectIDs.removeAll()" in body,
            "The worker clears origin IDs before the view-context merge can consume them.",
        )
        self.assertFalse(
            "remoteAppliedObjectIDs.removeAll()"
            in function("handleFetchedRecordZoneChanges").body,
            "Fetch completion can run before the view-context merge consumes the registered IDs.",
        )

        discard = function("discardRemoteAppliedObjectIDs").body
        self.assertIn("subtract", discard)

    def test_real_local_edit_after_remote_merge_remains_captureable(self):
        journal = function("journalLocalOutboxObjects").body
        self.assertRegex(
            journal,
            re.compile(r"changesAlreadyFiltered\s*\?\s*discardRemoteAppliedObjects"),
            "Only delayed merged IDs may pass through remote-origin filtering.",
        )

        gate = OriginGateModel()
        gate.register_before_save("episode-a")
        gate.save_finished()
        self.assertIn("episode-a", gate.awaiting_merge)
        self.assertEqual(gate.observe_remote_merge("episode-a"), "suppressed")
        gate.observe_local_edit("episode-a")
        self.assertEqual(gate.local_captures, ["episode-a"])


if __name__ == "__main__":
    unittest.main()
