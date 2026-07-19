#!/usr/bin/env python3
"""Pins delivery of generated transcription analysis to active UI and Spotlight."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method {signature!r}")
    next_method = source.find("\n- (", start + len(signature))
    return source[start:] if next_method < 0 else source[start:next_method]


player = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
episode_view = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
database = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


# The active player has already resolved the effective source order
# (generated overlay > embedded chapters > publisher chapters). Its chapter list must
# render that exact timeline without writing transient overlay splits to Core Data.
require(
    '@"chapters"' in player and '@"playingEpisode.chapters"' not in player,
    "PlayerInfo still observes only the publisher Core Data relationship instead of PlaybackManager.chapters.",
)
display_method = method_body(
    player,
    "- (NSArray*)_displayChaptersForEpisode:(CDEpisode*)episode playbackManager:(PlaybackManager*)pman",
)
for token in [
    "pman.chapters",
    "sameEpisodeLoaded",
    "ICMetadataChapter",
    "ICPlayerChapterDisplayItem",
    "CMTimeGetSeconds",
]:
    require(token in display_method, f"Playback chapter overlay mapping is missing {token!r}.")
require(
    "insertNewObjectForEntityForName" not in display_method
    and "NSEntityDescription" not in display_method,
    "The generated player overlay must stay transient and never overwrite publisher Core Data chapters.",
)
require(
    player.count("_displayChaptersForEpisode:") >= 4,
    "Initial load, PlaybackManager chapter KVO, and transcription changes must share the overlay mapping.",
)
require(
    "autoSkipsChapterTitle:" in method_body(
        player,
        "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath",
    )
    and "chapter.generatedSponsor" not in method_body(
        player,
        "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath",
    ),
    "Sponsor splits are not visibly marked through the same effective chapter-keyword rule as every other skipped chapter.",
)


# One artifact-change notification is the canonical Spotlight trigger. The old finish
# notification immediately precedes it and therefore must no longer be observed.
require(
    database.count('name:@"ICTranscriptionDidChangeNotification"') == 1,
    "DatabaseManager must register exactly one transcription artifact-change observer.",
)
require(
    "name:ICTranscriptionDidFinishNotification" not in database
    and "transcriptionDidFinishNotification:" not in database,
    "The old finish observer still causes a duplicate Spotlight update.",
)
spotlight_method = method_body(database, "- (void) transcriptionDidChangeNotification:(NSNotification*)notification")
require(
    "episodeHash.length == 0" in spotlight_method
    and "[self.objectContext performBlock:" in spotlight_method,
    "Spotlight transcription updates must validate the episode hash and enter the main Core Data context queue.",
)
require(
    spotlight_method.count("[self.spotlightIndexer updateEpisode:episode]") == 1,
    "A transcription artifact change must update the affected Spotlight episode exactly once.",
)


# The open episode view updates only its own visible document. It must preserve the
# current scroll position and hop to main when a notification originates elsewhere.
require(
    "selector:@selector(transcriptionDidChangeNotification:)" in episode_view
    and 'name:@"ICTranscriptionDidChangeNotification"' in episode_view,
    "EpisodeViewController does not observe generated analysis changes.",
)
episode_method = method_body(episode_view, "- (void) transcriptionDidChangeNotification:(NSNotification*)notification")
for token in [
    "[NSThread isMainThread]",
    "dispatch_async(dispatch_get_main_queue()",
    "self.episode.objectHash",
    "self.view.window == nil",
    "self.sharedWebView.superview != self.view",
    "_loadWebContentPreservingScrollOffset:YES",
]:
    require(token in episode_method, f"Visible episode analysis refresh is missing {token!r}.")
preserving_load = method_body(episode_view, "- (void) _loadWebContentPreservingScrollOffset:(BOOL)preserveScrollOffset")
require(
    "contentOffset" in preserving_load
    and "setContentOffset:previousContentOffset animated:NO" in preserving_load,
    "Refreshing the AI summary must preserve the user's Show Notes scroll position.",
)

print("transcription analysis visibility regression checks passed")
