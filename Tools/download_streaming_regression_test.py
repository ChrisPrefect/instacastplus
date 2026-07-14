#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def objc_method(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing method body: {signature}")
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
    raise SystemExit(f"Unterminated method body: {signature}")


cache_header = (ROOT / "Classes" / "CacheManager.h").read_text()
cache_manager = (ROOT / "Classes" / "CacheManager.m").read_text()
playback_header = (ROOT / "Classes" / "PlaybackManager.h").read_text()
playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
de_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()


require(
    "CacheManagerDidCancelStreamingCacheEpisodeNotification" in cache_header
    and "cancelStreamingCacheForEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload" in cache_header
    and "failStreamingCacheForEpisode:(CDEpisode*)episode error:(NSError*)error" in cache_header
    and "automaticCachingDisabledForEpisode:" in cache_header,
    "CacheManager must expose the real streaming-cache cancellation and auto-download suppression contract.",
)

stream_failure = objc_method(
    cache_manager,
    "- (void) failStreamingCacheForEpisode:(CDEpisode*)episode error:(NSError*)error",
)
require(
    "finishStreamingCacheForEpisode:episode" in stream_failure
    and "_recordDownloadError:error" in stream_failure
    and "CacheManagerDidFailCachingEpisodeNotification" in stream_failure,
    "A streaming network/media failure needs one terminal bookkeeping and visible retry state.",
)

cancel_caching = objc_method(
    cache_manager,
    "- (void) cancelCachingEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload",
)
cancel_caching_after_intent = objc_method(
    cache_manager,
    "- (void)_cancelCachingEpisodeAfterDurableIntent:(CDEpisode*)episode",
)
require(
    "_cancelCachingEpisode:episode" in cancel_caching
    and "_cancelStreamingCacheForEpisodeAfterDurableIntent:episode" in cancel_caching_after_intent,
    "The existing download cancel entry point must cancel stream-caching bookkeeping too.",
)

stream_cancel = objc_method(
    cache_manager,
    "- (void) cancelStreamingCacheForEpisode:(CDEpisode*)episode disableAutoDownload:(BOOL)disableAutodownload",
)
stream_cancel_after_intent = objc_method(
    cache_manager,
    "- (void)_cancelStreamingCacheForEpisodeAfterDurableIntent:(CDEpisode*)episode",
)
require(
    "prepareForDeferredDownloadCancellation" in stream_cancel
    and "_cancelStreamingCacheForEpisodeAfterDurableIntent:episode" in stream_cancel
    and "_streamingCacheProgresses" in stream_cancel_after_intent
    and "CacheManagerDidCancelStreamingCacheEpisodeNotification" in stream_cancel_after_intent
    and "setEpisode:episode didAutoDownload:YES" in stream_cancel_after_intent,
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
    and "takeDetachedLoaderForEpisodeHash" in open_episode
    and "streamCacheStartError" in open_episode
    and "failStreamingCacheForEpisode:anEpisode" in open_episode
    and "BOOL shouldCacheViaStream = canCacheViaStream" in open_episode,
    "Playback start must prefer stream-caching and reattach the existing per-hash writer.",
)

prepare_temp = objc_method(playback_manager, "- (BOOL)_prepareTempFileWithError:")
require(
    "writeToURL" in prepare_temp
    and "fileHandleForWritingToURL" in prepare_temp
    and "return NO" in prepare_temp,
    "An unwritable stream-cache file must fail initialization with its real I/O error.",
)

close_playback = objc_method(playback_manager, "- (void) closeAndSaveCurrentPosition:")
require(
    "cancelAndDiscardPartialCache" in close_playback
    and "finishStreamingCacheForEpisode" in close_playback
    and "detachFromPlaybackAndContinueCaching" in close_playback
    and "cacheTerminal" in close_playback,
    "Closing playback must terminally discard non-auto cache work, but retain coverage/import work when enabled.",
)

stream_response = objc_method(playback_manager, "didReceiveResponse:(NSURLResponse *)response")
require(
    "statusCode != 200 && statusCode != 206" in stream_response
    and "NSURLSessionResponseCancel" in stream_response
    and "_failWithError:" in stream_response,
    "HTTP error bodies must be rejected before any bytes can enter cache coverage.",
)

stream_completion = objc_method(playback_manager, "didCompleteWithError:(NSError *)error")
require(
    "_failWithError:" in stream_completion,
    "A network failure must use the same exactly-once terminal cleanup path.",
)

coverage_import = objc_method(playback_manager, "- (void)_updateCoverageStateAndImportIfNeeded")
require(
    "AVMediaTypeAudio" in coverage_import
    and "AVMediaTypeVideo" in coverage_import
    and coverage_import.find("loadValuesAsynchronouslyForKeys") < coverage_import.find("importStreamingFileAtURL"),
    "Complete byte coverage must be media-validated before it is published as a download.",
)

detach_loader = objc_method(playback_manager, "- (void)detachFromPlaybackAndContinueCaching")
require(
    detach_loader.find("[detachedSet addObject:self]") < detach_loader.find("dispatch_async(self.resourceLoaderQueue"),
    "Detach ownership must be synchronously visible before an immediate reopen can look up the loader.",
)

stream_failure_handler = objc_method(playback_manager, "- (void)_failWithError:")
require(
    "removeItemAtURL:self.tempURL" in stream_failure_handler
    and "failStreamingCacheForEpisode" in stream_failure_handler
    and "terminalStateReported" in stream_failure_handler,
    "Streaming failure cleanup must remove the partial file and report exactly one terminal state.",
)

playback_cancel = objc_method(
    playback_manager,
    "- (BOOL)_cancelStreamingCacheForEpisode:(CDEpisode*)episode leaseToken:(NSString*)leaseToken",
)
require(
    "cancelAndDiscardPartialCache" in playback_cancel
    and "finishStreamingCacheForEpisode:episode" in playback_cancel
    and "leaseToken:leaseToken" in playback_cancel
    and "openWithEpisode:episode at:resumeTime autostart:wasPlaying" in playback_cancel,
    "Cancelling active stream-caching must stop the loader and keep current playback on the direct stream.",
)

require(
    '"If not played after" = "Wenn nicht angespielt innerhalb";' in de_strings
    and "innert" not in de_strings,
    "German settings copy must replace 'innert' with 'innerhalb'.",
)
