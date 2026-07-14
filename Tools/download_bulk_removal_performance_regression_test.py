#!/usr/bin/env python3
"""Pins batched, non-blocking removal for large download libraries."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
MEDIA = (ROOT / "Classes" / "MediaFilesViewController.m").read_text()
IMAGE_HEADER = (ROOT / "Classes" / "ImageCacheManager.h").read_text()
IMAGE_MANAGER = (ROOT / "Classes" / "ImageCacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = source.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


media_clear = body(MEDIA, "- (void) clearCacheAction:")
auto_clear = body(MANAGER, "- (void) autoClearAndMakeRoomForBytes:")

require("removeCacheForEpisodes:" in HEADER and "removeCacheForEpisodes:" in MANAGER,
        "Bulk UI actions need a public one-save/one-I/O-batch removal entry point.")
require("removeCacheForEpisodes:" in media_clear and
        "removeCacheForEpisode:episode" not in media_clear,
        "Delete Played must not perform one main-context save and transcript job per episode.")
require("cancelDownloadsAndClearCacheWithCompletion" in media_clear and
        "clearTheFuckingCache" not in media_clear,
        "Delete All Content must use the asynchronous file-deletion API instead of blocking the main thread.")
require("Currently Downloading" not in media_clear and
        "Current downloads will be cancelled before all downloaded files are deleted." in media_clear,
        "The clear-all action must remain reachable during downloads and explain that they will be cancelled.")
require("cancelImageDownloadsAndClearCacheWithCompletion" in IMAGE_HEADER and
        "QOS_CLASS_UTILITY" in IMAGE_MANAGER and
        "cancelImageDownloadsAndClearCacheWithCompletion" in media_clear,
        "Bulk image-cache cleanup must also leave the main thread free.")

require("_autoClearSelectionInFlight" in MANAGER and
        "dispatch_async(_cacheDeletionQueue" in auto_clear and
        "removeCacheForEpisodes:selectedEpisodes" in auto_clear,
        "Storage-limit eviction must size files off-main and submit unowned files as one logical deletion batch.")
require("attributesOfItemAtPath" not in auto_clear and
        "removeCacheForEpisode:" not in auto_clear,
        "Storage-limit selection must not stat or save once per episode on the main thread.")

print("Download bulk-removal performance regression checks passed")
