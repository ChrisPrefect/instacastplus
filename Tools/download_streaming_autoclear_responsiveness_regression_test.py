#!/usr/bin/env python3
"""Pins non-blocking, actual-byte-based storage eviction while streaming."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_HEADER = (ROOT / "Classes" / "CacheManager.h").read_text()
CACHE = (ROOT / "Classes" / "CacheManager.m").read_text()
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


begin_stream = method_body(CACHE, "- (NSString*) beginStreamingCacheForEpisode:")
update_stream = method_body(CACHE, "- (void) updateStreamingCacheForEpisode:")
auto_clear = method_body(CACHE, "- (void) autoClearAndMakeRoomForBytes:")
open_episode = method_body(PLAYBACK, "- (void) openWithEpisode:")

# Enclosure byteSize is untrusted feed metadata. Reserving it before any bytes arrive
# can delete gigabytes of valid downloads for a stream that is actually tiny.
require(
    "expectedBytes:" not in CACHE_HEADER
    and "expectedBytes" not in begin_stream
    and "expectedBytes:" not in open_episode,
    "Streaming startup must not evict downloads from unverified feed-declared byteSize.",
)
require(
    update_stream.find("_setStreamingCacheBytes:downloadedBytes")
    < update_stream.find("autoClearAndMakeRoomForBytes:0 automatic:YES"),
    "Storage enforcement must use actual received stream bytes before considering eviction.",
)

# Main-thread work may update the small state machine, but it must not enumerate,
# fault, or sort every cached episode. Candidate selection belongs to a private
# Core Data context reached from the utility deletion queue.
background_dispatch = auto_clear.find("dispatch_async(_cacheDeletionQueue")
require(background_dispatch != -1, "Storage eviction needs a utility-queue selection phase.")
main_phase = auto_clear[:background_dispatch]
for forbidden in ["cachedEpisodes", "ReverseDownloadDateSort", "sortedArrayUsing"]:
    require(
        forbidden not in main_phase,
        f"The main-thread eviction phase must not enumerate/fault/sort the download library ({forbidden}).",
    )
require(
    "_autoClearSelectionInFlight = YES" in main_phase,
    "Concurrent eviction requests must be coalesced before background selection begins.",
)
background_phase = auto_clear[background_dispatch:]
require(
    "newBackgroundContext" in background_phase
    and "performBlockAndWait" in background_phase
    and "NSFetchRequest" in background_phase
    and '"objectHash IN %@"' in background_phase,
    "Eviction candidates must be fetched and ordered in a private Core Data context.",
)

print("Download streaming auto-clear responsiveness regression checks passed")
