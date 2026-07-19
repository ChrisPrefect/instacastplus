#!/usr/bin/env python3
"""Sponsor auto-skip must reuse the ordinary chapter-keyword pipeline."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()
PLAYER_INFO = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
WATCH_EPISODE = (ROOT / "InstacastWatch" / "WatchEpisode.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def objc_method(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing Objective-C method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body for Objective-C method: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise SystemExit(f"Unterminated Objective-C method: {signature}")


effective_names = objc_method(PLAYBACK, "- (NSArray*)_effectiveAutoSkipNamesForFeed:")
require(
    "_autoSkipSponsorsEnabledForFeed:" in effective_names
    and '@"Sponsor: "' in effective_names
    and "addObject:" in effective_names,
    "Enabled sponsor skipping does not add the exact `Sponsor: ` tag to the ordinary skip-name list.",
)
compute_markers = objc_method(PLAYBACK, "- (void)_computeAutoSkipMarkers")
require(
    "_effectiveAutoSkipNamesForFeed:" in compute_markers
    and "matchingSkipNameForChapter:" in compute_markers,
    "Sponsor chapters no longer pass through the existing keyword matcher and skip-marker pipeline.",
)
effective_names_position = compute_markers.find("_effectiveAutoSkipNamesForFeed:")
no_chapters_position = compute_markers.find("if (!episode || !self.chapters || self.chapters.count == 0)")
require(
    effective_names_position >= 0
    and no_chapters_position >= 0
    and effective_names_position < no_chapters_position
    and '@"skipNameCount": @(skipNames.count)' in compute_markers[: compute_markers.find("return;", no_chapters_position)],
    "No-chapters diagnostics do not report the effective skip-name list, including the enabled Sponsor keyword.",
)

for forbidden in [
    "ICGeneratedSponsorSkipName",
    "includeGeneratedSponsors",
    "_skipNameForChapter:",
    "chapter.generatedSponsor",
]:
    require(
        forbidden not in PLAYBACK,
        f"PlaybackManager still has a second sponsor-specific recognition path: {forbidden}",
    )

player_cell = objc_method(
    PLAYER_INFO,
    "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath",
)
require(
    "autoSkipsChapterTitle:" in player_cell
    and "chapter.generatedSponsor" not in player_cell,
    "The chapter list still marks sponsors through a second flag instead of the same effective skip keywords.",
)

watch_skip = objc_method(WATCH_EPISODE, "func chapterWillBeSkipped(_ chapter: WatchChapter) -> Bool")
require(
    "var effectiveSkipNames = skipChapterNames" in watch_skip
    and "if autoSkipSponsors" in watch_skip
    and 'effectiveSkipNames.append("Sponsor: ")' in watch_skip
    and "return effectiveSkipNames.contains" in watch_skip
    and "!name.isEmpty && lowerTitle.contains(name.lowercased())" in watch_skip
    and 'hasPrefix("sponsor:")' not in watch_skip,
    "Watch sponsor marking does not reuse the ordinary contains matcher with the exact `Sponsor: ` skip name.",
)

print("Playback sponsor keyword reuse regression checks passed.")
