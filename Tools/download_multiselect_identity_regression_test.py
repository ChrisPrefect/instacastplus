#!/usr/bin/env python3
"""Keep a delayed multi-select download bound to the selected episodes."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


download = method_body("- (void) downloadSelection:")
prompt = download.find("_askUserForCellularDownloadIfNecessary:")
capture = download.find("NSMutableArray<CDEpisode*>* selectedEpisodes")
require(
    capture != -1 and prompt != -1 and capture < prompt
    and "[selectedEpisodes addObject:episode]" in download[:prompt],
    "Multi-select download must capture episode identities before presenting cellular confirmation.",
)

completion = download[prompt:]
require(
    "for (CDEpisode* episode in selectedEpisodes)" in completion
    and "cacheEpisode:episode" in completion,
    "Delayed confirmation must download the captured episodes, not whichever rows exist later.",
)
require(
    "objectAtIndex:selectedIndexPath.row" not in completion
    and "self.episodes[selectedIndexPath.row]" not in completion,
    "The cellular-confirmation callback must not re-read mutable rows.",
)
require(
    "indexPathsForVisibleRows" in completion
    and "containsObject:currentEpisode" in completion
    and "reloadRowsAtIndexPaths:currentIndexPaths" in completion,
    "Only visible current rows resolved from captured identities may be reloaded after confirmation.",
)
require(
    "_indexPathForEpisode:episode" not in completion,
    "Large selections must not linearly search the whole episode list once per selected episode.",
)

# Deterministic proof of the former row/identity mismatch and bounds crash.
episodes = ["A", "B"]
selected_rows = [1]
captured_episodes = [episodes[row] for row in selected_rows]
episodes.insert(0, "X")
require(captured_episodes == ["B"] and episodes[selected_rows[0]] == "A",
        "The fixture must distinguish stable identity from a shifted row.")
episodes = ["A"]
require(selected_rows[0] >= len(episodes) and captured_episodes == ["B"],
        "A removed tail row must be unsafe only for the obsolete index-path implementation.")

print("Multi-select download identity regression checks passed")
