#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "CDEpisodeList.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def source_between(source: str, start: str, end: str) -> str:
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


count_method = source_between(
    SOURCE,
    "- (void) calculateNumberOfEpisodesCompletion:(void (^)(NSUInteger numberOfEpisodes))completion",
    "- (void) invalidateCaches",
)
main_completion = source_between(
    count_method,
    "void (^completeOnMainContext)(NSUInteger, BOOL) = ^(NSUInteger count, BOOL updateCache) {",
    "\n    };",
)
normalized_main_completion = " ".join(main_completion.split())

require(
    "if (calculatedList && !mainError) { calculatedList.cachedEpisodesCount = @(count); }" in normalized_main_completion,
    "Episode-list count completion must only cache the count when the main-context re-fetch succeeded.",
)
require(
    "else if (mainError) { ErrLog(" in normalized_main_completion,
    "Episode-list count completion must only log when the main-context re-fetch produced a real NSError.",
)
require(
    "ErrLog(@\"error getting episode list in main context: %@\", mainError); return;" not in normalized_main_completion,
    "Episode-list count completion must still run after a main-context re-fetch error (no early return).",
)
require(
    "completion(count);" in normalized_main_completion,
    "Episode-list count completion must still serve the original caller when the list object went away while counting.",
)
require(
    "for (void (^pendingCompletion)(NSUInteger) in completions) { pendingCompletion(count); }" in normalized_main_completion,
    "Episode-list count completion must drain every waiting completion.",
)
