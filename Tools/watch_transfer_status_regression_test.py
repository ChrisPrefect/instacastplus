#!/usr/bin/env python3
"""Pins honest Watch transfer phases for offline, queued, and active downloads."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "AppleWatchSyncManager.h").read_text()
MANAGER = (ROOT / "Classes" / "AppleWatchSyncManager.m").read_text()
CONTROLLER = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
DE = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
EN = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
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


require("typedef NS_ENUM(NSInteger, ICAppleWatchTransferPhase)" in HEADER
        and "ICAppleWatchTransferPhaseWaiting" in HEADER
        and "ICAppleWatchTransferPhaseDownloading" in HEADER,
        "The phone UI needs an explicit Watch waiting/downloading phase instead of a boolean incomplete flag.")

require("totalBytesKnown:(BOOL* _Nullable)outTotalBytesKnown" in HEADER,
        "The aggregate progress API must tell the phone whether every unfinished download has a known total size.")

progress = method_body(MANAGER, "watchDownloadProgressLoadedBytes:")
contribution = method_body(MANAGER, "- (NSDictionary*)_watchTransferContributionForState:")
require("_liveDownloadProgressForState:" in contribution
        and "ICAppleWatchStatusDownloading" in contribution
        and "ICAppleWatchStatusSelected" in contribution
        and "ICAppleWatchStatusManifestSent" in contribution
        and "ICAppleWatchStatusQueuedOnWatch" in contribution
        and "ICAppleWatchTransferPhaseDownloading" in progress
        and "ICAppleWatchTransferPhaseWaiting" in progress,
        "Transient Watch progress (plus legacy durable downloading) must report downloading; "
        "pre-delivery states must remain waiting.")
require("ICAppleWatchTransferTotalKnownKey" in contribution
        and "cachedWatchTransferUnknownTotalCount" in progress
        and "*outTotalBytesKnown = (self.cachedWatchTransferUnknownTotalCount == 0)" in progress,
        "One unfinished episode without an expected size must mark the entire byte total as unknown.")

status = method_body(CONTROLLER, "- (NSString*)_statusTextForManager:")
downloading = status.find("ICAppleWatchTransferPhaseDownloading")
waiting = status.find("ICAppleWatchTransferPhaseWaiting")
require(-1 < downloading < waiting
        and '"Watch lädt Podcasts…".ls' in status
        and '"Wartet auf Apple Watch…".ls' in status,
        "The Watch page must prioritize real progress and otherwise explain that delivery is waiting for the Watch.")
require("BOOL totalBytesKnown = NO" in status
        and "totalBytesKnown:&totalBytesKnown" in status
        and "if (totalBytesKnown && totalBytes > 0)" in status,
        "The phone must show x/y bytes only when the aggregate total includes every unfinished Watch download.")

require('"Wartet auf Apple Watch" = "Wartet auf Apple Watch";' in DE
        and '"Wartet auf Apple Watch" = "Waiting for Apple Watch";' in EN
        and '"Watch lädt Podcasts" = "Watch lädt Podcasts…";' in DE
        and '"Watch lädt Podcasts" = "Watch is downloading podcasts…";' in EN,
        "Both Watch transfer phases need complete German and English labels.")

print("Watch transfer-status regression checks passed")
