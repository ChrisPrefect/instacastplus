from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


subscription_source = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
parser_source = (ROOT / "Classes" / "Parser" / "ICFeedParser.m").read_text()
cell_source = (ROOT / "Classes" / "EpisodesTableViewCell.m").read_text()

method_start = subscription_source.index(
    "- (void) updateLocalFeedInfo:(CDFeed*)localFeed withRemoteFeed:(ICFeed*)remoteFeed force:(BOOL)force"
)
normal_start = subscription_source.index("if (!force)", method_start)
force_start = subscription_source.index("\n    else\n", normal_start)
normal_refresh_block = subscription_source[normal_start:force_start]
refresh_feed_start = subscription_source.index("- (void) refreshFeed:(CDFeed*)feed etagHandling:(BOOL)etagHandling completion:")
check_timer_start = subscription_source.index("- (void) checkRefreshOperationsTimer:", refresh_feed_start)
refresh_feed_block = subscription_source[refresh_feed_start:check_timer_start]

require(
    "NSInteger remoteDuration = remoteEpisode.duration;" in normal_refresh_block
    and "localEpisode.duration = (int32_t)remoteDuration;" in normal_refresh_block,
    "Normal feed refreshes must copy positive parser durations onto existing episodes before playback fills AVAsset duration.",
)
require(
    "remoteDuration > 0" in normal_refresh_block,
    "Normal feed refreshes must not overwrite an existing playback-derived duration with an empty feed duration.",
)
require(
    "- (BOOL)_feedNeedsDurationMetadataRefresh:(CDFeed*)feed" in subscription_source
    and "episode.duration <= 0" in subscription_source
    and "!episode.consumed" in subscription_source
    and "episode.position <= 0" in subscription_source,
    "Feeds with unplayed, unstarted local episodes missing duration must be detected before ETag handling.",
)
require(
    "BOOL needsDurationMetadataRefresh = [self _feedNeedsDurationMetadataRefresh:feed];" in refresh_feed_block
    and "if (etagHandling && !needsDurationMetadataRefresh)" in refresh_feed_block
    and "feedParser.etag = feed.etag;" in refresh_feed_block,
    "Refreshes for feeds with local duration holes must bypass If-None-Match so the feed body is parsed.",
)
require(
    "if (!etagHandling || needsDurationMetadataRefresh || ![localFeed.contentHash isEqual:parsedFeed.contentHash])" in refresh_feed_block,
    "Refreshes that are repairing local duration holes must merge even when feed contentHash matches.",
)
require(
    "itunes:duration" in parser_source
    and "_contentHashString" in parser_source[
        parser_source.index('else if ([elementName isEqualToString:@"itunes:duration"])') :
        parser_source.index('else if ([elementName isEqualToString:@"itunes:image"])')
    ],
    "Feed content hashes must include itunes:duration so duration-only metadata repairs trigger a merge.",
)
require(
    "NSInteger duration = episode.duration-episode.position;" in cell_source,
    "Episode rows no longer display duration from the persisted episode duration path covered by this regression.",
)
