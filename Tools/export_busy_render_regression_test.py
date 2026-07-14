#!/usr/bin/env python3
"""Pins one rendered busy-state turn before main-context export preparation."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


for public_signature, busy_call, begin_call, begin_signature in [
    ("- (void) exportSubscriptions", "setSubscriptionsExportBusy:YES", "_beginSubscriptionsExportAfterBusyState", "- (void)_beginSubscriptionsExportAfterBusyState"),
    ("- (void) exportBookmarks", "setBookmarksExportBusy:YES", "_beginBookmarksExportAfterBusyState", "- (void)_beginBookmarksExportAfterBusyState"),
    ("- (void) exportEverything", "setFullExportBusy:YES", "_beginFullExportAfterBusyState", "- (void)_beginFullExportAfterBusyState"),
]:
    public = body(public_signature)
    require(busy_call in public
            and "_commitExportBusyAppearance" in public
            and "dispatch_async(dispatch_get_main_queue()" in public
            and begin_call in public
            and "saveReturningError" not in public,
            f"{public_signature} must commit its spinner appearance and return to the main run loop before database preparation starts.")
    begin = body(begin_signature)
    require("saveReturningError" in begin,
            f"{begin_signature} must retain the checked consistency save after the busy state has rendered.")

commit = body("- (void)_commitExportBusyAppearance")
require("layoutIfNeeded" in commit and "[CATransaction flush]" in commit,
        "The busy row must be laid out and explicitly flushed to the render server; a main-queue hop alone does not commit a visible frame.")

print("Export busy-render regression checks passed")
