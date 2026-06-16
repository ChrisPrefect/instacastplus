#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def objc_method(source: str, signature: str) -> str:
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
    raise SystemExit(f"Unterminated method body: {signature}")


cache_header = (ROOT / "Classes" / "CacheManager.h").read_text()
cache_manager = (ROOT / "Classes" / "CacheManager.m").read_text()
playback_header = (ROOT / "Classes" / "PlaybackManager.h").read_text()
playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
de_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()


require(
    "CacheManagerDidCancelStreamingCacheEpisodeNotification" in cache_header
    and "cancelStreamingCacheForEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload" in cache_header
    and "automaticCachingDisabledForEpisode:" in cache_header,
    "CacheManager must expose the real streaming-cache cancellation and auto-download suppression contract.",
)

cancel_caching = objc_method(
    cache_manager,
    "- (void) cancelCachingEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload",
)
require(
    "cancelStreamingCacheForEpisode:episode disableAutoDownload:disableAutodownload" in cancel_caching,
    "The existing download cancel entry point must cancel stream-caching bookkeeping too.",
)

stream_cancel = objc_method(
    cache_manager,
    "- (void) cancelStreamingCacheForEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload",
)
require(
    "_streamingCacheProgresses" in stream_cancel
    and "CacheManagerDidCancelStreamingCacheEpisodeNotification" in stream_cancel
    and "setEpisode:episode didAutoDownload:YES" in stream_cancel,
    "Streaming cache cancellation must remove progress, notify the owner, and suppress repeat auto-downloads.",
)

require(
    "cancelStreamingCacheForEpisode:" in playback_header,
    "PlaybackManager must expose cancellation for the stream loader that owns the actual network task.",
)

playback_init = objc_method(playback_manager, "- (id) init")
require(
    "CacheManagerDidCancelStreamingCacheEpisodeNotification" in playback_init
    and "_cacheManagerDidCancelStreamingCacheEpisode:" in playback_init,
    "PlaybackManager must observe CacheManager stream-cancel requests.",
)

open_episode = objc_method(
    playback_manager,
    "- (void) openWithEpisode:(CDEpisode*)anEpisode at:(NSTimeInterval)time autostart:(BOOL)autostart",
)
require(
    "automaticCachingDisabledForEpisode:anEpisode" in open_episode
    and "isCachingSourceOfEpisode:anEpisode" in open_episode
    and "cancelCachingEpisode:anEpisode disableAutoDownload:NO" in open_episode
    and "BOOL shouldCacheViaStream = canCacheViaStream" in open_episode,
    "Playback start must prefer stream-caching over an already-running duplicate regular download.",
)

playback_cancel = objc_method(
    playback_manager,
    "- (BOOL) cancelStreamingCacheForEpisode:(CDEpisode*)episode",
)
require(
    "cancelAndDiscardPartialCache" in playback_cancel
    and "finishStreamingCacheForEpisode:episode" in playback_cancel
    and "openWithEpisode:episode at:resumeTime autostart:wasPlaying" in playback_cancel,
    "Cancelling active stream-caching must stop the loader and keep current playback on the direct stream.",
)

require(
    '"If not played after" = "Wenn nicht angespielt innerhalb";' in de_strings
    and "innert" not in de_strings,
    "German settings copy must replace 'innert' with 'innerhalb'.",
)
