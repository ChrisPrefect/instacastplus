#!/usr/bin/env python3
"""Pins Re-Download to the selected episode and terminal deletion outcome."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "EpisodeViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
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


download_current = body("- (void) _downloadFile")
download_selected = body("- (void) _downloadFileForEpisode:")
require("_downloadFileForEpisode:self.episode" in download_current and
        "cacheEpisode:episode" in download_selected and
        "cacheEpisode:self.episode" not in download_selected,
        "Delayed cellular confirmation and Re-Download must retain the originally selected episode.")

menu = body("- (UIMenu*) _buildDownloadMenu")
redownload = menu.split('redownloadTitle = @"Re-Download".ls', 1)[1].split("UIAction* deleteAction", 1)[0]
capture = redownload.find("CDEpisode* episode = self.episode")
remove = redownload.find("removeCacheForEpisode:episode")
completion = redownload.find("completion:^(NSError* error)")
restart = redownload.find("_downloadFileForEpisode:episode")
require(capture != -1 and remove != -1 and completion != -1 and restart != -1 and
        capture < remove < completion < restart,
        "Re-Download must remove and restart the immutable episode captured by the menu action.")
require("removeCacheForEpisode:self.episode" not in redownload and
        "[self _downloadFile]" not in redownload,
        "Navigation during asynchronous deletion must not redirect the completion to a different episode.")
before_completion = redownload[:completion]
require("[[AudioSession sharedAudioSession] stop]" not in before_completion,
        "Playback must not be stopped before CacheManager confirms the deletion transaction can commit.")
require("isEqualToString:episodeHash" in redownload,
        "Only the still-visible episode screen may refresh its controls after the captured episode was removed.")

print("Download Re-Download identity regression checks passed")
