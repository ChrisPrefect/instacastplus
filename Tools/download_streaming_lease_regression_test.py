#!/usr/bin/env python3
"""Pins atomic stream-cache ownership acquisition before a loader writes files."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()


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


require("- (NSString*) beginStreamingCacheForEpisode:(CDEpisode*)episode acquiredNewLease:(BOOL*)acquiredNewLease;" in CACHE_HEADER,
        "Loader creation needs a unique ownership token and an explicit new-vs-reattached result.")
require("leaseToken:(NSString*)leaseToken" in CACHE_HEADER and
        CACHE_HEADER.count("leaseToken:(NSString*)leaseToken") >= 3,
        "Progress, finish and failure must all identify the exact stream-cache lease generation.")

begin_stream = body(CACHE, "- (NSString*) beginStreamingCacheForEpisode:")
require("_clearingAllCache" in begin_stream and
        "_cacheDeletionTokensByIdentifier[key]" in begin_stream and
        "_cacheImportTokensByIdentifier[key]" in begin_stream and
        "return nil;" in begin_stream,
        "Stream-cache acquisition must reject full-clear and per-episode deletion transactions.")
require("_streamingCacheLeaseTokensByIdentifier[key] = leaseToken" in begin_stream and
        begin_stream.find("_streamingCacheLeaseTokensByIdentifier[key] = leaseToken") < begin_stream.rfind("return leaseToken;"),
        "A successful lease must be registered before the caller can create a file writer.")

open_episode = body(
    PLAYBACK,
    "- (void) openWithEpisode:(CDEpisode*)anEpisode at:(NSTimeInterval)time autostart:(BOOL)autostart",
)
acquire = open_episode.find("beginStreamingCacheForEpisode:anEpisode")
take_detached = open_episode.find("takeDetachedLoaderForEpisodeHash")
create_loader = open_episode.find("[[ICStreamingCacheLoader alloc] initWithEpisode")
require(acquire != -1 and take_detached != -1 and create_loader != -1 and
        acquire < take_detached < create_loader,
        "Playback must acquire the CacheManager lease before taking or creating a stream writer.")
require(open_episode.count("beginStreamingCacheForEpisode:anEpisode") == 1 and
        "NSString* streamCacheLeaseToken" in open_episode and
        "acquiredNewLease:&acquiredNewStreamCacheLease" in open_episode and
        "if (streamCacheLeaseToken.length == 0)" in open_episode,
        "Lease rejection must select direct playback without ghost bookkeeping or a false write error.")
require("leaseToken:streamCacheLeaseToken" in open_episode and
        "failStreamingCacheForEpisode:anEpisode" in open_episode and
        "error:streamCacheStartError" in open_episode,
        "A real loader initialization failure after acquisition must still terminally release/report the lease.")

take_detached_loader = body(
    PLAYBACK,
    "+ (ICStreamingCacheLoader*)takeDetachedLoaderForEpisodeHash:",
)
require("loader.isCacheTerminal" in take_detached_loader and
        take_detached_loader.find("loader.isCacheTerminal") < take_detached_loader.find("matchingLoader = loader"),
        "A detached loader that became terminal before reattachment must be discarded instead of returned to playback.")

print("Download streaming-lease regression checks passed")
