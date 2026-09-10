#!/usr/bin/env python3
"""Server phases must not masquerade as measured percentages or user errors."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProgressPresentationTests(unittest.TestCase):
    def test_server_rows_do_not_draw_weighted_progress(self):
        source = (ROOT / "Classes/TranscriptionQueueViewController.m").read_text()
        method = source.split("- (NSString*)_updateCellStatus:", 1)[1]
        server = method.split("if (item.usesServerTranscription) {", 1)[1].split("return statusText;", 1)[0]
        self.assertNotIn("cell.progressView.progress = item.progress", server)
        self.assertNotIn("item.progress <=", server)
        self.assertIn("headline = detail", server)

    def test_customer_copy_does_not_expose_admission_bookkeeping(self):
        for locale in ("de", "en"):
            text = (ROOT / f"Resources/{locale}.lproj/Localizable.strings").read_text()
            for phrase in ("belegen Plätze in der App", "bitte nicht doppelt einreichen", "Serveraufnahme", "reserve app capacity", "do not submit it twice", "Server admission unconfirmed"):
                self.assertFalse(phrase in text, f"{locale} still contains {phrase!r}")


if __name__ == "__main__":
    unittest.main()
