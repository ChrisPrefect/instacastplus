#!/usr/bin/env python3
"""Pin the evidence needed for a played row offering 'Mark as Played'.

The customer recording cannot establish whether the model was reset or the row
was stale. These checks cover diagnostics, not a reproduction of that bug.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


def method(path, signature):
    source = (ROOT / path).read_text()
    return source.split(signature, 1)[1].split("\n- (", 1)[0]


class PlayedStateDiagnosticsTests(unittest.TestCase):
    def test_reset_captures_caller_without_symbolicating_on_model_queue(self):
        body = method("Classes/Model/CDEpisode.m", "- (void) setConsumed:")
        self.assertIn('logEvent:@"episode-played-state"', body)
        reset = body.split("if (wasConsumed && !consumed)", 1)[1]
        snapshot, background = reset.split("dispatch_async(", 1)
        for key in ("episodeHash", "episodeObjectID", "episodePosition",
                    "episodeDuration", "changedAt"):
            self.assertIn(f'@"{key}"', snapshot)
        self.assertIn("[NSThread callStackReturnAddresses]", snapshot)
        self.assertIn("QOS_CLASS_UTILITY", background)
        self.assertIn("backtrace_symbols(", background)
        self.assertNotIn("self.", background.split("\n    }", 1)[0])
        self.assertNotIn("callStackSymbols", body)

    def test_long_press_records_menu_and_visible_cell_identity(self):
        body = method("Classes/EpisodesTableViewController.m",
                      "- (UIMenu *) _contextMenuForEpisode:")
        self.assertIn('logEvent:@"episode-context-menu"', body)
        for key in ("episodeHash", "episodeObjectID", "episodeConsumed",
                    "episodePosition", "episodeDuration", "cellEpisodeHash",
                    "cellEpisodeObjectID", "cellEpisodeConsumed"):
            self.assertIn(f'@"{key}"', body)
        self.assertIn("cellForRowAtIndexPath:indexPath", body)
        self.assertIn("cell.objectValue", body)

    def test_auto_skip_records_actual_model_state(self):
        body = method("Classes/PlaybackManager.m",
                      "- (NSMutableDictionary*)_playbackDiagnosticsMetadataForEpisode:")
        for key in ("episodeConsumed", "episodePosition", "episodeDuration"):
            self.assertIn(f'@"{key}"', body)


if __name__ == "__main__":
    unittest.main()
