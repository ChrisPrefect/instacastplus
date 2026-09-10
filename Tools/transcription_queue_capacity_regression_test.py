#!/usr/bin/env python3
"""Admission, unchanged-poll and UI contracts from the build-37 queue incident."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def read(name):
    return (ROOT / "Classes" / name).read_text()


def body(source, signature):
    start = source.index("{", source.index(signature))
    depth = 0
    for i in range(start, len(source)):
        depth += (source[i] == "{") - (source[i] == "}")
        if depth == 0:
            return source[start + 1:i]
    raise AssertionError(signature)


class QueueIncidentTests(unittest.TestCase):
    def assertIn(self, member, container, msg=None):
        self.assertTrue(member in container, msg or f"Missing contract: {member}")

    def test_combined_admission_limit(self):
        queue = read("TranscriptionQueue.swift")
        self.assertIn("maximumActiveItemCount = 25", queue)
        self.assertIn("activeItemCount < Self.maximumActiveItemCount", queue)
        for signature in ["private func enqueueJob(", "@objc func generateChapters("]:
            method = body(queue, signature)
            self.assertLess(method.index("admitQueueItem("), method.index("items.append(item)"))
        self.assertIn("admitQueueItem(", body(queue, "@objc func retry(episodeHash:"))

    def test_server_admission_and_retry_share_capacity(self):
        server = read("ServerTranscriptionManager.swift")
        for signature in ["@objc func enqueueEpisode(", "@objc func enqueueAutomaticEpisodes(",
                          "@objc func retryEpisodeHash("]:
            self.assertIn("admitQueueItem(", body(server, signature))

    def test_unchanged_poll_preserves_lifecycle_without_ui_spam(self):
        server = read("ServerTranscriptionManager.swift")
        publish = body(server, "private func postQueueChange()")
        self.assertIn("publishedQueueState", publish)
        self.assertIn("publishProcessingChange()", publish)
        self.assertNotIn('"isProcessing"', publish)
        self.assertLess(publish.index("publishProcessingChange()"), publish.index("isEqual"))
        processing = body(server, "private func publishProcessingChange()")
        self.assertIn("let processing = isProcessing", processing)
        self.assertIn("guard publishedProcessingState != processing", processing)
        self.assertIn("ICServerTranscriptionProcessingDidChangeNotification", processing)
        self.assertIn("persistenceError", publish)
        self.assertLess(publish.index("isEqual"), publish.index("NotificationCenter.default.post"))
        self.assertNotIn("nextRetryAt", publish)

    def test_episode_status_does_not_replace_touched_cells(self):
        method = body(read("EpisodesTableViewController.m"), "- (void) _transcriptionQueueChanged")
        self.assertNotIn("reloadData", method)
        self.assertIn("updateTranscriptIndicatorState", method)
        self.assertIn("_deferTableUpdateDuringSwipe", method)

    def test_sidebar_only_rebuilds_for_visibility_change(self):
        method = body(read("MainViewController_4.m"), "- (void) _transcriptionQueueDidChange")
        self.assertIn("hasVisibleItems", method)
        self.assertIn("updateItemWithTag", method)
        self.assertIn("if (", method)

    def test_queue_is_not_starved_by_repeated_debounce(self):
        method = body(read("TranscriptionQueueViewController.m"), "- (void)_queueChanged")
        self.assertNotIn("afterDelay:", method)
        self.assertIn("displayedItems", method)
        self.assertIn("_progressUpdated", method)

    def test_capacity_is_visible_and_localized(self):
        queue = read("TranscriptionQueue.swift")
        self.assertIn("queueCapacitySummary", queue)
        self.assertIn("capacitySkippedCount", queue)
        self.assertIn("queueCapacitySummary", read("TranscriptionQueueViewController.m"))
        for locale in ["de", "en"]:
            strings = (ROOT / f"Resources/{locale}.lproj/Localizable.strings").read_text()
            self.assertIn('"Transcription queue limit reached"', strings)

    def test_replayed_rejections_are_unique_and_notice_remains_reachable(self):
        queue = read("TranscriptionQueue.swift")
        admission = body(queue, "@objc func admitQueueItem(")
        self.assertIn("capacitySkippedEpisodeHashes.insert(episodeHash).inserted", admission)
        self.assertIn("scheduleCapacityNoticeUpdate()", admission)
        self.assertIn("capacitySkippedCount > 0", body(queue, "@objc var hasVisibleItems:"))
        acknowledge = body(queue, "@objc func acknowledgeCapacityNotice()")
        self.assertIn("capacitySkippedEpisodeHashes.removeAll()", acknowledge)
        self.assertIn("scheduleCapacityNoticeUpdate()", acknowledge)
        publish = body(queue, "private func scheduleCapacityNoticeUpdate()")
        self.assertIn("guard !capacityNoticeUpdatePending", publish)
        self.assertIn("DispatchQueue.main.async", publish)


if __name__ == "__main__":
    unittest.main()
