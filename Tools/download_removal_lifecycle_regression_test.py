#!/usr/bin/env python3
"""Pins transactional cache-removal semantics and safe replace/observer ordering."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
EPISODE_VIEW = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
PLAYER_INFO = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
AUDIO_SESSION = (ROOT / "Classes" / "AudioSession.m").read_text()
TRANSCRIPTION_QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
EPISODE_MODEL = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()
EPISODE_MODEL_HEADER = (ROOT / "Classes" / "Model" / "CDEpisode.h").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method/function: {signature}")
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
    raise AssertionError(f"Unterminated body: {signature}")


remove_batch = body(
    MANAGER,
    "- (void)_removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes\n"
    "                       automatic:(BOOL)automatic\n"
    "             physicalURLSnapshot:(ICCachePhysicalURLSnapshot*)physicalURLSnapshot\n"
    "                      completion:",
)
finish_files = body(MANAGER, "- (void)_finishCacheFileDeletionForItems:")
complete_deletion = body(MANAGER, "- (void)_completeCacheDeletionForIdentifier:")
destructive_finish = body(MANAGER, "- (NSError*) _finishDestructiveCacheClear")
destructive_delete = body(MANAGER, "- (NSError*) _deleteAllCacheFilesNow")
async_clear = body(MANAGER, "- (void)cancelDownloadsAndClearCacheWithCompletion:")
import_file = body(MANAGER, "- (void) importFileAtURL:")
cached_url = body(MANAGER, "- (NSURL*) URLForCachedEpisode:")
temporary_url = body(MANAGER, "- (NSURL*) tempURLForCachedEpisode:")
fast_cached_lookup = body(MANAGER, "- (BOOL) episodeIsCached:(CDEpisode*)episode fastLookup:")
auto_clear = body(MANAGER, "- (void) autoClearAndMakeRoomForBytes:")
redownload_menu = body(EPISODE_VIEW, "- (UIMenu*) _buildDownloadMenu")
player_clear = body(PLAYER_INFO, "- (void)_invalidateTranscriptStateForCacheNotification:")
audio_clear = body(AUDIO_SESSION, "- (void) _handleEpisodeCacheCleared:")
remove_references = body(DATABASE, "- (void) _removeEpisodeReferences:(CDEpisode*)episode")
player_memory_clear = body(PLAYER_INFO, "- (void)_invalidateTranscriptMemoryCacheForEpisodeHash:")
player_consumed_clear = body(PLAYER_INFO, "- (void)_clearTranscriptCacheIfNeededForEpisode:")
player_observers = body(PLAYER_INFO, "- (void) _setObserving:")
episode_consumed = body(EPISODE_MODEL, "- (void) setConsumed:")

require("completion:(void (^)(NSError* error))completion" in HEADER,
        "Replacement callers need an explicit physical-deletion completion contract.")
require("_cacheDeletionCompletionsByIdentifier" in MANAGER and
        "_completeCacheDeletionForIdentifier" in finish_files and
        "_cacheDeletionCompletionsByIdentifier" in complete_deletion,
        "A second replace request must join the in-flight deletion instead of racing it.")

will_notification_index = remove_batch.find("postNotificationName:CacheManagerWillDeleteCacheFilesNotification")
notification_index = remove_batch.find("postNotificationName:CacheManagerDidClearCacheNotification")
dispatch_index = remove_batch.find("dispatch_async(_cacheDeletionQueue")
require(will_notification_index != -1 and notification_index != -1 and dispatch_index != -1 and
        will_notification_index < dispatch_index and notification_index < dispatch_index and
        '@"episodeHashes"' in remove_batch,
        "The logical state/removal notification must be synchronous and carry exact hashes before file I/O starts.")

redownload_start = redownload_menu.find('redownloadTitle = @"Re-Download".ls')
redownload_section = redownload_menu[redownload_start:]
require(redownload_start != -1 and "CDEpisode* episode = self.episode" in redownload_section and
        "removeCacheForEpisode:episode" in redownload_section and
        "completion:^" in redownload_section and
        redownload_section.find("completion:^") < redownload_section.find("[self _downloadFileForEpisode:episode]"),
        "Re-Download must start only from the old file's physical-deletion completion.")
require("removeCacheForEpisode:episode" in import_file and "completion:^" in import_file and
        "_importFileAtURL:" in import_file,
        "File import must wait for an existing cached file to be physically removed.")

require('@"episodeHashes"' in audio_clear,
        "Batch/feed deletion must stop playback when it contains the playing episode.")
require('NSNotification.Name("CacheManagerWillDeleteCacheFilesNotification")' in TRANSCRIPTION_QUEUE and
        'NSNotification.Name("CacheManagerDidDeleteCacheFilesNotification")' in TRANSCRIPTION_QUEUE and
        'NSNotification.Name("CacheManagerDidRestoreCacheNotification")' in TRANSCRIPTION_QUEUE and
        '"episodeHashes"' in TRANSCRIPTION_QUEUE and
        "CacheManagerDidRemoveCacheNotification" not in TRANSCRIPTION_QUEUE,
        "Transcription must distinguish pre-delete suspension, terminal deletion, and rollback for every hash.")
require('@"episodeHashes"' in player_clear and '@"all"' in player_clear and
        "_removeTranscriptCacheForEpisode:" not in player_clear and "_clearAllTranscriptCache" not in player_clear,
        "The main-thread transcript observer may invalidate memory only; physical cleanup belongs to the utility queue.")
require(
    "+ (void)scheduleTranscriptCacheRemovalForEpisodeHash:(NSString*)episodeHash;" in EPISODE_MODEL_HEADER
    and "[CDEpisode scheduleTranscriptCacheRemovalForEpisodeHash:self.objectHash]" in episode_consumed,
    "Consumed-state cleanup and PlayerInfo healing must share one public background scheduler.",
)
require(
    "_invalidateTranscriptMemoryCacheForEpisodeHash:episode.objectHash" in player_observers
    and "_removeTranscriptCacheForEpisode:episode" not in player_observers
    and "contentsOfDirectoryAtURL:" not in player_memory_clear
    and "removeItemAtURL:" not in player_memory_clear,
    "The synchronous consumed observer may invalidate memory only, never scan or delete transcript files.",
)
require(
    "_invalidateTranscriptMemoryCacheForEpisodeHash:episode.objectHash" in player_consumed_clear
    and "[CDEpisode scheduleTranscriptCacheRemovalForEpisodeHash:episode.objectHash]" in player_consumed_clear
    and "contentsOfDirectoryAtURL:" not in player_consumed_clear,
    "Opening an already-consumed episode must heal disk state through the same background scheduler.",
)
require('@"all" : @YES' in destructive_finish,
        "A destructive clear must be explicit instead of overloading missing notification metadata.")
require("_cacheDeletionTokensByIdentifier" in cached_url and
        "_cacheDeletionTokensByIdentifier" in fast_cached_lookup and
        "if (!cacheURL)" in temporary_url,
        "A logically deleted episode must not be rediscovered from disk while physical deletion is still in flight.")
require("clearTheFuckingCache" not in HEADER and "clearTheFuckingCache" not in MANAGER and
        "dispatch_async(strongSelf->_cacheDeletionQueue" in async_clear and
        "ICCacheFileErrorMeansMissing" in destructive_delete,
        "Full-cache clearing must be async-only, serialize with per-file deletion, and treat a raced missing file as success.")
require("removeCacheForEpisodes:selectedEpisodes" in auto_clear,
        "Storage auto-clear must preserve durable ownership routing and batch unowned episode hashes.")
restore_notification = finish_files.find("postNotificationName:CacheManagerDidRestoreCacheNotification")
token_release = finish_files.find("removeObjectForKey:identifier")
require("CacheManagerDidDeleteCacheFilesNotification" in finish_files and
        restore_notification != -1 and token_release != -1 and token_release < restore_notification,
        "Terminal success/rollback notifications must be distinct, and rollback observers must see the released token.")

require("beginInterruptSaving" not in remove_references and "endInterruptSaving" not in remove_references,
        "Episode deletion must not force CacheManager's transactional save to fail before deleting the Core Data row.")
require("keyPathsForValuesAffectingNumberOfDownloadedBytes" not in MANAGER,
        "Exact asynchronous byte accounting must not also emit a derived KVO change with the stale byte value.")

print("Download removal lifecycle regression checks passed")
