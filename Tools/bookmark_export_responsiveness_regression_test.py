#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONTROLLER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
XPFF = (ROOT / "Classes" / "XPFF.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


serialize = body(XPFF, "NSData* XPFFDataWithBookmarksFilterHashes")
export_start = body(CONTROLLER, "- (void) exportBookmarks")
export = body(CONTROLLER, "- (void)_beginBookmarksExportAfterBusyState")
cell = body(CONTROLLER, "- (UITableViewCell *)tableView:")
present = body(CONTROLLER, "- (void)presentPendingBookmarksExportResultIfNeeded")

require("for(CDBookmark* bookmark in bookmarks)" in serialize and "DMANAGER.bookmarks" not in serialize,
        "XPFF serialization must use exactly the supplied context-safe bookmark snapshot.")
require("XPFFEscapedString" in serialize and "sortedArrayUsingSelector" in serialize,
        "XPFF output must escape optional metadata safely and be deterministic.")
require("anyExportInProgress" in export_start and "QOS_CLASS_UTILITY" in export
        and "newExportBackgroundContext" in export and "executeFetchRequest" in export,
        "Bookmark export must fetch and serialize on the dedicated background export context.")
require("writeToURL:url options:NSDataWritingAtomic error:" in export,
        "Bookmark export must check the atomic file write before presenting it.")
require("bookmarksExportInProgress" in cell and "UIActivityIndicatorView" in cell,
        "The bookmark row must show visible activity and prevent duplicate starts.")
require("pendingBookmarksExportURL" in present and "pendingBookmarksExportError" in present
        and "self.viewIfLoaded.window" in present,
        "Bookmark export UI must wait until its settings controller is visible.")


print("Bookmark export responsiveness regression checks passed")
