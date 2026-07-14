#!/usr/bin/env python3
"""Pins verified iPhone episode downloads and actionable terminal failures."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


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


operation = read("Classes/CacheOperation_iOS7.m")
operation_header = read("Classes/CacheOperation_iOS7.h")
cache_manager = read("Classes/CacheManager.m")
cache_header = read("Classes/CacheManager.h")
downloads = read("Classes/DownloadsViewController.m")
download_cell = read("Classes/DownloadsTableViewCell.m")
download_cell_header = read("Classes/DownloadsTableViewCell.h")
transcription = read("Classes/TranscriptionQueue.swift")
de = read("Resources/de.lproj/Localizable.strings")
en = read("Resources/en.lproj/Localizable.strings")


require("terminalError" in operation_header,
        "A failed URLSession operation must retain its concrete terminal NSError, not only a Boolean.")
require("idleCounter" not in operation,
        "Download liveness must come from URLSession terminal callbacks, not an arbitrary 20-second no-byte timeout.")
require("self.session == session" in method_body(operation, "didBecomeInvalidWithError:"),
        "Invalidation of an obsolete session must not clear or fail its replacement session.")
require("cancelLoading" in method_body(operation, "- (void) cancel") and
        "mediaValidationSemaphore" in operation,
        "Cancel must terminate and release an in-flight AVFoundation validation wait.")
require("feedExpectedContentLength" in operation and "transportExpectedContentLength" in operation,
        "Feed and transport size hints must remain separate so an unknown transport size cannot erase the feed hint.")
require("expectedDuration" in operation_header,
        "The operation needs the feed duration hint for transport-independent truncation validation.")

finish = method_body(
    operation,
    "URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:",
)
transport_validation = method_body(operation, "_transportValidationErrorForTask:")
require("_transportValidationErrorForTask" in finish and
        "statusCode" in transport_validation and "200" in transport_validation and "300" in transport_validation,
        "Download completion must reject HTTP failures before accepting their response body as media.")
require("isCompletePartialContentResponse" in operation and "Content-Range" in operation,
        "HTTP 206 must be accepted only when the assembled file matches the resource total.")
require("fileSize < 100*1024" not in finish,
        "An arbitrary 100 KiB threshold both accepts large error pages and rejects valid short clips.")
require("stagedDownloadURL" in operation and "NSTemporaryDirectory" in operation,
        "Unverified response bodies must stay outside the final episode cache until every validation passes.")
require("text/html" in operation and "application/json" in operation,
        "Obvious web/API response bodies must not be indexed as podcast media.")
require("transportExpectedContentLength > 0" in operation and
        "feedExpectedContentLength / 2" in operation,
        "Final size validation must use a positive transport size or the proven feed-size fallback.")

progress = method_body(
    operation,
    "didWriteData:(int64_t)bytesWritten",
)
resume = method_body(
    operation,
    "didResumeAtOffset:(int64_t)fileOffset",
)
require("totalBytesExpectedToWrite > 0" in progress and
        "expectedTotalBytes > 0" in resume,
        "URLSession's unknown -1 length must never overwrite a useful feed size hint.")

require("AVURLAsset" in operation and "loadValuesAsynchronouslyForKeys" in operation,
        "A response that passes HTTP and byte checks must still be validated as playable media off-main.")
require("fileExtensionForMIMEType" in operation and "response.MIMEType" in operation,
        "Extensionless/tracking media URLs need the transport MIME extension for AVFoundation and final playback.")
require("expectedDuration >= 600" in operation and "expectedDuration / 2" in operation,
        "A playable prefix whose measured duration collapses must be rejected as truncated.")
require("moveItemAtURL:self.stagedDownloadURL toURL:self.localURL" in operation,
        "Only a fully validated staging file may be moved to the final cache URL.")
require("_removeStagedDownload" in operation and "removeItemAtURL:stagedDownloadURL" in operation,
        "Every terminal failure must remove its unverified staging artifact.")
main = method_body(operation, "- (void) main")
require(main.count("[self isCancelled]") >= 4 and "finalizedDownload" in main,
        "Cancel during validation/finalization must never leave a final file that later reappears as cached.")

require("CacheManagerDidFailCachingEpisodeNotification" in cache_header,
        "Success and failure need separate public cache-manager terminal events.")
require("failedDownloadEpisodes" in cache_header and "downloadErrorForEpisode:" in cache_header,
        "Manual failures must remain visible with their concrete reason until retry or dismissal.")
require("retryFailedDownloadForEpisode:" in cache_header,
        "Retry must preserve the failed request's original connectivity policy.")
cache_end = method_body(cache_manager, "- (void) cacheOperationDidEnd:")
terminal_end = method_body(cache_manager, "- (void)_finishCacheOperationDidEnd:")
batch_end = method_body(cache_manager, "- (void) _finishDownloadBatchAfterOperation:")
require("_finishCacheOperationDidEnd" in cache_end and
        "operation.terminalError" in terminal_end and
        "CacheManagerDidFailCachingEpisodeNotification" in terminal_end,
        "CacheManager must propagate the operation's exact terminal NSError.")
require("showBackgroundErrorWithTitle" in terminal_end and
        "operation.reportsFailureToUser" in terminal_end and "!operation.automatic" in terminal_end,
        "A manual failure must be visible even when the Downloads screen is not open; automatic failures stay non-intrusive.")
require("currentQueueHadFailure" in cache_manager and "!queueHadFailure" in batch_end,
        "A mixed queue with an earlier failure must not announce that every download finished successfully.")
require("FailedEpisodeDownloads.plist" in cache_manager and
        "writeToFile" in cache_manager and "_restoreFailedDownloads" in cache_manager,
        "Manual background failures and their retry policy must survive suspension or process death.")

background_events = method_body(cache_manager, "handleEventsForBackgroundURLSession:")
require("afterDelay:2" not in background_events and
        "backgroundSessionCompletionHandlers" in background_events,
        "The iOS background-session completion handler must wait for validation/finalization, not two seconds.")
require("savedCachingInfoForIdentifier" in background_events and
        "reportsFailureToUser" in background_events,
        "A background wake must restore the saved automatic/cellular/UI policy before attaching its session.")
require("_completeBackgroundSessionForIdentifier" in terminal_end,
        "The background completion handler must be released only from the verified terminal path.")
require("_downloadStartError" in cache_manager,
        "Missing media/hash/path or operation creation must produce a concrete synchronous start error.")

require("failedDownloadEpisodes" in downloads and "downloadErrorForEpisode" in downloads,
        "The Downloads screen must retain failed manual rows and render their exact error.")
require("retryFailedDownload" in downloads and '"Retry".ls' in downloads,
        "A failed row needs an explicit Retry action wired to the real download request.")
retry = method_body(downloads, "- (void) retryFailedDownload:")
require("retryFailedDownloadForEpisode" in retry and "overwriteCellularLock:YES" not in retry,
        "Retry must preserve the original cellular policy rather than silently overriding settings.")
require("showsErrorStatus" in download_cell_header and "numberOfLines = 0" in download_cell,
        "Failure text must wrap to its full localized message instead of being truncated.")
download_end = method_body(downloads, "CacheManagerDidEndCachingNotification")
require("_rebuildDisplayEpisodes" in download_end and "displayEpisodes.count == 0" in download_end,
        "The Downloads screen must refresh its combined snapshot and not auto-dismiss while failed manual rows still need attention.")
view_did_appear = method_body(downloads, "- (void) viewDidAppear:")
require("_updateToolbar" in view_did_appear and "_updateCaption" in view_did_appear,
        "A restored failure-only Downloads screen must initialize its disabled Pause state and failure caption immediately.")
caption = method_body(downloads, "- (void) _updateCaption")
require("if (rate > 0)" in caption and "rate > 1024" not in caption,
        "Every positive transfer rate, including 1-1024 B/s, must replace the previous caption instead of leaving stale speed information.")

require("CacheManagerDidFailCachingEpisodeNotification" in transcription and
        "pendingDownloadHashes.remove" in transcription,
        "A failed transcription auto-download must leave its waiting state with the concrete error.")
require("reportsFailureToUser: false" in transcription,
        "A background transcription download must report into its queue without showing a manual-download sheet.")
auto_download = method_body(transcription, "private func autoDownloadEpisode(")
require("cacheEpisode" in auto_download and "return (" in auto_download,
        "Transcription must inspect synchronous download-start failure instead of assuming every request queued.")

for strings, language in ((de, "German"), (en, "English")):
    for key in (
        "Download Failed",
        "The podcast server returned a web page instead of a playable episode file.",
        "The podcast server ended the transfer before the complete episode file was received.",
        "The downloaded episode file is not playable.",
        "Tap Retry to try the download again.",
    ):
        require(f'"{key}"' in strings, f"{language} download-error localization is missing: {key}")

print("iPhone download integrity regression checks passed")
