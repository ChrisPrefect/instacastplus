#!/usr/bin/env python3
from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "FeedEpisodesTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


for signature in (
    "- (void) _filterFavoriteEpisode",
    "- (void) _filterUnlistenedEpisode",
    "- (void) _filterUnfinishedEpisode",
    "- (void) _filterUnplayedAndStartedEpisode",
):
    body = method_body(signature)
    require(
        "archived == %@" in body and ", @NO" in body,
        f"{signature} must not re-display archived/deleted episodes.",
    )


print("Feed episode archived-filter regression checks passed")
