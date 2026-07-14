#!/usr/bin/env python3
"""Pins a reachable backup-import progress UI in compact windows and Dynamic Type."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "ICBackupImportProgressView.h").read_text()
SOURCE = (ROOT / "Classes" / "ICBackupImportProgressView.m").read_text()
CALLER = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("showInWindow:" in HEADER and "showInWindow:self.view.window" in CALLER,
        "The progress overlay must attach to the importing controller's scene window.")
require("App.ic_keyWindow" not in SOURCE and "[UIScreen mainScreen].bounds" not in SOURCE,
        "Progress geometry and presentation must not use global screen/key-window state.")
require("initWithFrame:CGRectZero" in SOURCE,
        "The overlay must derive its size from its actual window constraints.")

require("bodyScrollView.contentLayoutGuide" in SOURCE and
        "bodyScrollView.frameLayoutGuide" in SOURCE,
        "Status, feeds, and metadata need one correctly constrained vertical scroll viewport.")
for arranged_view in ("_statusLabel", "_feedStack", "separator", "_metadataStack"):
    require(f"[_bodyStack addArrangedSubview:{arranged_view}]" in SOURCE,
            f"{arranged_view} must be reachable in the shared scroll body.")

require("_statusLabel.numberOfLines = 0" in SOURCE and
        "_statusLabel.lineBreakMode = NSLineBreakByWordWrapping" in SOURCE,
        "Long localized progress status must wrap instead of truncating.")
metadata_section = SOURCE.split("@implementation _ICMetadataRowView", 1)[1].split("@end", 1)[0]
require("_titleLabel.numberOfLines = 0" in metadata_section,
        "Metadata titles must support Dynamic Type wrapping.")
require("constraintGreaterThanOrEqualToConstant:24" in metadata_section and
        "constraintEqualToConstant:24" not in metadata_section,
        "Metadata rows need a minimum height, not a clipping fixed height.")

for edge in ("leadingAnchor", "trailingAnchor", "topAnchor", "bottomAnchor"):
    require(f"safeArea.{edge}" in SOURCE,
            f"The progress card is not bounded by the window safe-area {edge}.")
require("constraintLessThanOrEqualToConstant:340" in SOURCE,
        "340pt must be a maximum/preferred card width, not a required width.")
require("preferredCardWidth.priority = UILayoutPriorityDefaultHigh" in SOURCE,
        "The 340pt card width needs a breakable preference for 320pt windows.")

print("Backup progress layout regression checks passed")
