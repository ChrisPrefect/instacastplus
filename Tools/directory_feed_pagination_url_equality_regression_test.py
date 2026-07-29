#!/usr/bin/env python3
"""Pin directory-feed pagination to NSURL value equality."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "DirectoryFeedViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.index("- (NSString*)_webViewHTMLForFeed:")
end = SOURCE.index("\n- (", start + 1)
renderer = SOURCE[start:end]

require(
    "feed.firstPageURL != feed.lastPageURL" not in renderer,
    "Separately parsed but value-equal NSURL instances must not create a false older-page link.",
)
require(
    "(feed.firstPageURL || feed.lastPageURL)"
    in renderer
    and "![feed.firstPageURL isEqual:feed.lastPageURL]" in renderer,
    "Pagination must distinguish unequal URL values while keeping nil/nil as one page.",
)

print("Directory-feed pagination URL-equality regression checks passed")
