#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def read(path: str) -> str:
    return (ROOT / path).read_text()


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")

    candidates = []
    for marker in ("\n- (", "\n+ (", "\n@end"):
        index = source.find(marker, start + len(signature))
        if index > start:
            candidates.append(index)

    end = min(candidates) if candidates else len(source)
    return source[start:end]


playback = read("Classes/PlaybackViewController.m")
player = read("Classes/PlayerController.m")

simultaneous = method_body(
    playback,
    "- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:",
)
should_begin = method_body(playback, "- (BOOL)gestureRecognizerShouldBegin:")

require(
    "[playbackController addDismissalPanGestureRecognizerToView:self.infoViewController.chapterImagesCollection]" in player,
    "The player cover/chapter artwork collection must install the same interactive dismissal pan used by the navigation bar.",
)
require(
    "velocity.y <= 0 || velocity.y <= fabs(velocity.x)" in should_begin,
    "The cover dismissal pan must only begin for a clear downward gesture, so horizontal chapter-artwork paging remains unchanged.",
)
require(
    "return NO;" in simultaneous
    and "otherGestureRecognizer == scrollView.panGestureRecognizer" not in simultaneous,
    "Once the downward dismissal pan begins on the artwork collection, horizontal paging must be locked instead of recognizing simultaneously with the collection view pan.",
)
require(
    "_dismissalTranslationBaselineY" not in playback
    and "effectiveTranslationY" not in playback
    and "translation.y / h" in playback,
    "The interactive dismissal must follow the full pan translation instead of adding a second dead zone after UIKit recognizes the gesture.",
)
require(
    playback.find("[self.parent beginInteractiveDismissing]")
    < playback.find("[self updateInteractiveTransition:percent]"),
    "The player must apply UIKit's already accumulated translation as soon as interactive dismissal begins.",
)
