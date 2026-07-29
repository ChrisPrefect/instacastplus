#!/usr/bin/env python3
"""Regression proof for the TestFlight invalid-row-count crash in feed settings."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "FeedSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.index(signature)
    brace = SOURCE.index("{", start)
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"unterminated method: {signature}")


view_will_appear = method_body("- (void)viewWillAppear:(BOOL)animated")
view_did_appear = method_body("- (void)viewDidAppear:(BOOL)animated")

require(
    "[self _reloadArchivedEpisodeCount]" not in view_will_appear,
    "The asynchronous archived-count refresh must not start while the returning table "
    "still has the old dynamic playback-section row count.",
)
require(
    "[self.tableView reloadData]" in view_did_appear
    and "[self _reloadArchivedEpisodeCount]" in view_did_appear
    and view_did_appear.index("[self.tableView reloadData]")
    < view_did_appear.index("[self _reloadArchivedEpisodeCount]"),
    "After a child setting changes the playback section from 5 to 6 rows (or back), "
    "viewDidAppear must fully synchronize the table before any targeted archived-section reload.",
)

print("Feed-settings dynamic-row lifecycle regression checks passed")
