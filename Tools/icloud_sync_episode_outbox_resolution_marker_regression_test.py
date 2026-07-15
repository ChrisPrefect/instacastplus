#!/usr/bin/env python3
"""Pins exact EpisodeState outbox resolution across receive, drain, and materialization."""

import unittest
from pathlib import Path

from _icloud_sync_episode_apply_test_support import (
    FUNCTIONS_BY_NAME,
    common_episode_background_worker,
    function,
    transitive_source,
)


ROOT = Path(__file__).resolve().parents[1]
SWIFT = "\n".join(
    path.read_text() for path in sorted((ROOT / "Classes").glob("ICiCloudSyncManager*.swift"))
)


def resolution_marker(revision: str) -> str:
    return f"resolvedOutboxRevision:v1:{revision}"


class EpisodeOutboxResolutionMarkerRegressionTests(unittest.TestCase):
    def test_resolution_is_exact_revision_not_timestamp_based(self):
        r1 = resolution_marker("r1")
        self.assertEqual(r1, resolution_marker("r1"))
        self.assertNotEqual(r1, resolution_marker("r2"))

        self.assertIn("resolvedOutboxRevision:v1:", SWIFT)
        helper = function("episodeOutboxRevisionResolvedByMetadata").body
        self.assertIn("payloadHash", helper)
        self.assertIn("revision", helper)
        self.assertNotIn("changedAt", helper)
        self.assertNotIn("localModifiedAt", helper)

    def test_background_receiver_marks_but_never_deletes_or_acknowledges_outbox(self):
        worker = common_episode_background_worker()
        self.assertIsNotNone(worker)
        closure = transitive_source(worker.name)
        self.assertIn("episodeOutboxResolutionMarker", closure)
        self.assertNotIn("context.delete(outbox", closure)
        self.assertNotIn('outbox.setValue(true, forKey: "acknowledged")', closure)

    def test_drain_and_materializer_both_ignore_exactly_resolved_revision(self):
        self.assertIn(
            "episodeOutboxRevisionResolvedByMetadata",
            function("drainLocalOutbox").body,
        )
        self.assertIn(
            "episodeOutboxRevisionResolvedByMetadata",
            transitive_source("materializeRecordsForSyncEngineCallback"),
        )
        cache_commit = function("consumeEpisodeApplyBatchResult").body
        self.assertIn("resolvedOutboxRevisions", cache_commit)
        self.assertIn("localOutboxSnapshotCache", cache_commit)
        self.assertIn("?.revision == revision", cache_commit)

    def test_local_episode_clock_uses_active_remote_floor(self):
        persistence = "\n".join(
            item.body for item in FUNCTIONS_BY_NAME["persistLocalOutboxMutations"]
        )
        self.assertIn("remoteEpisodeClockGate.floor", persistence)


if __name__ == "__main__":
    unittest.main()
