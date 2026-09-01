#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "TranscriptionQueueViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


controller_start = SOURCE.find("@implementation TranscriptionQueueViewController")
start = SOURCE.find("- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:", controller_start)
end = SOURCE.find("\n- (NSString*)_updateCellStatus", start)
require(start != -1 and end != -1, "Missing transcription queue cell configuration.")
cell = SOURCE[start:end]

require(
    "cell.accessibilityIdentifier = item.episodeHash" in cell
    and "__weak DownloadsTableViewCell* weakCell" in cell
    and "sender:cell" in cell
    and "strongCell.accessibilityIdentifier" in cell,
    "Transcription artwork completion must verify that the reused cell still represents the same episode hash.",
)


print("Transcription queue artwork-reuse regression checks passed")
