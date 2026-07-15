#!/usr/bin/env python3
"""Pins distinct, stable initial-backfill progress and bounded page look-ahead."""

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
    brace = source.find("{", start)
    if brace == -1:
        raise AssertionError(f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


class ICloudBackfillIdentityProgressPipelineRegressionTests(unittest.TestCase):
    def test_episode_plan_pages_distinct_cloudkit_record_identities(self):
        episode_page = method_body(
            MANAGER, "nonisolated static func episodeObjectHashesForInitialUploadPlan"
        )
        self.assertIn(
            "request.returnsDistinctResults = true",
            episode_page,
            "CloudKit has one record per objectHash, so duplicate legacy Core Data rows must collapse in SQL.",
        )

    def test_episode_total_uses_the_same_distinct_identity_as_the_plan(self):
        totals = method_body(MANAGER, "nonisolated static func computeSyncTotalCounts")
        episode_branch = totals.split("if episodesEnabled", 1)[1].split(
            "if subscriptionsEnabled", 1
        )[0]
        self.assertIn("returnsDistinctResults = true", episode_branch)
        self.assertIn("context.fetch", episode_branch)
        self.assertNotIn(
            "context.count(for: request)",
            episode_branch,
            "A row count disagrees with the distinct objectHash records actually uploaded.",
        )

    def test_subscription_plan_pages_distinct_cloudkit_record_identities(self):
        subscription_page = method_body(
            MANAGER, "nonisolated static func subscribedFeedURLsForInitialUploadPlan"
        )
        self.assertIn("NSFetchRequest<NSDictionary>", subscription_page)
        self.assertIn('propertiesToFetch = ["sourceURL_"]', subscription_page)
        self.assertIn("returnsDistinctResults = true", subscription_page)
        self.assertIn(
            "sourceURL_ IN %@",
            subscription_page,
            "Payload hydration must happen only after the distinct URL page is fixed.",
        )

    def test_count_read_failure_cannot_be_frozen_as_zero(self):
        signature_start = MANAGER.find("nonisolated static func computeSyncTotalCounts")
        signature_end = MANAGER.find("{", signature_start)
        self.assertIn("async throws", MANAGER[signature_start:signature_end])
        totals = method_body(MANAGER, "nonisolated static func computeSyncTotalCounts")
        self.assertNotIn("try?", totals)
        refresh = method_body(MANAGER, "func refreshSyncTotalCountsInBackground")
        self.assertIn("try await Self.computeSyncTotalCounts", refresh)

    def test_backfill_total_is_durable_frozen_and_bound_to_the_account(self):
        total_key = re.search(r"initialEpisodeBackfill\w*Total\w*Key", MANAGER)
        self.assertIsNotNone(
            total_key,
            "Initial episode progress needs a durable total key.",
        )
        account_scoped = (
            "initialEpisodeBackfillTotalAccountKey" in MANAGER
            or "initialBackfillTotalsByAccountKey" in MANAGER
            or re.search(r"initialEpisodeBackfill\w*Total\w*Account\w*Key", MANAGER)
            is not None
        )
        self.assertTrue(
            account_scoped,
            "The frozen total must never leak across iCloud accounts.",
        )
        counts = method_body(MANAGER, "@objc var syncCounts")
        self.assertRegex(
            counts,
            r"initialEpisodeBackfill\w*Total",
            "Visible backfill progress must use its durable start snapshot, not a live recount.",
        )
        live_totals = method_body(MANAGER, "func syncTotalCounts")
        self.assertIn(
            "hasInitialUploadBackfillWork",
            live_totals,
            "Repeated status reads must not launch a new Episode/Feed count scan during backfill.",
        )
        frozen_total = method_body(MANAGER, "var initialEpisodeBackfillFrozenTotal")
        self.assertIn(
            "initialEpisodeBackfillOffsetKey",
            frozen_total,
            "A stale total left by a crash after completion must be ignored without an active cursor.",
        )

    def test_cursor_and_visible_offset_share_one_durable_checkpoint(self):
        self.assertIn("initialEpisodeBackfillCheckpointKey", MANAGER)
        self.assertIn("initialSubscriptionBackfillCheckpointKey", MANAGER)
        state = method_body(MANAGER, "func initialBackfillState(")
        self.assertIn("checkpointKey", state)
        self.assertIn("dictionary(forKey: checkpointKey)", state)
        persist = method_body(MANAGER, "func persistInitialBackfillCheckpoint")
        self.assertIn("defaults.set(checkpoint, forKey: checkpointKey)", persist)
        for signature in (
            "func updateInitialEpisodeBackfillCursor",
            "func updateInitialSubscriptionBackfillCursor",
        ):
            self.assertIn("persistInitialBackfillCheckpoint", method_body(MANAGER, signature))

    def test_partial_cloudkit_ack_posts_the_new_numerator(self):
        resolved = method_body(
            MANAGER, "func recordInitialUploadRecordNamesResolved"
        )
        subtract = resolved.find(".subtract(resolvedNames)")
        notify = resolved.find("postStateChanged()", subtract)
        self.assertGreater(subtract, -1)
        self.assertGreater(
            notify,
            subtract,
            "A partial ACK must refresh X/Y even when the complete page cursor cannot advance yet.",
        )

    def test_more_than_one_page_is_prepared_before_send_can_drain(self):
        window_patterns = [
            r"initialUploadPreparedPageWindowSize\s*=\s*(\d+)",
            r"initialUploadPageWindowSize\s*=\s*(\d+)",
            r"initialUploadLookaheadPageCount\s*=\s*(\d+)",
        ]
        match = next(
            (re.search(pattern, MANAGER) for pattern in window_patterns if re.search(pattern, MANAGER)),
            None,
        )
        self.assertIsNotNone(
            match,
            "Initial upload needs an explicit bounded page look-ahead window.",
        )
        self.assertGreater(int(match.group(1)), 1)

        plan = method_body(MANAGER, "nonisolated static func buildInitialUploadPlan")
        self.assertIn("pages.append(", plan)
        self.assertNotIn(
            "pages: [page]",
            plan,
            "Preparing exactly one page forces local fetch/writes between all 19 CloudKit requests.",
        )
        apply_plan = method_body(MANAGER, "func applyInitialUploadPlan")
        self.assertIn("recordInitialUploadBatchesQueued(", apply_plan)


if __name__ == "__main__":
    unittest.main()
