#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        return ""

    candidates = []
    for marker in ("\n- (", "\n+ (", "\n#pragma mark"):
        index = source.find(marker, start + len(signature))
        if index > start:
            candidates.append(index)

    end = min(candidates) if candidates else len(source)
    return source[start:end]


player_info = read("Classes/PlayerInfoViewController_v5.m")

layout_header = method_body(player_info, "- (void) layoutHeaderView")
reload_body = method_body(player_info, "- (void) reload\n")
set_image = method_body(player_info, "- (void) setImage:")
sync_helper = method_body(player_info, "- (void)_syncChapterImageCollectionToCurrentArtwork")

require(
    sync_helper,
    "PlayerInfoViewController needs one source of truth that maps PlaybackManager.currentArtwork to the chapter image collection index.",
)
require(
    "pman.currentArtwork >= 0" in sync_helper
    and "pman.currentArtwork + 1" in sync_helper
    and "[self changeChapterImageIndex:collectionIndex]" in sync_helper,
    "The chapter image collection sync must preserve the active chapter artwork: currentArtwork 0 maps to collection index 1, not the episode-artwork page.",
)
require(
    "[self.chapterImagesCollection reloadData]" in layout_header
    and "[self _syncChapterImageCollectionToCurrentArtwork]" in layout_header
    and layout_header.index("[self.chapterImagesCollection reloadData]") < layout_header.index("[self _syncChapterImageCollectionToCurrentArtwork]"),
    "After foreground/layout reloads, the player must re-scroll to the current chapter artwork instead of leaving the collection on index 0.",
)
require(
    "[self _syncChapterImageCollectionToCurrentArtwork]" in reload_body,
    "PlayerInfoViewController reload must preserve the current chapter artwork page.",
)
require(
    "[self _syncChapterImageCollectionToCurrentArtwork]" in set_image,
    "Refreshing the player image while returning to the app must preserve the current chapter artwork page.",
)
require(
    "[self updateCollectionsImage:0]" not in layout_header
    and "[self updateCollectionsImage:0]" not in reload_body
    and "[self updateCollectionsImage:0]" not in set_image,
    "Layout/image refreshes still hard-reset the chapter image collection to the episode artwork page.",
)
