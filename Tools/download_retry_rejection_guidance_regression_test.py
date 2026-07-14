#!/usr/bin/env python3
"""Pins actionable UI feedback for every synchronous failed-download retry rejection."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
CONTROLLER = (ROOT / "Classes" / "DownloadsViewController.m").read_text()
DE = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
EN = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("retryFailedDownloadForEpisode:(CDEpisode*)episode error:(NSError**)error" in HEADER,
        "Retry must expose a checked rejection error to its UI caller.")

retry = body(CACHE, "- (BOOL)retryFailedDownloadForEpisode:")
for state in [
    "_clearingAllCache",
    "_cacheDeletionTokensByIdentifier",
    "_cacheImportTokensByIdentifier",
    "episodeIsCached:",
    "existingOperation.cancelled",
]:
    require(state in retry, f"Retry must resolve or explain the synchronous rejection state: {state}")
require("reportsFailureToUser:NO" in retry
        and "downloadErrorForEpisode:episode" in retry
        and "_recordDownloadError:retryError" in retry
        and "*error =" in retry,
        "Retry failures must be durably updated and returned once to the visible controller instead of becoming a silent NO or duplicate alert.")

action = body(CONTROLLER, "- (void) retryFailedDownload:")
require("NSError* retryError" in action
        and "retryFailedDownloadForEpisode:episode error:&retryError" in action
        and "[self presentError:retryError]" in action,
        "The Retry button must present the concrete synchronous rejection reason.")

keys = [
    "The download cannot be retried while downloaded files are being cleared. Wait for the operation to finish and try again.",
    "The download is still being removed. Wait for the operation to finish and try again.",
    "A file is currently being imported for this episode. Wait for the import to finish and try again.",
    "The previous download attempt is still being cancelled. Wait a moment and try again.",
    "The saved download failure details are no longer available. Close Downloads and start the episode download again.",
]
for key in keys:
    require(f'"{key}" =' in DE and f'"{key}" =' in EN,
            f"Missing localized retry rejection guidance: {key}")

print("Download retry-rejection guidance regression checks passed")
