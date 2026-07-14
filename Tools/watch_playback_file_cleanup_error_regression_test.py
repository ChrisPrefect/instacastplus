#!/usr/bin/env python3
"""Pins visible, retryable Watch cleanup after a damaged playback file cannot be deleted."""

from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EPISODE = (ROOT / "InstacastWatch" / "WatchEpisode.swift").read_text()
DOWNLOADS = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
VIEWS = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()
CONNECTIVITY = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()
ENGLISH = (ROOT / "InstacastWatch" / "en.lproj" / "Localizable.strings").read_text()
GERMAN = (ROOT / "InstacastWatch" / "de.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


require("var hasPlaybackFileRemovalError: Bool" in EPISODE
        and "status == .downloaded" in EPISODE
        and "localFileURL != nil" in EPISODE
        and "lastError" in EPISODE,
        "A persisted downloaded+file+error state needs one explicit cleanup-error identity.")

record_failure = body(DOWNLOADS, "private func recordPlaybackFileRemovalFailure(")
cleanup_key = "Die defekte Audiodatei konnte nicht entfernt werden. Tippe, um es erneut zu versuchen."
require("NSLocalizedString(" in record_failure
        and f'"{cleanup_key}"' in record_failure
        and "clearReportedTerminalDownloadState" in record_failure,
        "A physical deletion failure must persist actionable guidance and revoke stale success transfers.")

remove_file = body(DOWNLOADS, "func removePlaybackFile(")
require("disposition == .queued ? nil : error" in remove_file,
        "A successful cleanup retry must clear the old error before redownloading.")

retry_cleanup = body(DOWNLOADS, "func retryPlaybackFileRemoval(hash:")
require("hasPlaybackFileRemovalError" in retry_cleanup
        and "await self.removePlaybackFile(" in retry_cleanup
        and "disposition: .queued" in retry_cleanup
        and retry_cleanup.find("guard removed") < retry_cleanup.find("prioritizeEpisode(hash: hash)"),
        "Retry must delete and durably queue the damaged file before starting a replacement download.")

tap = body(VIEWS, "private func handleTap(_ episode:")
require("episode.hasPlaybackFileRemovalError" in tap
        and "retryPlaybackFileRemoval" in tap
        and tap.find("hasPlaybackFileRemovalError") < tap.find("WatchPlayerController.shared.play(episode)"),
        "Tapping a cleanup error must never reopen the same damaged file.")
row_item = body(VIEWS, "private struct WatchEpisodeListItemView")
require("onTap(episode)" in row_item,
        "The row-scoped list item must route taps through the guarded cleanup/play handler.")
status_line = body(VIEWS, "private var statusLine:")
require("hasPlaybackFileRemovalError" in status_line
        and "exclamationmark.triangle.fill" in status_line
        and ".orange" in status_line
        and ".lineLimit(3)" in status_line,
        "A downloaded cleanup error must be visible and readable instead of showing normal playback text.")

report = body(CONNECTIVITY, "func reportTerminalDownloadState(forEpisodeHash")
signature = body(CONNECTIVITY, "private func terminalStateSignature(for episode:")
require("!episode.hasPlaybackFileRemovalError" in report
        or "!episode.hasPlaybackFileRemovalError" in signature,
        "A cleanup-error episode must never be replayed to the phone as watch.downloaded.")

require(f'"{cleanup_key}" = "The damaged audio file could not be removed. Tap to retry.";' in ENGLISH,
        "English Watch cleanup guidance is missing.")
require(f'"{cleanup_key}" = "{cleanup_key}";' in GERMAN,
        "German Watch cleanup guidance is missing.")


@dataclass
class CleanupState:
    downloaded: bool = True
    file_present: bool = True
    cleanup_error: bool = True
    play_count: int = 0
    download_start_count: int = 0

    def tap(self, deletion_succeeds: bool) -> None:
        if self.cleanup_error:
            if deletion_succeeds:
                self.file_present = False
                self.downloaded = False
                self.cleanup_error = False
                self.download_start_count += 1
            return
        self.play_count += 1


state = CleanupState()
state.tap(deletion_succeeds=False)
require(state.cleanup_error and state.file_present and state.play_count == 0,
        "A failed cleanup retry must remain visible and must not play the damaged file.")
state.tap(deletion_succeeds=True)
require(not state.cleanup_error and not state.file_present
        and state.download_start_count == 1 and state.play_count == 0,
        "A successful cleanup must start exactly one replacement download without playback.")

print("Watch playback-file cleanup error regression checks passed")
