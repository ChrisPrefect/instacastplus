#!/usr/bin/env python3
"""Pins explicit ownership of list-driven continuous playback.

Regression: a list source such as "Recently Played" survived a later manual episode
start merely because the new episode also matched that broad dynamic list. With an
empty Up Next queue, finishing the manually started episode then resumed the stale
list even though per-feed continuous playback was disabled.

Manual playback may keep a source only when a list screen explicitly arms that source.
Only explicitly identified continuation, transport, or resume paths may inherit it.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    require(signature in source, f"Missing method: {signature}")
    return source.split(signature, 1)[1].split("\n- (", 1)[0]


audio_header = (ROOT / "Classes" / "AudioSession.h").read_text()
audio_session = (ROOT / "Classes" / "AudioSession.m").read_text()
playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
playback_view = (ROOT / "Classes" / "PlaybackViewController.m").read_text()
player_info = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
scene_delegate = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
smarthome = (ROOT / "Classes" / "SmarthomeManager.m").read_text()
widget_exporter = (ROOT / "Classes" / "WidgetDataExporter.m").read_text()
intent_bridge = (ROOT / "Classes" / "AppIntents" / "ICIntentBridge.swift").read_text()

require(
    "preservingPlaybackSource:(BOOL)preservingPlaybackSource" in audio_header,
    "AudioSession needs an explicit playback-source ownership flag for automatic transitions.",
)

resolver = method_body(
    audio_session,
    "- (void) _resolvePlaybackSourceListForEpisode:(CDEpisode*)anEpisode",
)
require(
    "preservingPlaybackSource:(BOOL)preservingPlaybackSource" in resolver,
    "Source resolution must distinguish manual starts from automatic continuations.",
)
require(
    "if (!preservingPlaybackSource)" in resolver
    and "self.sourceEpisodeListUID = nil;" in resolver,
    "A manual start without an explicitly armed list must clear the stale source unconditionally.",
)
require(
    resolver.find("pendingSourceEpisodeListUID") < resolver.find("if (!preservingPlaybackSource)"),
    "An explicitly armed list must still win before the manual-start clearing rule.",
)

explicit_play = method_body(
    audio_session,
    "- (void) playEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent at:(NSTimeInterval)time autostart:(BOOL)autostart",
)
require(
    "preservingPlaybackSource:NO" in explicit_play,
    "The existing public play API represents a manual start and must not inherit a stale list source.",
)

restore_play = method_body(
    audio_session,
    "- (void) restorePlaybackEpisode:(CDEpisode*)anEpisode",
)
require(
    "preservingPlaybackSource:YES" in restore_play,
    "Restoring persisted playback must preserve its persisted source ownership.",
)

for signature in (
    "- (void) _continueOpeningAsset:",
    "- (void)_finishEpisodeDueToSkip:",
    "- (void) playerItemDidPlayToEndTimeNotification:",
):
    require(
        "playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES"
        in method_body(playback_manager, signature),
        f"The automatic continuation path must transfer source ownership: {signature}",
    )

# Relaunch restores AudioSession.episode and sourceEpisodeListUID before PlaybackManager
# has opened its player. Reloading that exact episode must not look like a manual start.
toggle_play = method_body(audio_session, "- (void) togglePlay")
require(
    "playEpisode:self.episode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES" in toggle_play,
    "AudioSession togglePlay must preserve the restored source when reopening its current episode.",
)

present_player = method_body(
    playback_view,
    "- (void) _presentFromParentViewController:(UIViewController*)parentViewController",
)
require(
    "preservingPlaybackSource:[audioSession.episode isEqual:self.episode]" in present_player,
    "A forced player reload may preserve the source only when it reloads AudioSession's current episode.",
)
require(
    "playEpisode:audioSession.episode queueUpCurrent:NO at:0 autostart:autostart preservingPlaybackSource:YES"
    in present_player,
    "Opening the restored AudioSession episode must preserve its persisted source.",
)

require(
    player_info.count(
        "playEpisode:episodeToPlay queueUpCurrent:NO at:MAX(0.0, chapter.timecode) autostart:YES preservingPlaybackSource:YES"
    ) == 1,
    "Reloading the current episode from Player Info chapters must preserve its source.",
)
require(
    "[audioSession playEpisode:episode];" in player_info,
    "Selecting an Up Next row remains a manual queue selection and must use the non-preserving API.",
)

require(
    scene_delegate.count("playEpisode:episodeToPlay queueUpCurrent:NO") == 2
    and scene_delegate.count("playEpisode:episodeToPlay queueUpCurrent:NO at:MAX(0.0, chapterTime) autostart:YES preservingPlaybackSource:YES") == 1
    and scene_delegate.count("playEpisode:episodeToPlay queueUpCurrent:NO at:chapterTime autostart:YES preservingPlaybackSource:YES") == 1,
    "Both CarPlay chapter reload paths must preserve the current episode's source.",
)
require(
    "playEpisode:episode queueUpCurrent:NO at:MAX(0, startTime) autostart:YES];" in scene_delegate,
    "Selecting a CarPlay episode remains a manual start and must clear stale list ownership.",
)

# Commands which deliberately obtain their target from nextPlayableEpisode are
# continuations of the current transport context, not independent manual starts.
require(
    "playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES" in smarthome,
    "The smart-home next-episode command must preserve playback-source ownership.",
)
require(
    "[as playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES];"
    in widget_exporter,
    "The widget next-episode command must preserve playback-source ownership.",
)
require(
    "[audioSession playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES];"
    in scene_delegate,
    "The widget deep-link next-episode command must preserve playback-source ownership.",
)
intent_next = intent_bridge.split("static func nextEpisode()", 1)[1].split("\n    }", 1)[0]
require(
    "preservingPlaybackSource: true" in intent_next,
    "The App Intent next-episode command must preserve playback-source ownership.",
)
require(
    "playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES"
    in method_body(playback_manager, "- (void) nextTrack")
    and "playEpisode:previousEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES"
    in method_body(playback_manager, "- (void) previousTrack"),
    "Explicit next/previous transport controls must preserve playback-source ownership.",
)
require(
    "[as playEpisode:previousEpisode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES];"
    in widget_exporter,
    "The widget previous-episode transport must preserve playback-source ownership.",
)
require(
    "[audioSession playEpisode:playlist[index - 1] queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES];"
    in scene_delegate,
    "The widget deep-link previous-episode transport must preserve playback-source ownership.",
)

# Widget/Siri play actions can also reopen the episode restored into AudioSession while
# PlaybackManager is still empty. Preserve only when both identities really match.
require(
    "preservingPlaybackSource:[as.episode isEqual:episode]" in widget_exporter,
    "Widget resume must preserve ownership only for AudioSession's restored episode.",
)
require(
    "preservingPlaybackSource:[audioSession.episode isEqual:episode]" in scene_delegate,
    "Widget deep-link resume must preserve ownership only for AudioSession's restored episode.",
)
require(
    intent_bridge.count("preservingPlaybackSource: session.episode?.isEqual(episode) == true") == 2,
    "Siri play and play/pause must preserve ownership only when reopening AudioSession's restored episode.",
)

print("playback source ownership regression checks passed")
