#!/usr/bin/env python3
"""While a swipe action is open, nothing may touch the table view.

Background events (downloads, playback changes, watch sync, transcription queue)
used to run reloadData or a pass over all visible cells while the user was still
dragging a row. UIKit owns the cell layout during that gesture, so every such
update tears the swipe down mid-drag — that was the reported stutter.

Each list therefore has to gate its update paths on an active swipe and replay
the strongest pending update in didEndEditingRowAtIndexPath:.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def source(name: str) -> str:
    return (ROOT / "Classes" / name).read_text()


def body(text: str, signature: str) -> str:
    require(signature in text, f"Missing method: {signature}")
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:index]
    raise SystemExit(f"Unterminated method: {signature}")


GATED_LISTS = {
    # EpisodesTableViewController is the base class of the feed and smart-list
    # episode lists, so the gate covers both.
    "EpisodesTableViewController.m": [
        "_playbackEpisodeDidChange:",
        "_appleWatchEpisodeStatesDidChange:",
        "_transcriptionQueueChanged",
        "_updateVisiblePlaylistIndicators",
        "_performPlayComboButtonUpdate",
        "reloadDataAndPreserveSelection",
        "updateAppearance",
    ],
    "UpNextTableViewController.m": [
        "playbackManagerDidChangeEpisodeNotification:",
        "_performPlayComboButtonUpdate",
        "updateAppearance",
    ],
    "AppleWatchEpisodesViewController.m": [
        "_reloadDataFromManager",
        "_reloadVisibleRowsForEpisodeHashes:",
    ],
    "TranscriptionQueueViewController.m": [],
    "DownloadsViewController.m": [
        "_setObserving:",
        "updateAppearance",
    ],
    "PlayerInfoViewController_v5.m": [
        "_setObserving:",
    ],
}

for filename, gated_methods in GATED_LISTS.items():
    text = source(filename)
    require("willBeginEditingRowAtIndexPath:" in text,
            f"{filename} does not notice the start of a swipe.")
    require("didEndEditingRowAtIndexPath:" in text,
            f"{filename} never releases the swipe gate.")
    require("swipeInteractionActive" in text,
            f"{filename} has no swipe gate.")
    for method in gated_methods:
        # Signatures differ in spacing, so locate the definition line itself and take
        # everything up to the next top-level method.
        lines = text.splitlines()
        section = None
        for index, line in enumerate(lines):
            if line.startswith("- (") and method in line:
                end = len(lines)
                for follow in range(index + 1, len(lines)):
                    if lines[follow].startswith("- (") or lines[follow].startswith("@end"):
                        end = follow
                        break
                section = "\n".join(lines[index:end])
                break
        require(section is not None, f"{filename}: method {method} not found.")
        require("swipeInteractionActive" in section or "_deferTableUpdateDuringSwipe" in section,
                f"{filename}: {method} still updates the table while a swipe is open.")

# The gate must be released explicitly when an action fires; UIKit does not
# reliably deliver didEndEditingRowAtIndexPath: before the action's own updates.
for filename in ["EpisodesTableViewController.m",
                 "UpNextTableViewController.m",
                 "AppleWatchEpisodesViewController.m",
                 "DownloadsViewController.m",
                 "PlayerInfoViewController_v5.m"]:
    text = source(filename)
    require(text.count("_endSwipeInteractionAndFlushDeferredUpdate") >= 3,
            f"{filename} does not release the swipe gate from its swipe action handlers.")

# ICTintColor is read from cell layout. Resolving it from NSUserDefaults per access
# was measured at ~123 µs (vs ~0.2 µs) whenever the stored hex was not canonical.
appearance = source("ICAppearanceManager.m")
require("ICResolvedThemeTintColor" in appearance and "gCachedThemeTintColor" in appearance,
        "The theme tint color is resolved from NSUserDefaults on every access again.")
for invalidator in ["- (void) updateAppearance", "- (void)updateThemeTintColor"]:
    require("ICInvalidateThemeTintColorCache" in body(appearance, invalidator),
            f"{invalidator} does not invalidate the cached theme tint color.")
require(appearance.count("ic_colorFromDefaults:") == 1,
        "Appearance code resolves the stored theme color outside the cached accessor.")

print("List swipe update gate regression checks passed")
