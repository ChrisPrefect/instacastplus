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

finish_parsing_body = source_between(
    subscription_manager,
    "- (void) _finishParsingFeed:(CDFeed*)feed url:(NSURL*)url shouldAutoDownload:(BOOL)shouldAutoDownload",
    "- (BOOL)_feedNeedsDurationMetadataRefresh:",
)

refresh_feed_body = source_between(
    subscription_manager,
    "- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:(ICSubscriptionManagerRefreshCompletionBlock)completion",
    "    [self.parserQueue addOperation:feedParser];",
)

parser_error_block = source_between(
    refresh_feed_body,
    "feedParser.didEndWithError = ^(NSError* error) {",
    "    };",
)

require(
    "dispatch_async(dispatch_get_main_queue(), ^{" in parser_error_block,
    "Parser network errors must dispatch to main before touching refresh state.",
)

require(
    "_markFeedFailedForURL:url timedOut:NO error:error" in parser_error_block,
    "Parser network errors must still mark the feed as failed.",
)

require(
    "_finishParsingFeed:feed url:url shouldAutoDownload:NO" not in parser_error_block,
    "Parser network errors must not run success-feed cleanup, keep-newest cache enforcement, or did-parse notifications.",
)

require(
    "_finishRefreshingURL:url" in parser_error_block,
    "Parser network errors must finish only the refresh tracking for the failed URL.",
)

require(
    "_enforceKeepNewestLimitForFeed:feed" in finish_parsing_body
    and "SubscriptionManagerDidParseFeedNotification" in finish_parsing_body,
    "Success cleanup must keep keep-newest enforcement and did-parse notification for successfully parsed feeds.",
)

print("Feed refresh network failure UI regression checks passed.")
