#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        if start < 0:
            return ""

        line_end = source.find("\n", start)
        if line_end < 0:
            return ""
        if source[start:line_end].strip().endswith(";"):
            search_start = line_end + 1
            continue
        break

    candidates = []
    for marker in ("\n- (", "\n+ (", "\n#pragma mark"):
        index = source.find(marker, start + len(signature))
        if index > start:
            candidates.append(index)

    end = min(candidates) if candidates else len(source)
    return source[start:end]


player_info = read("Classes/PlayerInfoViewController_v5.m")
image_cache = read("Classes/ImageCacheManager.m")
image_operation = read("Classes/ICImageCacheOperation.m")

layout_header = method_body(player_info, "- (void) layoutHeaderView")
reload_body = method_body(player_info, "- (void) reload\n")
set_image = method_body(player_info, "- (void) setImage:")
sync_helper = method_body(player_info, "- (void)_syncChapterImageCollectionToCurrentArtwork")
cell_for_item = method_body(player_info, "- (__kindof UICollectionViewCell *)collectionView:")
local_image = method_body(image_cache, "- (IC_IMAGE*) localImageForImageURL:")
episode_artwork_helper = method_body(player_info, "- (void)_setEpisodeArtworkForCell:")
artwork_cache_size_helper = method_body(player_info, "- (NSInteger)_episodeArtworkCacheSizeForCollectionView:")

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
require(
    "return [self cachedImageForKey:cacheKey];" in local_image
    and "initWithContentsOfFile" not in local_image,
    "The image cache local lookup is now memory-only; PlayerInfo must not rely on it as the only episode-artwork load path after foreground memory eviction.",
)
require(
    "_episodeArtworkCacheSizeForCollectionView:" in player_info
    and "CGRectGetWidth(collectionView.bounds)" in artwork_cache_size_helper
    and "CGRectGetWidth(self.view.bounds)" in artwork_cache_size_helper
    and "NSInteger artworkSize = [self _episodeArtworkCacheSizeForCollectionView:collectionView]" in episode_artwork_helper
    and "localImageForImageURL:imageURL size:artworkSize grayscale:NO" in episode_artwork_helper,
    "PlayerInfo chapter artwork cells must request artwork at the displayed collection width before falling back to async episode-artwork loading.",
)
require(
    "imageForURL:imageURL size:artworkSize grayscale:NO sender:cell completion:" in episode_artwork_helper,
    "PlayerInfo chapter artwork cells must start the async disk/network episode-artwork load at the displayed collection width when the memory-only local lookup misses.",
)
require(
    "self.image ?: self.imageView.image ?: cell.chapterImageView.image" in episode_artwork_helper
    and "Podcast Placeholder 580" not in episode_artwork_helper
    and "Podcast Placeholder 320" not in episode_artwork_helper,
    "PlayerInfo must keep the existing artwork visible during async reloads instead of flashing the gray placeholder on a memory-cache miss.",
)
require(
    "cellForItemAtIndexPath:indexPath" in episode_artwork_helper
    and "if (currentCell != cell)" in episode_artwork_helper,
    "Async episode-artwork completion must verify the collection cell still represents the same index path before replacing the image.",
)
require(
    "_loadCachedVariantImageLargeEnoughForSize" in image_operation
    and "candidateSize < minimumSize" in image_operation
    and "_loadBestCachedVariantImage" not in image_operation,
    "Large player artwork requests must never upscale a cached 56/72pt thumbnail into the full-size cover.",
)
