#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SELECTION = (ROOT / "Classes" / "EpisodeListPodcastSelectionTableViewController.m").read_text()
CELL = (ROOT / "Classes" / "ICListEditorPodcastCell.m").read_text()


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


configure = body(SELECTION, "- (UITableViewCell *)tableView:")
reuse = body(CELL, "- (void)prepareForReuse")

require("ICListEditorPodcastCell" in configure and "representedFeedIdentifier" in configure,
        "Podcast selection rows need an explicit feed identity across cell reuse.")
require('imageNamed:@"Podcast Placeholder 56"' in configure and "imageForURL:" in configure,
        "A missing disk image must show a placeholder and start the asynchronous image request.")
require("sender:cell" in configure and "strongCell.representedFeedIdentifier" in configure,
        "Artwork completion must be owned by the cell and reject results for its previous feed.")
require("cancelImageCacheOperationsWithSender:self" in reuse and "representedFeedIdentifier = nil" in reuse,
        "Reused podcast cells must cancel obsolete artwork work and clear their identity.")


print("Episode-list podcast-selection artwork regression checks passed")
