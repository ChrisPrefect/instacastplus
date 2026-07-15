#!/usr/bin/env python3
"""Pins every received EpisodeState path to one bounded background worker."""

import re
import unittest

from _icloud_sync_episode_apply_test_support import (
    brace_block_ranges,
    called_function_names,
    common_episode_background_worker,
    function,
    index_is_inside,
    reachable_function_names,
    transitive_source,
)


class ICloudEpisodeApplyAllPathsOffMainRegressionTests(unittest.TestCase):
    def require_worker(self):
        worker = common_episode_background_worker()
        self.assertIsNotNone(
            worker,
            "Live fetch, pending replay, and serverRecordChanged must converge on one "
            "nonisolated background EpisodeState mutation worker.",
        )
        return worker

    def test_live_pending_and_conflict_paths_share_one_background_worker(self):
        worker = self.require_worker()
        for root in (
            "handleFetchedRecordZoneChanges",
            "applyPendingEpisodeStates",
            "handleSentRecordZoneChanges",
        ):
            self.assertIn(
                worker.name,
                reachable_function_names(root),
                f"{root} does not reach the shared EpisodeState worker {worker.name}.",
            )

    def test_shared_worker_never_hops_to_main_or_saves_the_view_context(self):
        worker = self.require_worker()
        closure = transitive_source(worker.name)
        for forbidden in (
            "databaseManager.objectContext",
            "databaseManager.saveReturningError",
            "performSynchronousRemoteApplyBatch",
            "MainActor.run",
            "Task { @MainActor",
        ):
            self.assertFalse(
                forbidden in closure,
                f"The shared EpisodeState worker still reaches MainActor/view-context work: {forbidden}",
            )
        self.assertIn("remoteApplyBatchSize", closure)
        self.assertIn("context.perform", closure)
        self.assertIn("context.save()", closure)

        if "applyRemoteEpisodeState(" in closure:
            kernel = function("applyRemoteEpisodeState")
            self.assertIn("nonisolated", kernel.declaration)
            self.assertIn("static", kernel.declaration)

    def test_pending_replay_is_only_background_orchestration(self):
        pending = function("applyPendingEpisodeStates").body
        for forbidden in (
            "databaseManager.objectContext",
            "performSynchronousRemoteApplyBatch",
            "applyRemoteEpisodeState(",
            ".payloadDictionary()",
            "context.fetch(",
        ):
            self.assertFalse(
                forbidden in pending,
                f"Pending recovery still performs mass EpisodeState work on MainActor: {forbidden}",
            )
        worker = self.require_worker()
        self.assertIn(worker.name, reachable_function_names("applyPendingEpisodeStates"))

    def test_server_record_changed_episodes_are_batched_before_per_record_handling(self):
        worker = self.require_worker()
        sent = function("handleSentRecordZoneChanges").body
        per_record_ranges = brace_block_ranges(
            sent,
            r"for\s+failedSave\s+in\s+event\.failedRecordSaves",
        )
        self.assertTrue(per_record_ranges, "Missing failed-save processing loop.")

        batch_entries = []
        for callee in called_function_names(sent):
            if worker.name not in reachable_function_names(callee):
                continue
            call_sites = list(re.finditer(rf"\b{re.escape(callee)}\s*\(", sent))
            if any(not index_is_inside(match.start(), per_record_ranges) for match in call_sites):
                batch_entries.append(callee)

        self.assertTrue(
            batch_entries,
            "Episode serverRecordChanged values must enter the shared worker as a batch, "
            "not through handleFailedRecordSave once per record.",
        )
        batch_source = "\n".join(transitive_source(name) for name in batch_entries)
        self.assertIn("serverRecordChanged", sent + batch_source)
        self.assertIn("episodeState", sent + batch_source)

    def test_single_record_conflict_helper_no_longer_mutates_episode_on_main(self):
        single = function("applyRemoteRecord").body
        self.assertFalse(
            "applyRemoteEpisodeState(" in single,
            "A server conflict still mutates and saves one EpisodeState on MainActor.",
        )
        self.assertFalse(
            "databaseManager.objectContext" in single,
            "The single-record conflict path still opens the view context.",
        )


if __name__ == "__main__":
    unittest.main()
