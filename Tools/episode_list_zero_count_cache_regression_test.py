#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "Model" / "CDEpisodeList.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("- (void) setCachedEpisodesCount:")
end = SOURCE.find("\n}", start)
require(start != -1 and end != -1, "Missing cached episode-count setter.")
setter = SOURCE[start:end]

require(
    "(_cachedEpisodesCount == nil) != (cachedEpisodesCount == nil)" in setter,
    "The count cache must distinguish an unknown nil value from the legitimate empty value @0.",
)
require(
    "isEqualToNumber" in setter,
    "Known episode counts should compare NSNumber values without collapsing nil into zero.",
)


print("Episode-list zero-count cache regression checks passed")
