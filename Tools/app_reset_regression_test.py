#!/usr/bin/env python3
"""Pins an ordered, non-blocking and truthfully reported factory reset."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_H = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE_M = (ROOT / "Classes" / "CacheManager.m").read_text()
RESET = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
SYNC = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
DB_H = (ROOT / "Classes" / "Model" / "DatabaseManager.h").read_text()
DB_M = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
IMAGE_CACHE = (ROOT / "Classes" / "ImageCacheManager.m").read_text()
IMAGE_CACHE_H = (ROOT / "Classes" / "ImageCacheManager.h").read_text()
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(),
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("cancelDownloadsAndClearCacheWithCompletion" in CACHE_H and
        "cancelDownloadsAndClearCacheWithCompletion" in CACHE_M,
        "Factory reset needs one CacheManager API that cancels active work and clears only after terminal callbacks.")
cache_clear_start = CACHE_M.find("- (void)cancelDownloadsAndClearCacheWithCompletion")
cache_clear_end = CACHE_M.find("\n- (void)", cache_clear_start + 1)
cache_clear = CACHE_M[cache_clear_start:cache_clear_end]
require("CacheManagerDidEndCachingNotification" in cache_clear and
        "[strongSelf cancelCaching]" in cache_clear and
        "beginDeletion" in cache_clear,
        "Active downloads must be cancelled and awaited by lifecycle event, not by a delay or an ignored BOOL.")
require("QOS_CLASS_UTILITY" in CACHE_M and "_deleteAllCacheFilesNow" in CACHE_M,
        "Mass filesystem deletion must run off the main thread.")
require("_clearingAllCache" in CACHE_M,
        "New automatic downloads must be gated while a destructive clear is in progress.")
require("prepareForLocalAppResetWithCompletion" in SYNC,
        "Factory reset must stop iCloud tasks/outbox capture before local deletions can become cloud tombstones.")
require("resetAllUserDataWithCompletion" in DB_H and "resetAllUserDataWithCompletion" in DB_M,
        "Factory reset must delete every user-data entity, not merely unsubscribe feeds.")
for entity in ("Feed", "Episode", "Bookmark", "EpisodeList", "Playlist", "AppleWatchEpisodeState", "ICCloudSyncOutboxEntry", "ICCloudPendingEpisodeState"):
    require(f'@"{entity}"' in DB_M.split("resetAllUserDataWithCompletion", 1)[1],
            f"Factory reset is missing the {entity} entity.")
require("NSBatchDeleteRequest" in DB_M and "mergeChangesFromRemoteContextSave" in DB_M,
        "Large factory resets must use background batch deletion and merge object-ID changes into the UI context.")
image_clear = IMAGE_CACHE.split("- (BOOL) clearTheFuckingCache", 1)[1].split("@end", 1)[0]
require("error:" in image_clear and "return NO" in image_clear,
        "Image-cache deletion must report filesystem failures instead of always claiming success.")
require("cancelImageDownloadsAndClearCache" in IMAGE_CACHE_H and
        "cancelImageDownloadsAndClearCache" in IMAGE_CACHE,
        "Factory reset needs an image-cache API that owns cancellation and deletion.")
reset_image_clear = IMAGE_CACHE.split("- (BOOL)cancelImageDownloadsAndClearCache", 1)[1].split("@end", 1)[0]
require("cancelAllOperations" in reset_image_clear and "waitUntilAllOperationsAreFinished" in reset_image_clear,
        "Factory reset must stop in-flight image writes before deleting the image cache.")

for localization in LOCALIZATIONS:
    for key in (
        "The local app data could not be opened for reset.",
        "The local app data could not be completely deleted. Please try the reset again.",
        "Cached images could not be deleted. No local database data was reset.",
    ):
        require(f'"{key}" =' in localization,
                f"Factory-reset error text is not localized: {key}")

start = RESET.find("- (void) performAppReset")
end = RESET.find("- (void)_showResetCompleteAlert", start)
method = RESET[start:end]
require("cancelDownloadsAndClearCacheWithCompletion" in method,
        "App reset must use the ordered cache-clear completion instead of calling the synchronous legacy method.")
require(method.find("cancelDownloadsAndClearCacheWithCompletion") < method.find("removePersistentDomainForName"),
        "Settings and database data must not be destroyed until cache cancellation/deletion succeeded.")
require(method.find("prepareForLocalAppResetWithCompletion") < method.find("resetAllUserDataWithCompletion"),
        "iCloud must be quiesced before subscriptions are removed locally.")
require("if (error)" in method and "_showResetError" in method,
        "A cache or database failure must be shown and must not fall through to Reset Complete.")
require("resetAllUserDataWithCompletion" in method and "cancelImageDownloadsAndClearCache" in method,
        "Reset must await complete local-database and image-cache deletion before reporting success.")
require("exit(0)" not in RESET,
        "The app must never terminate itself after reset; iOS reports programmatic exit like a crash.")

print("App reset regression checks passed")
