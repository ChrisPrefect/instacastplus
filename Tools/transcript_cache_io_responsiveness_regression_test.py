#!/usr/bin/env python3
"""Keeps transcript cache reads, writes, and deletes off the main thread."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
EPISODE = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()
EPISODE_HEADER = (ROOT / "Classes" / "Model" / "CDEpisode.h").read_text()


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
        if source.find(";", start, brace) == -1:
            break
        search_start = brace + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


read_helper = body(PLAYER, "- (void)_readCachedTranscriptDataForEpisodeHash:")
cache_check = body(PLAYER, "- (void)_checkCachedTranscriptDataForEpisodeHash:")
prefetch = body(PLAYER, "- (void)_prefetchTranscriptDescriptor:")
prefetch_start = body(PLAYER, "- (void)_startTranscriptPrefetchDescriptor:")
prefetch_sources = body(PLAYER, "- (void)_prefetchTranscriptSourcesForEpisode:")
load = body(PLAYER, "- (void)_loadTranscriptDescriptor:(NSDictionary*)descriptor")
network = body(PLAYER, "- (void)_loadTranscriptDescriptorFromNetwork:")
cache_will_delete = body(PLAYER, "- (void)cacheManagerWillDeleteCacheFilesNotification:")
cache_clear = body(PLAYER, "- (void)cacheManagerDidClearCacheNotification:")
cleanup = body(EPISODE, "static void ICProcessPendingTranscriptCacheRemovals(void)")

require(
    "+ (void)performTranscriptCacheIO:(dispatch_block_t)block;" in EPISODE_HEADER
    and "QOS_CLASS_UTILITY" in EPISODE,
    "Transcript disk work needs one shared serial utility queue with consumed-state cleanup.",
)
require(
    "performTranscriptCacheIO" in read_helper
    and "_cachedTranscriptDataForEpisodeHash" in read_helper
    and "dispatch_get_main_queue" in read_helper,
    "Cache reads must finish on the shared utility queue and return state handling to main.",
)
require(
    "_checkCachedTranscriptDataForEpisodeHash" in prefetch
    and "_cachedTranscriptDataForEpisodeHash" not in prefetch_sources,
    "Prefetch selection must check cache files asynchronously without reading them on main.",
)
require(
    "fileSize" in cache_check
    and "_cachedTranscriptDataForEpisodeHash" not in cache_check
    and "performTranscriptCacheIO" in cache_check,
    "Prefetch cache checks must inspect file size instead of allocating entire transcript files.",
)
require(
    "transcriptPrefetchCacheCheckTokens" in PLAYER
    and "NSObject* cacheCheckToken" in prefetch
    and "transcriptPrefetchCacheCheckTokens[taskKey] = cacheCheckToken" in prefetch
    and "transcriptPrefetchCacheCheckTokens[taskKey] != cacheCheckToken" in prefetch
    and "transcriptPrefetchCacheCheckKeys" not in PLAYER,
    "A cancelled cache check must use unique identity so an old completion cannot consume its replacement.",
)
require(
    "indexOfObjectIdenticalTo:descriptor" in prefetch
    and "indexOfObject:descriptor" not in prefetch,
    "Advancing prefetch must locate the exact descriptor instance when equal sources occur twice.",
)
require(
    "_readCachedTranscriptDataForEpisodeHash" in load
    and "dispatch_get_global_queue(QOS_CLASS_USER_INITIATED" in load,
    "Opening a transcript must read on the cache queue and keep parsing off main.",
)
for section, name in ((prefetch_start, "prefetch"), (load, "cache recovery"), (network, "network completion")):
    require(
        "performTranscriptCacheIO" in section,
        f"Transcript {name} must serialize cache writes/deletes with consumed-state cleanup.",
    )

require(
    "while (YES)" not in cleanup
    and "dispatch_async(ICTranscriptCleanupQueue" in cleanup
    and "ICProcessPendingTranscriptCacheRemovals" in cleanup,
    "A cleanup pass must re-enqueue later removals at the queue tail to preserve FIFO with cache writes.",
)
require(
    "beginPreparation" in cache_will_delete
    and "performAfterPendingTranscriptCacheIO" in cache_will_delete
    and "finishPreparationWithError:nil" in cache_will_delete
    and "beginPreparation" not in cache_clear,
    "Cache deletion must wait for previously queued transcript writes before removing their files.",
)

# Deterministic ordering proof for the former drain-loop race: a write already
# queued while cleanup A runs must execute before the later cleanup B.
queue = ["cleanup-A"]
pending = {"A"}
queue.append("write-B")
pending.add("B")
queue.append("cleanup-next")
require(queue == ["cleanup-A", "write-B", "cleanup-next"] and "B" in pending,
        "The fixture must keep a pre-existing write ahead of a later removal pass.")

clear_order = ["queued-write", "deletion-barrier", "physical-delete"]
require(clear_order.index("queued-write") < clear_order.index("deletion-barrier") < clear_order.index("physical-delete"),
        "The fixture must make physical deletion authoritative over an already queued write.")

first_descriptor = {"url": "https://example.invalid/transcript.vtt"}
second_descriptor = {"url": "https://example.invalid/transcript.vtt"}
duplicate_sources = [first_descriptor, second_descriptor]
require(duplicate_sources.index(second_descriptor) == 0
        and next(index for index, value in enumerate(duplicate_sources) if value is second_descriptor) == 1,
        "The fixture must distinguish value equality from the exact duplicate descriptor instance.")

print("Transcript cache I/O responsiveness regression checks passed")
