#!/usr/bin/env python3
"""Pins deferred-download ownership to the durable backup-stage commit boundary."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text(encoding="utf-8")
IMPORTER_HEADER = (ROOT / "Classes" / "InstacastBackupImporter.h").read_text(encoding="utf-8")
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def block_at(source: str, marker: str, start: int = 0) -> tuple[int, int, str]:
    marker_index = source.find(marker, start)
    require(marker_index >= 0, f"Missing block marker: {marker}")
    brace = source.find("{", marker_index)
    require(brace >= 0, f"Missing block body: {marker}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return marker_index, index + 1, source[brace + 1:index]
    raise AssertionError(f"Unterminated block: {marker}")


processor_start = IMPORTER.find("+ (void)_processPendingDeferredRestoreForFeedURLs:")
processor_end = IMPORTER.find("+ (void)processPendingNowPlaying", processor_start)
require(processor_start >= 0 and processor_end > processor_start,
        "Missing deferred-restore processor.")
processor = IMPORTER[processor_start:processor_end]

write_index = processor.find("stageUpdated = ICBackupWriteDownloadStage(remainingDownloads")
require(write_index >= 0, "Deferred restore must durably update the remaining download stage.")

cached_start = processor.find("if ([cacheManager episodeIsCached:episode])")
cached_end = processor.find("if ([cacheManager isCachingEpisode:episode])", cached_start)
require(cached_start >= 0 and cached_end > cached_start,
        "Missing cached deferred-download branch.")
cached_branch = processor[cached_start:cached_end]

release_matches = list(re.finditer(
    r"ICBackupSetDeferredDownloadOwnership\([^;]+,\s*NO\);",
    processor,
))
release_before_write = any(match.start() < write_index for match in release_matches)

# Deterministic failure scenario: A is already cached, so this pass removes A from
# its prospective stage and schedules ownership release. The atomic stage write then
# fails, leaving the old durable A entry authoritative. A subsequent user deletion
# creates a tombstone only if ownership is still held; without it, the retry downloads A.
stage_contains_a = True
ownership_held = "ICBackupSetDeferredDownloadOwnership(candidate[@\"objectHash\"], YES)" in cached_branch
tombstone_exists = False
if release_before_write:
    ownership_held = False
stage_write_succeeded = False
if stage_write_succeeded:
    stage_contains_a = False
if ownership_held:
    tombstone_exists = True
retry_redownloads_a = stage_contains_a and not tombstone_exists
require(not retry_redownloads_a,
        "A failed stage write released deferred ownership early: deleting cached A "
        "cannot create a tombstone, so the next retry downloads A again.")

require("deferredOwnershipHashesToRelease" in processor,
        "Resolved candidates need an explicit set of ownership releases pending commit.")

require("[resolvedDownloadKeys addObject:candidate[@\"pendingKey\"]]" in cached_branch
        and "ICBackupSetDeferredDownloadOwnership(candidate[@\"objectHash\"], YES)" in cached_branch
        and "[deferredOwnershipHashesToRelease addObject:candidate[@\"objectHash\"]]" in cached_branch
        and "ICBackupSetDeferredDownloadOwnership(candidate[@\"objectHash\"], NO)" not in cached_branch,
        "A physical cache hit must hold ownership until its staged release is durably committed.")

cancellation_start = processor.find("BOOL queueOwnerRemoved =")
cancellation_end = processor.find("});", cancellation_start)
require(cancellation_start >= 0 and cancellation_end > cancellation_start,
        "Missing deferred-cancellation commit preparation.")
cancellation_branch = processor[cancellation_start:cancellation_end]
require("[consumedCancellationHashes addObject:candidate[@\"objectHash\"]]" in cancellation_branch
        and "[deferredOwnershipHashesToRelease addObject:candidate[@\"objectHash\"]]" in cancellation_branch
        and "ICBackupSetDeferredDownloadOwnership" not in cancellation_branch,
        "Cancellation ownership must use the same stage commit boundary; its durable tombstone stays authoritative on failure.")

gate_start, gate_end, commit_gate = block_at(processor, "if (stageUpdated) {", write_index)
require("deferredOwnershipHashesToRelease" in commit_gate
        and "ICBackupSetDeferredDownloadOwnership(objectHash, NO)" in commit_gate,
        "Ownership releases must be published only inside the successful stage-write gate.")
require(release_matches and all(gate_start <= match.start() < gate_end for match in release_matches),
        "No deferred ownership release may occur outside the successful stage-write commit gate.")

implementation_start = CACHE.find("@implementation CacheManager")
require(implementation_start >= 0, "Missing CacheManager implementation.")

remove_many_start = CACHE.find("- (void) removeCacheForEpisodes:(NSArray<CDEpisode*>*)episodes", implementation_start)
remove_many_end = CACHE.find("- (void) removeCacheForEpisode:(CDEpisode*)episode\n"
                             "                      automatic:(BOOL)automatic\n"
                             "                     completion:", remove_many_start)
require(remove_many_start >= 0 and remove_many_end > remove_many_start,
        "Missing public multi-episode deletion path.")
remove_many = CACHE[remove_many_start:remove_many_end]
require("ownsDeferredDownloadWithObjectHash:identifier" in remove_many
        and "[activeEpisodes addObject:episode]" in remove_many,
        "Settled deferred-owned episodes must use the durable cancellation path before bulk deletion.")

remove_one_start = remove_many_end
remove_one_end = CACHE.find("- (void)_beginRemovalAfterCancellingEpisode:", remove_one_start)
require(remove_one_end > remove_one_start, "Missing public single-episode deletion path.")
remove_one = CACHE[remove_one_start:remove_one_end]
require("ownsDeferredDownloadWithObjectHash:episode.objectHash" in remove_one
        and "_beginRemovalAfterCancellingEpisode" in remove_one,
        "Deleting a settled deferred-owned episode must wait for its tombstone commit.")

remove_feed_start = CACHE.find("- (void) removeCacheForFeed:(CDFeed*)feed\n"
                               "                   automatic:(BOOL)automatic\n"
                               "                  completion:", implementation_start)
remove_feed_end = CACHE.find("- (void)_removeCacheForEpisodes:", remove_feed_start)
require(remove_feed_start >= 0 and remove_feed_end > remove_feed_start,
        "Missing podcast download-deletion path.")
remove_feed = CACHE[remove_feed_start:remove_feed_end]
require("[self _removeCacheRequestsForEpisodes:episodes" in remove_feed,
        "Podcast deletion must pass every chunk through the central durable ownership partition.")

auto_clear_start = CACHE.find("- (void) autoClearAndMakeRoomForBytes:", implementation_start)
auto_clear_end = CACHE.find("- (void)_recordPendingAutoClearBytes:", auto_clear_start)
require(auto_clear_start >= 0 and auto_clear_end > auto_clear_start,
        "Missing storage auto-clear path.")
auto_clear = CACHE[auto_clear_start:auto_clear_end]
require("[self removeCacheForEpisodes:selectedEpisodes" in auto_clear
        and "[self _removeCacheForEpisodes:selectedEpisodes" not in auto_clear,
        "Storage auto-clear must preserve the ownership/tombstone contract while retaining public batching.")

cancel_method_start = CACHE.find("- (void)_cancelCachingEpisode:", implementation_start)
cancel_method_end = CACHE.find("- (void)_cancelTrackedDownloadOperationAfterDurableIntent:", cancel_method_start)
require(cancel_method_start >= 0 and cancel_method_end > cancel_method_start,
        "Missing CacheManager cancellation path.")
cancel_method = CACHE[cancel_method_start:cancel_method_end]
require("ownsDeferredDownloadWithObjectHash" in cancel_method
        and "prepareForDeferredDownloadCancellation" in cancel_method
        and "!hasTrackedOwner" not in cancel_method
        and cancel_method.find("ownsDeferredDownloadWithObjectHash")
        < cancel_method.find("prepareForDeferredDownloadCancellation"),
        "Held ownership must force durable tombstone creation even after the runtime download owner has settled.")

require("prepareForDeferredDownloadClearAllWithCompletion" in IMPORTER_HEADER,
        "Destructive clear-all needs an explicit durable pending-restore cancellation API.")
clear_restore_start = IMPORTER.find("+ (void)prepareForDeferredDownloadClearAllWithCompletion:")
clear_restore_end = IMPORTER.find("+ (void)prepareForDeferredDownloadCancellation:", clear_restore_start)
require(clear_restore_start >= 0 and clear_restore_end > clear_restore_start,
        "Missing deferred-restore destructive-clear preparation.")
clear_restore = IMPORTER[clear_restore_start:clear_restore_end]
clear_stage = clear_restore.find("ICBackupWriteDownloadStage(@[]")
clear_ownership = clear_restore.find("ICBackupClearDeferredDownloadOwnership")
clear_tombstones = clear_restore.find("ICBackupRemoveDownloadCancellationTombstones")
require(clear_stage >= 0 and clear_ownership > clear_stage and clear_tombstones > clear_stage,
        "Clear-all must durably remove the pending stage before releasing ownership and cleaning cancellation markers.")
require("if (!stageUpdated)" in clear_restore
        and clear_restore.find("if (!stageUpdated)") < clear_ownership,
        "A failed clear-all stage write must retain ownership and abort physical deletion.")

clear_all_start = CACHE.find("- (void)cancelDownloadsAndClearCacheWithCompletion:", implementation_start)
clear_all_end = CACHE.find("- (void) _removeAllSavedCachingInfos", clear_all_start)
require(clear_all_start >= 0 and clear_all_end > clear_all_start,
        "Missing destructive download clear path.")
clear_all = CACHE[clear_all_start:clear_all_end]
begin_restore_preparation = clear_all.find("[deletionPreparation beginPreparation]")
prepare_restore = clear_all.find("prepareForDeferredDownloadClearAllWithCompletion")
wait_for_preparation = clear_all.find("[deletionPreparation waitForPreparation]")
require(begin_restore_preparation >= 0
        and begin_restore_preparation < prepare_restore < wait_for_preparation
        and "finishPreparationWithError:error" in clear_all[prepare_restore:wait_for_preparation],
        "Destructive clear-all must feed pending-stage failure into its existing pre-delete durability barrier.")

remove_tombstones = processor.find("ICBackupRemoveDownloadCancellationTombstones", write_index)
require(remove_tombstones > gate_end,
        "Cancellation tombstones may be cleaned only after stage and ownership commit.")

print("Backup deferred-ownership commit regression checks passed")
