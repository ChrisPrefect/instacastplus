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
    "for (UIView* view = gestureRecognizer.view; view; view = view.superview)" not in simultaneous,
    "The cover dismissal pan must not recognize simultaneously with ancestor scroll views; the player table view would move the header while the sheet transition moves the whole player.",
)
require(
    "(UIScrollView*)gestureRecognizer.view" in simultaneous
    and "otherGestureRecognizer == scrollView.panGestureRecognizer" in simultaneous,
    "If simultaneous recognition is allowed, it must be limited to the scroll view that owns the dismissal pan, not the PlayerInfo table view ancestor.",
)
