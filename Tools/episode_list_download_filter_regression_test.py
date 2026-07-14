from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


list_source = (ROOT / "Classes" / "Model" / "CDEpisodeList.m").read_text()
model_source = (
    ROOT
    / "Resources"
    / "Models"
    / "Model4.xcdatamodeld"
    / "Model.xcdatamodel"
    / "contents"
).read_text()


require(
    'attribute name="downloaded" optional="YES" transient="YES"' in model_source,
    "The current Episode.downloaded model attribute is no longer transient; revisit the list download filter regression.",
)
require(
    '[NSPredicate predicateWithFormat:@"downloaded == NO"]' not in list_source,
    "Episode lists must not fetch-filter on the transient Episode.downloaded field; the not-downloaded filter then returns no rows.",
)
require(
    list_source.count("[CacheManager sharedCacheManager].cachedEpisodeObjectHashes") >= 2
    and "[[CacheManager sharedCacheManager] cachedEpisodes]" not in list_source,
    "Episode list and count paths must use the CacheManager hash index without materializing the cached episode set.",
)
