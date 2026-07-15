#!/usr/bin/env python3
"""Pins every UI unsubscribe action to the complete feed lifecycle owner."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "FeedViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
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


unsubscribe = body("- (void) unsubscribeAction:")
require("[[SubscriptionManager sharedSubscriptionManager]" in unsubscribe and
        "unsubscribeFeed:self.feed" in unsubscribe and
        "completion:^(NSError* error)" in unsubscribe,
        "Feed detail unsubscribe must use the asynchronous lifecycle owner that durably commits before cleanup.")
require("[DMANAGER unsubscribeFeed:self.feed]" not in unsubscribe and
        "removeCacheForFeed:self.feed" not in unsubscribe,
        "A UI controller must not execute only a partial unsubscribe transaction.")
require("presentError:error" in unsubscribe and
        unsubscribe.find("if (error)") < unsubscribe.find("popToRootViewControllerAnimated"),
        "Feed detail unsubscribe must remain visible and explain a commit failure.")
require("afterDelay:0.3" not in unsubscribe,
        "Feed detail unsubscribe must not hide persistence ordering behind a delay.")

print("Feed unsubscribe lifecycle regression checks passed")
