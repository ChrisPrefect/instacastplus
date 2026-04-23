from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


parser_media_header = (ROOT / "Classes" / "Parser" / "ICMedia.h").read_text()
require(
    "@property (nonatomic, strong) NSString* codec;" in parser_media_header,
    "Parser media does not persist feed codec metadata.",
)

feed_parser = (ROOT / "Classes" / "Parser" / "ICFeedParser.m").read_text()
require(
    'media.codec = ICFeedParserCodecFromAttributes(attributes);' in feed_parser,
    "Feed parser does not capture enclosure codec metadata.",
)
require(
    "_episode.media = ICFeedParserPruneLegacyVideoCodecs(_episode.media);" in feed_parser,
    "Feed parser does not remove H.264/AVC alternatives before storing an episode.",
)

parser_episode = (ROOT / "Classes" / "Parser" / "ICEpisode.m").read_text()
require(
    "ICMediaIsLegacyAVCVideo(media)" in parser_episode,
    "Parser episode media preference can still select H.264/AVC video.",
)
require(
    "ICMediaIsNonHEVCVideo(media)" in parser_episode,
    "Parser episode media preference can still select generic non-H.265 video.",
)
require(
    "ICMediaIsHEVCVideo(media)" in parser_episode,
    "Parser episode media preference does not explicitly prioritize H.265/HEVC video.",
)

core_data_episode = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()
require(
    "ICCDMediumIsLegacyAVCVideo(media)" in core_data_episode,
    "Persisted episode media preference can still select H.264/AVC video.",
)
require(
    "ICCDMediumIsNonHEVCVideo(media)" in core_data_episode,
    "Persisted episode media preference can still select generic non-H.265 video.",
)
require(
    "ICCDMediumIsHEVCVideo(media)" in core_data_episode,
    "Persisted episode media preference does not explicitly prioritize H.265/HEVC video.",
)
