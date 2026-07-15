#!/usr/bin/env python3
"""Pins stream-cache file validation and midpoint progress semantics."""

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CACHE_MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
CACHE_OPERATION = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()
PLAYBACK_CONTROLS = (ROOT / "Classes" / "PlaybackControlsViewController.m").read_text()
FULLSCREEN_PLAYER = (ROOT / "Classes" / "PlayerFullscreenVideoViewController.m").read_text()
EPISODE_CELL = (ROOT / "Classes" / "EpisodesTableViewCell.m").read_text()
EPISODES_CONTROLLER = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing method body: {signature}")
        if source.find(";", start, brace) == -1:
            break
        search_start = brace

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


streaming_temp_url = method_body(
    CACHE_MANAGER,
    "- (NSURL*)streamingTempURLForCachedEpisode:",
)
require(
    "cacheURL.pathExtension" in streaming_temp_url
    and "stringByDeletingPathExtension" in streaming_temp_url
    and 'stringWithFormat:@"%@.part.%@"' in streaming_temp_url
    and 'stringByAppendingString:@".part"' not in streaming_temp_url,
    "A completed streaming cache must retain the media extension as its final "
    "extension so AVFoundation can validate the downloaded audio file.",
)

# Keeping an extension is only useful if it describes the media. The normal download
# path already owns the supported MIME contract; streaming must normalize parameters
# and resolve every supported audio MIME to the same suffix. In particular, common
# extensionless CDN URLs must not silently become `.mp3` before AVFoundation validates
# them.
normal_download_extension = method_body(
    CACHE_OPERATION,
    "- (NSString*)fileExtensionForMIMEType:",
)
stream_episode_extension = method_body(
    CACHE_MANAGER,
    "- (NSString*) _extensionForEpisode:",
)
shared_extension = method_body(
    CACHE_MANAGER,
    "+ (NSString*)fileExtensionForMIMEType:",
)


def mime_extension_pairs(source: str) -> dict[str, str]:
    return dict(re.findall(r'@"([^"]+)"\s*:\s*@"([^"]+)"', source))


reference_audio_extensions = {
    mime: extension
    for mime, extension in mime_extension_pairs(shared_extension).items()
    if mime.startswith("audio/")
}
stream_audio_extensions = mime_extension_pairs(shared_extension)
missing_or_wrong_audio_extensions = {
    mime: (extension, stream_audio_extensions.get(mime))
    for mime, extension in reference_audio_extensions.items()
    if stream_audio_extensions.get(mime) != extension
}
require(
    not missing_or_wrong_audio_extensions,
    "Streaming must preserve the normal downloader's supported audio MIME contract; "
    f"missing/wrong mappings: {missing_or_wrong_audio_extensions}.",
)
require(
    '[CacheManager fileExtensionForMIMEType:mimeType]' in normal_download_extension
    and '[CacheManager fileExtensionForMIMEType:media.mimeType]' in stream_episode_extension,
    "Normal and streaming downloads must share one MIME-to-extension contract.",
)
require(
    'componentsSeparatedByString:@";"' in shared_extension
    and "whitespaceAndNewlineCharacterSet" in shared_extension,
    "Streaming MIME lookup must normalize parameters and surrounding whitespace before "
    "choosing the final file extension.",
)

for mime, expected_extension in {
    "audio/aac": "aac",
    "audio/wav": "wav",
    "audio/flac": "flac",
}.items():
    normalized_mime = f"{mime}; charset=binary".split(";", 1)[0].strip().lower()
    actual_extension = stream_audio_extensions.get(normalized_mime, "mp3")
    require(
        actual_extension == expected_extension,
        f"An extensionless {mime} stream must end in .{expected_extension}, not .mp3.",
    )

stream_extension_adoption = method_body(
    (ROOT / "Classes" / "PlaybackManager.m").read_text(),
    "- (BOOL)_adoptResponseFileExtensionWithError:",
)
stream_validation = method_body(
    (ROOT / "Classes" / "PlaybackManager.m").read_text(),
    "- (void)_updateCoverageStateAndImportIfNeeded",
)
require(
    "fileExtensionForMIMEType:self.mimeType" in stream_extension_adoption
    and "moveItemAtURL:previousURL toURL:correctedURL" in stream_extension_adoption,
    "The actual HTTP response MIME must correct an extensionless or mislabeled stream file before validation.",
)
require(
    stream_validation.find("_adoptResponseFileExtensionWithError:")
    < stream_validation.find("AVURLAsset URLAssetWithURL:self.tempURL"),
    "Response MIME correction must finish before AVFoundation validates the completed stream file.",
)

for source, controller_name in (
    (PLAYBACK_CONTROLS, "compact playback controls"),
    (FULLSCREEN_PLAYER, "fullscreen player"),
):
    effective_progress = method_body(
        source,
        "- (double)_effectiveLoadProgressForPlaybackManager:",
    )
    streaming_branch = effective_progress[
        effective_progress.find("if (pman.streamingCacheActive") :
    ]
    require(
        "return pman.streamingCacheProgress;" in streaming_branch
        and "MAX(bufferedProgress, pman.streamingCacheProgress)" not in streaming_branch,
        f"The {controller_name} must show whole-file byte coverage during stream "
        "caching, not the absolute end of a small buffer near the seek position.",
    )

cell_state = method_body(EPISODE_CELL, "- (void) updatePlayComboButtonState")
require(
    "isCachingEpisode:episode" in cell_state
    and "isLoadingEpisode:episode" in cell_state
    and "pman.streamingCacheProgress" in cell_state
    and "kEpisodePlayButtonComboStateFilling" in cell_state,
    "Episode rows must expose active stream caching and its byte progress.",
)

controller_observation = method_body(EPISODES_CONTROLLER, "- (void) _setObserving:")
require(
    'forKeyPath:@"cachingEpisodes"' in controller_observation
    and "CacheManagerDidUpdateNotification" in controller_observation,
    "Visible episode rows must be refreshed when stream caching starts or advances.",
)

print("Download streaming midpoint regression checks passed")
