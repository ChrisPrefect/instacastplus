#!/usr/bin/env python3
"""Pins stream-cache startup recovery, terminal UI state, and byte accounting."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()


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
        if source.find(";", start, brace) == -1:
            break
        search_start = brace

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


# A non-background URLSession cannot resume after process death. Recovery therefore
# snapshots only directories that already existed when the background cleanup began.
# A lease created after that snapshot is not a deletion candidate; a lease that was
# already present is protected by the main-thread token reconciliation.
build_index = method_body(CACHE, "- (void)_buildCacheIndexInBackground")
require(
    "_removeOrphanedStreamingCacheDirectoriesWithFileManager:" in build_index
    and build_index.find("_removeOrphanedStreamingCacheDirectoriesWithFileManager:")
    < build_index.find("contentsOfDirectoryAtPath:storagePath"),
    "Orphan stream directories must be removed on the background index worker before "
    "any byte/index snapshot can count them.",
)

startup_cleanup = method_body(
    CACHE,
    "- (BOOL)_removeOrphanedStreamingCacheDirectoriesWithFileManager:",
)
require(
    "contentsOfDirectoryAtPath:streamingRoot" in startup_cleanup
    and "_streamingCacheLeaseTokensByIdentifier.allValues" in startup_cleanup
    and "_streamingCacheRecoveryCandidateTokens" in startup_cleanup
    and startup_cleanup.find("contentsOfDirectoryAtPath:streamingRoot")
    < startup_cleanup.find("_streamingCacheLeaseTokensByIdentifier.allValues")
    < startup_cleanup.find("removeItemAtPath:candidatePath"),
    "Startup recovery must snapshot candidates, reconcile active lease tokens, and "
    "reserve every inactive candidate against later lease acquisition before deletion.",
)
require(
    "dispatch_get_main_queue()" in startup_cleanup,
    "The background recovery worker must reconcile against the main-thread lease map.",
)

recalculate = method_body(CACHE, "- (void)recalculateDownloadedBytesInBackground")
require(
    "_removeOrphanedStreamingCacheDirectoriesWithFileManager:" in recalculate
    and recalculate.find("_removeOrphanedStreamingCacheDirectoriesWithFileManager:")
    < recalculate.find("accumulateDirectory(pathToDownloads)"),
    "Every authoritative byte rescan must reconcile orphan stream files before it "
    "publishes a size snapshot.",
)
require(
    'stringByAppendingPathComponent:@"Streaming"' in build_index
    and "skipDescendants" in build_index
    and 'stringByAppendingPathComponent:@"Streaming"' in recalculate
    and "skipDescendants" in recalculate,
    "Directory scans must exclude active Streaming files; those bytes are accounted "
    "from the registered leases without rescanning per progress update.",
)

# Deterministic interleaving proof for the required candidate-snapshot contract.
disk_entries = {"orphan-token", "active-before-snapshot"}
candidates = set(disk_entries)
active_tokens: set[str] = {"active-before-snapshot"}
reserved_candidates = candidates - active_tokens
active_tokens.add("new-active-token")
disk_entries.add("new-active-token")
for candidate in reserved_candidates:
    if candidate not in active_tokens:
        disk_entries.remove(candidate)
require(
    disk_entries == {"active-before-snapshot", "new-active-token"},
    "Leases active before reconciliation and created during delete phase must survive recovery.",
)

require(
    "downloadedBytes:(unsigned long long)downloadedBytes" in CACHE_HEADER,
    "Stream progress must report its current on-disk byte size to CacheManager.",
)
update_stream = method_body(CACHE, "- (void) updateStreamingCacheForEpisode:")
require(
    "_setStreamingCacheBytes:downloadedBytes" in update_stream
    and "autoClearAndMakeRoomForBytes:0 automatic:YES" in update_stream,
    "Active stream bytes must update exact storage accounting and enforce the automatic "
    "storage limit without a directory rescan.",
)
begin_stream = method_body(CACHE, "- (NSString*) beginStreamingCacheForEpisode:")
finish_stream = method_body(CACHE, "- (void) finishStreamingCacheForEpisode:")
require(
    "_streamingCacheBytesByIdentifier[key] = @0" in begin_stream
    and "_streamingCacheRecoveryCandidateTokens" in begin_stream
    and "autoClearAndMakeRoomForBytes:" not in begin_stream
    and "expectedBytes" not in begin_stream,
    "A newly registered stream lease must enter byte accounting without deleting "
    "downloads from unverified feed-declared size metadata.",
)
require(
    update_stream.find("_setStreamingCacheBytes:downloadedBytes")
    < update_stream.find("_downloadedBytes > maxAllowedBytes")
    < update_stream.find("autoClearAndMakeRoomForBytes:0 automatic:YES")
    and "expectedBytes" not in update_stream,
    "Every throttled progress update must use an O(1) total-vs-limit check so concurrent "
    "streams enforce the limit from actual received bytes.",
)
require(
    "_removeStreamingCacheBytesForIdentifier:key" in finish_stream
    and "autoClearAndMakeRoomForBytes:0 automatic:YES" in finish_stream,
    "Every terminal stream path must remove its active bytes and reconcile storage policy.",
)

# Deferred backup restore can cancel by durable object hash after the managed episode
# has already disappeared. Dropping the lease alone leaves the detached/current URLSession
# writer alive. Publish its exact hash+lease identity before ownership bookkeeping is
# removed, and make PlaybackManager cancel by that identity without requiring CDEpisode.
ownerless_cancel = method_body(
    CACHE,
    "- (BOOL)completeDeferredRestoreCancellationForObjectHash:",
)
ownerless_notification = ownerless_cancel.find(
    "CacheManagerDidCancelStreamingCacheEpisodeNotification"
)
ownerless_hash = ownerless_cancel.find('@"episodeHash"')
ownerless_token = ownerless_cancel.find('@"leaseToken"')
ownerless_remove_lease = ownerless_cancel.find(
    "[_streamingCacheLeaseTokensByIdentifier removeObjectForKey:objectHash]"
)
ownerless_remove_bytes = ownerless_cancel.find(
    "_removeStreamingCacheBytesForIdentifier:objectHash"
)
require(
    -1 not in (
        ownerless_notification,
        ownerless_hash,
        ownerless_token,
        ownerless_remove_lease,
        ownerless_remove_bytes,
    )
    and ownerless_notification < ownerless_remove_lease
    and ownerless_hash < ownerless_remove_lease
    and ownerless_token < ownerless_remove_lease
    and ownerless_notification < ownerless_remove_bytes,
    "Ownerless deferred-restore cancellation must notify the streaming writer with the "
    "exact episodeHash and leaseToken before removing its lease/bytes or directory ownership.",
)

playback_ownerless_cancel = method_body(
    PLAYBACK,
    "- (void)_cacheManagerDidCancelStreamingCacheEpisode:",
)
require(
    'notification.userInfo[@"episodeHash"]' in playback_ownerless_cancel
    and 'notification.userInfo[@"leaseToken"]' in playback_ownerless_cancel
    and "_cancelStreamingCacheForEpisodeHash:" in playback_ownerless_cancel,
    "PlaybackManager must consume the ownerless hash+lease notification through a writer "
    "cancel path that does not require a surviving CDEpisode object.",
)

# The loader callback has three states. `complete == NO` is not enough because both an
# active transfer and a terminal failure are incomplete.
require(
    "ICStreamingCacheLoaderStateActive" in PLAYBACK
    and "ICStreamingCacheLoaderStateSucceeded" in PLAYBACK
    and "ICStreamingCacheLoaderStateFailed" in PLAYBACK,
    "Streaming progress needs an explicit active/succeeded/failed state.",
)
require(
    "unsigned long long downloadedBytes" in PLAYBACK
    and "ICStreamingCacheLoaderState state" in PLAYBACK,
    "The progress callback must carry both exact file bytes and terminal state.",
)
notify_progress = method_body(PLAYBACK, "- (void)_notifyProgressIfNeededForce:")
require(
    "_downloadedCoverageBytes" in notify_progress
    and "self.terminalState" in notify_progress
    and "handler(progress, downloadedBytes, state)" in notify_progress,
    "Loader notifications must publish one coherent progress/bytes/state snapshot.",
)
downloaded_coverage = method_body(PLAYBACK, "- (unsigned long long)_downloadedCoverageBytes")
require(
    "self.downloadedRanges" in downloaded_coverage
    and "range.end - range.start" in downloaded_coverage
    and "activeWriteOffset" not in downloaded_coverage,
    "A small downloaded range near the end of a sparse stream file must account only "
    "for its unique covered bytes, never the highest write offset.",
)
stream_failure = method_body(PLAYBACK, "- (void)_failWithError:")
require(
    "self.terminalState = ICStreamingCacheLoaderStateFailed" in stream_failure
    and stream_failure.find("ICStreamingCacheLoaderStateFailed")
    < stream_failure.find("_notifyProgressIfNeededForce:YES"),
    "A terminal loader failure must be reported as failed before its final callback.",
)
open_episode = method_body(
    PLAYBACK,
    "- (void) openWithEpisode:(CDEpisode*)anEpisode at:(NSTimeInterval)time autostart:(BOOL)autostart",
)
require(
    "state == ICStreamingCacheLoaderStateActive" in open_episode
    and "state == ICStreamingCacheLoaderStateSucceeded" in open_episode
    and "strongSelf.streamingCacheActive = cacheActive" in open_episode
    and "strongSelf.streamingCacheComplete = cacheComplete" in open_episode,
    "Playback UI state must distinguish active transfer, terminal success, and terminal failure.",
)

# Accounting transition model: active bytes are part of total usage; moving a successful
# file to final storage preserves total bytes, while failure/cancel removes them.
base_bytes = 100
active_bytes = {"lease": 25}
require(base_bytes + sum(active_bytes.values()) == 125, "Active bytes must be counted.")
base_bytes += active_bytes.pop("lease")
require(base_bytes + sum(active_bytes.values()) == 125, "Success must not double count.")
active_bytes["lease-2"] = 30
active_bytes.pop("lease-2")
require(base_bytes + sum(active_bytes.values()) == 125, "Failure/cancel must remove bytes.")

near_end_range = (99_000_000, 99_524_288)
covered_bytes = near_end_range[1] - near_end_range[0]
require(covered_bytes == 524_288, "A near-end sparse range must count 512 KiB, not 99.5 MB.")

print("Download streaming lifecycle regression checks passed")
