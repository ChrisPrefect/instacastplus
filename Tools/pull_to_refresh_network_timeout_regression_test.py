#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def source_between(source, start, end):
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


subscription_manager = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
http_operation = (ROOT / "VemedioKit" / "VMHTTPOperation.m").read_text()

refresh_feed_body = source_between(
    subscription_manager,
    "- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion",
    "- (void) checkRefreshOperationsTimer:(NSTimer*)timer",
)

timer_body = source_between(
    subscription_manager,
    "- (void) checkRefreshOperationsTimer:(NSTimer*)timer",
    "- (void)_postDidAddEpisodesNotification:",
)

require(
    "- (void)_cancelRefreshParserForURL:(NSURL*)url" in subscription_manager,
    "Refresh timeouts must cancel the matching parser operation, not only remove UI refresh state.",
)

cancel_body = source_between(
    subscription_manager,
    "- (void)_cancelRefreshParserForURL:(NSURL*)url",
    "- (void) checkRefreshOperationsTimer:(NSTimer*)timer",
)

require(
    "for (NSOperation* operation in [self.parserQueue.operations copy])" in cancel_body
    and "[operation isKindOfClass:[ICFeedParser class]]" in cancel_body
    and "[feedParser cancel]" in cancel_body,
    "The timeout cancel helper must find and cancel the ICFeedParser operation for the timed-out feed.",
)

require(
    "feedParser.userInfo = url;" in refresh_feed_body,
    "Refresh parser operations must keep the original feed URL so timeout cancellation can match them after redirects.",
)

timed_out_loop = source_between(
    timer_body,
    "for (NSURL* url in timedOutURLs) {",
    "    }\n\n    // Safety timeout:",
)

require(
    "_cancelRefreshParserForURL:url" in timed_out_loop
    and timed_out_loop.index("_cancelRefreshParserForURL:url") < timed_out_loop.index("_finishRefreshingURL:url"),
    "Per-feed timeout must cancel the parser operation before removing refresh tracking for that URL.",
)

require(
    "[self.dataTask cancel];" in http_operation
    and "[self isCancelled]" in http_operation,
    "VMHTTPOperation cancellation must stop the underlying NSURLSessionDataTask and release the synchronous wait loop.",
)

print("Pull-to-refresh network timeout regression checks passed.")
