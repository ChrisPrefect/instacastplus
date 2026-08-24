#!/usr/bin/env python3
"""Keep a configured transcription delete swipe bound to its queue item."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()


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


trailing = method_body("trailingSwipeActionsConfigurationForRowAtIndexPath:")
before_handler, handler = trailing.split("handler:^", 1)
require(
    "ICTranscriptionQueueItem* item" in before_handler
    and "NSString* episodeHash = [item.episodeHash copy]" in before_handler
    and "BOOL usesServerTranscription = item.usesServerTranscription" in before_handler,
    "A transcription swipe must capture the exact queue item, its hash, and backend when configured.",
)
require(
    "displayItems[indexPath.row]" not in handler
    and "indexOfObjectIdenticalTo:item" in handler
    and "indexOfObjectPassingTest:" not in handler
    and "dequeueEpisodeHash:episodeHash" in handler
    and "dequeueWithEpisodeHash:episodeHash" in handler,
    "Executing the swipe must require the captured item instance, not a replacement at its old row.",
)
require(
    "pendingReloadAfterSwipe" in handler
    and "_endSwipeInteractionAndFlushDeferredUpdate" in handler,
    "A row that moved while its swipe was open needs a consistent deferred structural reload.",
)

visible = [("L", False), ("S", True)]
captured = visible[1]
current = [("L", False), ("N", False), ("S", True)]
require(captured == ("S", True) and current[1] == ("N", False),
        "The fixture must reproduce mixed-queue identity drift.")

print("Transcription queue swipe identity regression checks passed")
