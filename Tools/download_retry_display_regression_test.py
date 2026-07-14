#!/usr/bin/env python3
"""Pins one active-first row while asynchronous failed-download cleanup finishes."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "DownloadsViewController.m").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
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


rebuild = method_body("- (void) _rebuildDisplayEpisodes")
active_loop = rebuild.find("for (CDEpisode* episode in activeEpisodes)")
active_count = rebuild.find("self.activeDownloadCount = episodes.count")
failed_loop = rebuild.find("for (CDEpisode* episode in failedEpisodes)")
require("seenEpisodeIdentities" in rebuild and
        -1 < active_loop < active_count < failed_loop,
        "The display snapshot must deduplicate active rows first and freeze their section boundary before failed rows.")
require("containsObject:identity" in rebuild[failed_loop:] and "continue;" in rebuild[failed_loop:],
        "A stale failed entry for an active retry must not create a second table row.")

cell = method_body("- (UITableViewCell *)tableView:")
active_state = cell.find("BOOL isActiveDownload = indexPath.row < self.activeDownloadCount")
error_lookup = cell.find("downloadErrorForEpisode:episode", active_state)
require(active_state != -1 and error_lookup != -1 and
        "isActiveDownload ? nil" in cell[active_state:error_lookup + 100],
        "An active retry must render progress even while its asynchronous old error record still exists.")

height = method_body("- (CGFloat)tableView:(UITableView*)tableView heightForRowAtIndexPath:")
height_active_state = height.find("indexPath.row < self.activeDownloadCount")
height_error_lookup = height.find("_failureTextForEpisode", height_active_state)
require(height_active_state != -1 and height_error_lookup != -1 and
        "isActiveDownload ? nil" in height[height_active_state:height_error_lookup + 100],
        "An active retry must also use the normal row height while its old error record still exists.")
require("ICDownloadRetryButtonWidth()" in height and "- 90" not in height,
        "Error-row height must reserve the localized Retry button's real intrinsic width, not a fixed English-sized guess.")
require("ICConfigureDownloadRetryButton(retryButton)" in cell,
        "The cell and row-height calculation must share one Retry button configuration so their widths cannot drift.")

retry = method_body("- (void) retryFailedDownload:(UIButton*)button")
rejection = retry.find("retryFailedDownloadForEpisode:episode error:&retryError")
row_lookup = retry.find("indexOfObjectPassingTest", rejection)
row_reload = retry.find("reloadRowsAtIndexPaths", row_lookup)
present_error = retry.find("presentError:retryError", row_reload)
require(-1 < rejection < row_lookup < row_reload < present_error,
        "A synchronous Retry rejection must reload its existing row before presenting the reason so inline text and height show the new durable error.")

clear_error = CACHE.find("- (void) clearDownloadErrorForEpisode:(CDEpisode*)episode")
delete_journal = CACHE.find("_deletePersistedFailedDownloadForIdentifier", clear_error)
remove_memory = CACHE.find("_downloadErrorsByEpisodeHash removeObjectForKey", delete_journal)
require(-1 < clear_error < delete_journal < remove_memory,
        "The regression proof depends on durable journal deletion completing before in-memory error cleanup.")

print("Download retry display regression checks passed")
