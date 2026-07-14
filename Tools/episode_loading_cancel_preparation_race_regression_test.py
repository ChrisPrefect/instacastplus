#!/usr/bin/env python3
"""Pins cancellation failures to an episode job still being prepared off-main."""

from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "Classes"
    / "Model"
    / "EpisodeLoadingManager.m"
).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start >= 0, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace >= 0, f"Missing body: {signature}")
        if SOURCE.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


queue = body("- (void)queuePendingEpisodesForFeed:")
cancel = body("- (void)cancelLoadingForFeed:")
failure_info = body("- (NSDictionary*)_loadInfoForCancellationFailureAtFeedURL:")
handle_failure = body("- (void)_handleLoadFailure:")
retry = body("- (void)retryLoadingForFeed:")

require("loadingErrorGenerations" in SOURCE,
        "Loading errors need generation ownership so a later preparation cannot erase a current failure.")
require("_loadInfoForCancellationFailureAtFeedURL:feedURL" in cancel,
        "Count/save cancellation failures must capture the generation that is still being prepared.")
require("_preparingGenerations[feedURL]" in failure_info,
        "A preparing generation must take precedence over the older pending job during cancellation failure.")
require("_preparingGenerations[feedURL]" in handle_failure,
        "Failure ownership must recognize the current preparing generation.")
require("_loadingErrorGenerations[feedURL]" in queue and
        "isEqualToString:generation" in queue,
        "Preparation success may clear only an error owned by an older generation.")
require("queueIsCurrent && !persistenceError && isLatestPreparation" in queue and
        "!isLatestPreparation && !persistenceError" in queue,
        "An older preparation must neither replace nor leak past a newer generation that won the race.")
require("_loadingErrorGenerations removeObjectForKey:feedURL" in retry,
        "Explicit retry must release both the error and its generation owner.")


def preparation_commit(error_generation, generation: str) -> bool:
    """True means the committed job remains blocked for explicit retry."""
    return error_generation == generation


require(preparation_commit("new", "new"),
        "A cancellation failure during preparation must survive that preparation's commit.")
require(not preparation_commit("old", "new"),
        "A genuinely new preparation may clear an older generation's error.")

print("Episode loading cancel/preparation race regression checks passed")
