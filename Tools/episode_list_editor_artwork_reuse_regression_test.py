#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "EpisodeListEditorViewController.m").read_text()
CELL_HEADER = (ROOT / "Classes" / "ICListEditorPodcastCell.h").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(
    "representedFeedIdentifier" in CELL_HEADER,
    "Reusable list-editor podcast cells need an explicit represented-feed identity.",
)

start = SOURCE.find("else if (indexPath.row > 0 && indexPath.row < [self.selectedPodcasts count] + 1)")
end = SOURCE.find("else", start + 10)
require(start != -1 and end != -1, "Missing selected-podcast cell configuration.")
cell_block = SOURCE[start:end]
require(
    "cell.representedFeedIdentifier" in cell_block
    and "__weak ICListEditorPodcastCell* weakCell" in cell_block
    and "sender:cell" in cell_block
    and "strongCell.representedFeedIdentifier" in cell_block,
    "Artwork completion must verify that the reusable cell still represents the requested feed.",
)


print("Episode-list editor artwork-reuse regression checks passed")
