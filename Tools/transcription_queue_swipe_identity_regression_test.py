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

# UIKit's row count and touch handlers must stay on the same rendered membership
# while the underlying queue changes behind an open swipe.
require(
    "return self.displayedItems.count;" in SOURCE
    and "[TranscriptionQueue shared].displayItems[indexPath.row]" not in SOURCE
    and "[TranscriptionQueue shared].displayItems[row]" not in SOURCE,
    "Row counts, taps, progress and accessory actions must share a stable displayedItems snapshot.",
)
queue_changed = method_body("- (void)_queueChanged")
require(
    "afterDelay:" not in queue_changed
    and "isEqualToArray:items" in queue_changed
    and queue_changed.index("self.displayedItems = items") < queue_changed.index("reloadData")
    and "_progressUpdated" in queue_changed,
    "Queue membership changes must render immediately; status-only changes must preserve existing cells.",
)
flush = method_body("- (void)_endSwipeInteractionAndFlushDeferredUpdate")
require(
    flush.index("self.displayedItems =") < flush.index("reloadData"),
    "The deferred reload must publish its matching snapshot before UIKit asks for rows.",
)

print("Transcription queue swipe identity regression checks passed")
