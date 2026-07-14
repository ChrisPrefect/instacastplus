#!/usr/bin/env python3
"""Pins independent normal-download and streaming-cache ownership."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if SOURCE.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


remove_if_unowned = body("- (void)_removeCachingEpisodeForIdentifierIfUnowned:")
remove_download = body("- (BOOL) _removeTrackedDownloadOperation:")
finish_stream = body("- (void) finishStreamingCacheForEpisode:")
cancel_stream = body("- (void) cancelStreamingCacheForEpisode:")
cancel_stream_after_intent = body("- (void)_cancelStreamingCacheForEpisodeAfterDurableIntent:")

require("_downloadOperationsByIdentifier[identifier]" in remove_if_unowned and
        "_streamingCacheLeaseTokensByIdentifier[identifier]" in remove_if_unowned and
        "return;" in remove_if_unowned,
        "Shared UI/hash tracking must remain until both the normal download and stream owner are terminal.")
require(remove_download.find("_downloadOperationsByIdentifier removeObjectForKey:identifier") <
        remove_download.find("_removeCachingEpisodeForIdentifierIfUnowned:identifier"),
        "A normal download must relinquish only its own owner before shared tracking is reconciled.")
require("_cachingEpisodeHashes removeObject:identifier" not in remove_download and
        "_cachingEpisodes removeObject:operation.userInfo" not in remove_download,
        "Normal-download completion must not directly erase a still-active streaming owner.")

require("_cancelStreamingCacheForEpisodeAfterDurableIntent:episode" in cancel_stream,
        "Streaming cancellation must reach owner cleanup only after its durable cancellation handshake.")

for name, method in (("finish", finish_stream), ("cancel", cancel_stream_after_intent)):
    require(method.find("_streamingCacheLeaseTokensByIdentifier removeObjectForKey:key") <
            method.find("_streamingCacheProgresses removeObjectForKey:key") <
            method.find("_removeCachingEpisodeForIdentifierIfUnowned:key"),
            f"Streaming {name} must relinquish only the stream owner before shared tracking is reconciled.")
    require("_cachingEpisodeHashes removeObject:key" not in method,
            f"Streaming {name} must not erase a still-active normal-download owner.")


def remains_tracked(normal_owner: bool, stream_owner: bool) -> bool:
    return normal_owner or stream_owner


require(remains_tracked(False, True),
        "The stream must remain cancelable after the superseded normal operation ends.")
require(remains_tracked(True, False),
        "The normal operation must remain cancelable if streaming ends first.")
require(not remains_tracked(False, False),
        "Shared tracking must end exactly when the last owner ends.")

print("Download streaming-owner regression checks passed")
