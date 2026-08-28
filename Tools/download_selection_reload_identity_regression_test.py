#!/usr/bin/env python3
"""Keep edit-mode selection bound to episodes while a filtered list reloads."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ListEpisodesTableViewController.m").read_text()


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


require(
    "pendingSelectedEpisodeObjectIDs" in SOURCE,
    "A paged list reload must retain selected episode identities until their page returns.",
)

update = method_body("- (void) updateEpisodes")
capture_position = update.find("_captureSelectedEpisodeObjectIDsForReload")
reset_position = update.find("self.loadedEpisodes =")
require(
    capture_position != -1
    and reset_position != -1
    and capture_position < reset_position,
    "Selected episode identities must be captured before updateEpisodes clears the backing array.",
)

capture = method_body("- (void) _captureSelectedEpisodeObjectIDsForReload")
require(
    "indexPathsForSelectedRows" in capture
    and "self.episodes" in capture
    and "episode.objectID" in capture,
    "Selection capture must resolve current rows to stable Core Data object IDs.",
)
require(
    "deselectRowAtIndexPath" in capture,
    "Obsolete selected index paths must be cleared before the list is rebuilt.",
)

restore = method_body(
    "- (void) _restorePendingEpisodeSelectionFromPage:(NSArray<CDEpisode*>*)pageEpisodes"
)
require(
    "episode.objectID" in restore
    and "pendingSelectedEpisodeObjectIDs" in restore
    and "selectRowAtIndexPath" in restore,
    "Returned pages must restore selection by episode identity, never by the old row.",
)
require(
    "oldCount + index" in restore,
    "Selection restoration must translate a page-relative match to its current table row.",
)

load_page = method_body("- (void) _loadNextPage")
episodes_position = load_page.find("self.episodes = self.loadedEpisodes")
restore_position = load_page.find("_restorePendingEpisodeSelectionFromPage:pageEpisodes")
require(
    episodes_position != -1
    and restore_position != -1
    and episodes_position < restore_position,
    "Selection may only be restored after the returned page is installed as the data source.",
)

# Deterministic proof of the row/identity mismatch from the customer report.
before = ["A", "B", "C"]
selected_rows = [1]
selected_episode_ids = {before[row] for row in selected_rows}
after_download_finishes = ["B", "C"]
require(
    after_download_finishes[selected_rows[0]] == "C",
    "The fixture must show that preserving row 1 selects the wrong episode.",
)
restored_rows = [
    row
    for row, episode_id in enumerate(after_download_finishes)
    if episode_id in selected_episode_ids
]
require(
    restored_rows == [0] and after_download_finishes[restored_rows[0]] == "B",
    "Stable identity must keep B selected after A disappears.",
)

print("Download selection reload identity regression checks passed")
