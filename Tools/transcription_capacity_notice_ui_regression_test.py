#!/usr/bin/env python3
"""Capacity rejection and acknowledgement must remain explicit in the UI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CapacityNoticeUITests(unittest.TestCase):
    def test_duplicate_local_job_has_feedback_even_when_queue_is_full(self):
        source = (ROOT / "Classes/EpisodesTableViewController.m").read_text()
        method = source.split("- (void) _transcribeEpisode:", 1)[1].split("- (void) _serverTranscribeEpisode:", 1)[0]
        self.assertNotIn("canAddQueueItem", method)
        self.assertIn("ICTranscriptionStatusCompleted", method)
        self.assertIn("ICTranscriptionStatusFailed", method)
        self.assertIn("_showTranscriptionToastWithText:", method)

    def test_notice_can_be_acknowledged_without_removing_jobs(self):
        source = (ROOT / "Classes/TranscriptionQueueViewController.m").read_text()
        self.assertIn("capacitySkippedCount", source)
        self.assertIn("acknowledgeCapacityNotice", source)
        self.assertIn('NSLocalizedString(@"Dismiss notice", nil)', source)
        for locale in ("de", "en"):
            strings = (ROOT / f"Resources/{locale}.lproj/Localizable.strings").read_text()
            self.assertIn('"Dismiss notice" =', strings)


if __name__ == "__main__":
    unittest.main()
