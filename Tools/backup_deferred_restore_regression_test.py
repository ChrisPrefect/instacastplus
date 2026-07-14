#!/usr/bin/env python3
"""Pins durable, bounded retry semantics for deferred backup restore work."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
HEADER = (ROOT / "Classes" / "InstacastBackupImporter.h").read_text()
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
CACHE_HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
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


require("downloads.plist" in SOURCE and "ICBackupDownloadStageURL" in SOURCE,
        "Deferred downloads must live in a durable Application Support stage, not only in UserDefaults.")
require("NSPropertyListBinaryFormat_v1_0" in SOURCE
        and "NSDataWritingAtomic" in SOURCE
        and "NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication" in SOURCE,
        "The deferred-download stage must be a protected atomic binary property list.")
require("NSURLIsExcludedFromBackupKey" in SOURCE,
        "Transient backup-import recovery state must be excluded from device backups.")
require("setObject:pendingDownloads forKey:kPendingBackupDownloadsKey" not in SOURCE
        and "setObject:remaining forKey:kPendingBackupDownloadsKey" not in SOURCE,
        "Thousands of deferred episode GUIDs must not be written back to UserDefaults.")

migration_start = SOURCE.find("ICBackupMigrateLegacyPendingDownloads")
require(migration_start >= 0, "Existing pending-download UserDefaults data needs a one-time durable migration.")
migration = SOURCE[migration_start:SOURCE.find("\n}\n", migration_start) + 3]
require("objectForKey:kPendingBackupDownloadsKey" in migration
        and "ICBackupWriteDownloadStage" in migration
        and "removeObjectForKey:kPendingBackupDownloadsKey" in migration,
        "Legacy data may be removed only through the explicit stage migration path.")
require(migration.find("ICBackupWriteDownloadStage") < migration.find("removeObjectForKey:kPendingBackupDownloadsKey"),
        "The durable stage write must win the crash race before legacy UserDefaults data is removed.")

require("startDeferredRestoreRecovery" in HEADER and "retryPendingDeferredRestoreIfNeeded" in HEADER,
        "Deferred restore needs explicit startup and foreground lifecycle entry points.")
require("startDeferredRestoreRecovery" in APP
        and "retryPendingDeferredRestoreIfNeeded" in APP
        and "retryPendingDeferredRestoreIfNeeded" in SCENE,
        "Startup, protected-data availability, and scene foregrounding must retry durable deferred work.")

observer_start = SOURCE.find("+ (void)startDeferredRestoreRecovery")
require(observer_start >= 0, "Deferred restore must register its episode-hydration observers once.")
observer = SOURCE[observer_start:SOURCE.find("#pragma mark", observer_start)]
require("EpisodeLoadingManagerDidLoadBatchNotification" in observer
        and "EpisodeLoadingManagerDidFinishLoadingNotification" in observer
        and "CacheManagerDidFinishCachingEpisodeNotification" in observer,
        "Hydration batches/finish and physical download completion must trigger a deferred retry.")
require("_deferredRestoreScheduled" in SOURCE and "_deferredRestoreAllFeeds" in SOURCE,
        "Hydration notifications must be coalesced and scoped instead of launching overlapping full-library work.")

cancel_prepare_start = SOURCE.find("+ (void)prepareForDeferredDownloadCancellation:")
cancel_prepare_end = SOURCE.find("#pragma mark", cancel_prepare_start)
require(cancel_prepare_start >= 0 and cancel_prepare_end > cancel_prepare_start,
        "CacheManager needs an asynchronous durable cancellation handshake with the backup stage.")
cancel_prepare = SOURCE[cancel_prepare_start:cancel_prepare_end]
require("ICBackupWriteDownloadCancellationTombstone" in cancel_prepare
        and "ICBackupImportQueue() addOperation" in cancel_prepare
        and "dispatch_async(dispatch_get_main_queue()" in cancel_prepare,
        "Cancellation must commit its tombstone on the serial utility queue before completing on main.")

processor = method_body(SOURCE, "+ (void)_processPendingDeferredRestoreForFeedURLs:")
require(processor,
        "Downloads and Now Playing need one serialized deferred processor.")
require("newBackgroundContext" in processor
        and "fetchBatchSize" in processor
        and 'predicateWithFormat:@"guid IN %@"' in processor,
        "Deferred episode resolution must use bounded indexed background Core Data fetches.")
require("dispatch_sync(dispatch_get_main_queue()" in processor,
        "Only the small CacheManager/AudioSession handoff may cross back to the main thread.")
require("episodeIsCached:" in processor and "isCachingEpisode:" in processor,
        "A crash replay must deduplicate already cached and already queued episodes.")
require("ICBackupWriteDownloadStage" in processor
        and "cancelledDownloadHashes" in processor
        and "resolvedDownloadKeys" in processor,
        "Only a physical cache hit or durable cancellation tombstone may advance the pending stage.")
require(processor.find("ICBackupWriteDownloadStage") < processor.find("ICBackupRemoveDownloadCancellationTombstones"),
        "Cancellation tombstones may disappear only after the updated pending stage is durably committed.")
cancel_owner_confirmation = processor.find("completeDeferredRestoreCancellationForObjectHash")
require(cancel_owner_confirmation >= 0
        and cancel_owner_confirmation < processor.find("ICBackupWriteDownloadStage"),
        "The CacheManager queue descriptor must be removed after the tombstone commit and before stage cleanup.")
require("- (BOOL)completeDeferredRestoreCancellationForObjectHash:" in CACHE_HEADER
        and "queueOwnerRemoved = [cacheManager completeDeferredRestoreCancellationForObjectHash:" in processor,
        "Stage cleanup must wait until CacheManager confirms that the indexed runtime owner is actually gone.")
require("remainingDownloads" in processor,
        "Missing feeds, episodes, and media URLs must remain staged for a later hydration retry.")
require("deferredMainBatchSize" in processor and "NSMaxRange(batchRange)" in processor,
        "Thousands of CacheManager handoffs must be split into bounded main-thread batches.")

require("_downloadOperationsByIdentifier[identifier]" in CACHE and "_persistCachingOperation:cacheOperation" in CACHE,
        "The CacheManager contract used for replay must remain deduplicated and durable.")
cancel = method_body(CACHE, "- (void)_cancelCachingEpisode:")
require("prepareForDeferredDownloadCancellation" in cancel
        and "ownsDeferredDownloadWithObjectHash" in cancel
        and "_cancelCachingEpisodeAfterDurableIntent" in cancel,
        "The public cancel path must wait for the durable restore-intent revocation handshake.")
require(cancel.find("ownsDeferredDownloadWithObjectHash") < cancel.find("prepareForDeferredDownloadCancellation"),
        "Ordinary downloads must bypass backup persistence and keep their immediate cancel path.")
cancel_commit = method_body(CACHE, "- (void)_cancelTrackedDownloadOperationAfterDurableIntent:")
require("_removeSavedCachingInfoForIdentifier" in cancel_commit and "[operation cancel]" in cancel_commit,
        "Only the post-commit cancel path may remove the persistent queue descriptor and operation.")
terminal = method_body(CACHE, "- (void)_finishCacheOperationDidEnd:")
require("operation.cancelled" in terminal
        and "ownsDeferredDownloadWithObjectHash" in terminal
        and "retryPendingDeferredRestoreIfNeeded" in terminal,
        "An executing deferred download must retry tombstone cleanup after its terminal callback removes the owner.")
require("writeToURL" not in cancel and "contentsOf" not in cancel,
        "CacheManager cancellation must never perform filesystem I/O on the main thread.")

now_playing = processor[processor.find("pendingNowPlaying"):]
require("restorePlaybackEpisode:" in now_playing and "removeObjectForKey:kPendingNowPlayingKey" in now_playing,
        "Resolved pending Now Playing state must be restored and then cleared.")
successful_restore = now_playing[now_playing.find("double position"):]
require(successful_restore.find("restorePlaybackEpisode:")
        < successful_restore.find("removeObjectForKey:kPendingNowPlayingKey"),
        "Now Playing must be handed to AudioSession before its durable pending state is cleared.")
require("doubleValue" in now_playing,
        "Deferred playback positions must not be truncated to 32-bit integer seconds.")

finder_start = SOURCE.find("+ (CDEpisode *)findEpisodeWithGuid:")
finder = SOURCE[finder_start:]
require("fetchLimit = 1" in finder and 'guid == %@ AND feed == %@' in finder,
        "The non-import fallback must use one bounded indexed fetch.")
require("feed.episodes" not in finder,
        "The fallback must never scan every episode relationship once the import GUID index is gone.")

require("cat == ICBackupImportBookmarks || cat == ICBackupImportDownloads" in SOURCE,
        "Building and writing a large deferred-download stage must stay off the main thread.")

print("Backup deferred-restore regression checks passed")
