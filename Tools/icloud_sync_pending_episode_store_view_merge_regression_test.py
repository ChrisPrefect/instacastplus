#!/usr/bin/env python3
"""Prevents sync-private pending EpisodeState writes from flooding the view context."""

from __future__ import annotations

import math
import re
import unittest

from _icloud_sync_episode_apply_test_support import ROOT, function


DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def matching_brace(source: str, opening: int) -> int:
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise AssertionError("Unterminated Objective-C method")


def context_factory_body(name: str) -> str | None:
    declaration = re.search(
        rf"-\s*\(NSManagedObjectContext\s*\*\s*\)\s*{re.escape(name)}\s*\n?\s*\{{",
        DATABASE,
    )
    if not declaration:
        return None
    opening = DATABASE.find("{", declaration.start())
    return DATABASE[opening + 1:matching_brace(DATABASE, opening)]


def write_uses_view_merge_isolated_storage(swift_body: str) -> bool:
    if "context.save()" not in swift_body:
        return "NSBatchInsertRequest" in swift_body or "NSBatchDeleteRequest" in swift_body
    factories = re.findall(
        r"(?:DatabaseManager\.shared\(\)\??|databaseManager)\."
        r"(new[A-Za-z0-9_]*Context)\(\)",
        swift_body,
    )
    if not factories:
        return False
    for factory in factories:
        body = context_factory_body(factory)
        if body is None:
            return False
        uses_container_context = "[container newBackgroundContext]" in body
        owns_separate_coordinator = (
            "NSPersistentStoreCoordinator" in body
            and "NSPrivateQueueConcurrencyType" in body
            and "persistentStoreCoordinator = _" in body
        )
        if uses_container_context or not owns_separate_coordinator:
            return False
    return True


class ICloudPendingEpisodeStoreViewMergeRegressionTests(unittest.TestCase):
    def test_pending_episode_writes_do_not_use_auto_merging_container_context(self):
        self.assertIn(
            "automaticallyMergesChangesFromParent = YES",
            DATABASE,
            "The regression matters while the UI context automatically merges container saves.",
        )
        for method_name in (
            "stagePendingEpisodeStates",
            "removePendingEpisodeStates",
            "deleteAllPendingEpisodeStates",
            "applyPendingEpisodeStateBatchInBackground",
        ):
            body = function(method_name).body
            self.assertTrue(
                write_uses_view_merge_isolated_storage(body),
                f"{method_name} saves sync-private rows through the UI container, so every "
                "100-row chunk is merged into the view context.",
            )

    def test_4515_staged_rows_generate_zero_view_context_merge_batches(self):
        stage = function("stagePendingEpisodeStates").body
        isolated = write_uses_view_merge_isolated_storage(stage)
        synthetic_view_merges = 0 if isolated else math.ceil(4515 / 100)
        self.assertEqual(
            synthetic_view_merges,
            0,
            "4515 received EpisodeStates currently enqueue 46 irrelevant view-context merges "
            "before their real episode mutations even begin.",
        )

    def test_worker_merges_only_exact_user_visible_object_ids(self):
        worker = function("applyPendingEpisodeStateBatchInBackground").body
        consume = function("consumeEpisodeApplyBatchResult").body
        conversion = function("managedObjectIDs").body
        self.assertIn("$0.entity.name == pendingEpisodeStateEntityName", worker)
        self.assertIn("NSInsertedObjectIDsKey", consume)
        self.assertIn("NSUpdatedObjectIDsKey", consume)
        self.assertNotIn("NSDeletedObjectIDsKey", consume)
        self.assertIn("managedObjectID(forURIRepresentation:", conversion)
        self.assertIn("throw", conversion)

    def test_view_context_merge_is_echo_suppressed_for_exact_remote_ids(self):
        consume = function("consumeEpisodeApplyBatchResult").body
        origin_union = consume.find("remoteAppliedObjectIDs.formUnion(originObjectIDs)")
        origin_cleanup = consume.find("defer {", origin_union)
        merge = consume.find("performSynchronousRemoteViewContextMerge(")
        self.assertGreaterEqual(origin_union, 0)
        self.assertGreaterEqual(origin_cleanup, 0)
        self.assertLess(
            origin_union,
            merge,
            "Remote episode IDs must be registered before the main-context merge notification.",
        )
        cleanup_end = consume.find("\n        }", origin_cleanup)
        self.assertIn(
            "remoteAppliedObjectIDs.subtract(originObjectIDs)",
            consume[origin_cleanup:cleanup_end],
            "Remote episode IDs must be cleared on every exit after the merge is consumed.",
        )

        subscription_consume = function("consumeSubscriptionApplyBatchResult").body
        self.assertIn(
            "performSynchronousRemoteViewContextMerge(",
            subscription_consume,
            "Remote subscription merges need the same synchronous observer suppression.",
        )
        helper = function("performSynchronousRemoteViewContextMerge").body
        self.assertIn("let wasApplyingRemoteChange = isApplyingRemoteChange", helper)
        self.assertIn("isApplyingRemoteChange = true", helper)
        self.assertIn("isApplyingRemoteChange = wasApplyingRemoteChange", helper)
        self.assertIn("NSManagedObjectContext.mergeChanges", helper)
        self.assertIn("context.processPendingChanges()", helper)
        self.assertNotIn("await", helper)


if __name__ == "__main__":
    unittest.main()
