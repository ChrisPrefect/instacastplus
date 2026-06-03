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
    "void (^completeOnMainContext)(NSUInteger) = ^(NSUInteger count) {",
    "    };",
)
normalized_main_completion = " ".join(main_completion.split())

require(
    "if (!calculatedList || mainError) { if (mainError) { ErrLog(" in normalized_main_completion,
    "Episode-list count completion must only log when the main-context re-fetch produced a real NSError.",
)
require(
    "if (!calculatedList || mainError) { if (mainError) { ErrLog(" in normalized_main_completion
    and "completion(count); return; }" in normalized_main_completion,
    "Episode-list count completion must still run when the main-context list cannot be re-fetched.",
)
require(
    "ErrLog(@\"error getting episode list in main context: %@\", mainError); return;" not in normalized_main_completion,
    "Episode-list count completion must not log a null main-context error when the context/list is simply gone.",
)
