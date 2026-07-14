#!/usr/bin/env python3
"""Pins the empty-area long-press crash in the subscriptions table."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "SubscriptionsTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("- (void) handleLongPress:(UILongPressGestureRecognizer*)recognizer")
require(start != -1, "Subscriptions long-press handler is missing.")
end = SOURCE.find("- (BOOL)gestureRecognizerShouldBegin:", start)
require(end != -1, "Subscriptions long-press handler boundary is missing.")
handler = SOURCE[start:end]

lookup = handler.find("indexPathForRowAtPoint:")
fetch = handler.find("[self.fetchController objectAtIndexPath:rowIndexPath]")
guard = handler.find("if (!rowIndexPath)")
require(lookup != -1 and fetch != -1, "Subscriptions long-press must resolve the touched row.")
require(lookup < guard < fetch and "return;" in handler[guard:fetch],
        "A long press below the last subscription must stop before passing nil to NSFetchedResultsController.")

print("Subscription long-press regression checks passed")
