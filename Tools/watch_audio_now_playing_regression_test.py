#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


watch_player = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()
watch_controller = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
audio_session = (ROOT / "Classes" / "AudioSession.m").read_text()
audio_session_header = (ROOT / "Classes" / "AudioSession.h").read_text()
playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
scene_delegate = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
project = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()


def objc_method(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise SystemExit(f"Unterminated method body: {signature}")


require(
    "startSilentPlayback" not in audio_session
    and "startSilentPlayback" not in audio_session_header
    and "startSilentPlayback" not in playback_manager,
    "Paused iOS playback must not keep the app alive with silent audio; it corrupts Lock Screen/Dynamic Island playback state.",
)
require(
    "silentPlayer" not in audio_session and "Silence.caf" not in audio_session,
    "The silent AVPlayer keep-alive workaround must be removed instead of hidden behind another call site.",
)
require(
    "Silence.caf" not in project and not (ROOT / "Resources" / "Sounds" / "Silence.caf").exists(),
    "The obsolete silent-audio resource must not remain bundled after removing the keep-alive workaround.",
)

require(
    "import MediaPlayer" in watch_player,
    "The Watch player must publish MediaPlayer now-playing metadata so it appears in watchOS Now Playing during workouts.",
)
require(
    "MPNowPlayingInfoCenter.default().nowPlayingInfo" in watch_player
    and "MPMediaItemPropertyTitle" in watch_player
    and "MPMediaItemPropertyArtist" in watch_player
    and "MPMediaItemPropertyAlbumTitle" in watch_player
    and "MPMediaItemPropertyPlaybackDuration" in watch_player
    and "MPNowPlayingInfoPropertyElapsedPlaybackTime" in watch_player
    and "MPNowPlayingInfoPropertyPlaybackRate" in watch_player,
    "The Watch player must keep title, podcast, duration, elapsed time, and rate in MPNowPlayingInfoCenter.",
)
require(
    "MPRemoteCommandCenter.shared()" in watch_player
    and "togglePlayPauseCommand" in watch_player
    and "playCommand" in watch_player
    and "pauseCommand" in watch_player,
    "The Watch player must register remote play/pause commands for the system Now Playing screen.",
)
require(
    "clearNowPlayingInfo" in watch_player
    and "MPNowPlayingInfoCenter.default().nowPlayingInfo = nil" in watch_player,
    "The Watch player must clear now-playing metadata when playback finishes or fails.",
)

reload_body = objc_method(watch_controller, "- (void)_reloadDataFromManager")
header_layout_body = objc_method(watch_controller, "- (void)_layoutHeaderForWidth:(CGFloat)width")
require(
    "_episodeHashesForStates:" in watch_controller
    and "episodeHashesChanged" in reload_body
    and "[self.tableView reloadData]" in reload_body
    and "if (episodeHashesChanged)" in reload_body,
    "The iPhone Watch list must not reload all rows for every Watch download progress update when the episode order is unchanged.",
)
status_body = objc_method(watch_controller, "- (NSString*)_statusTextForManager:(AppleWatchSyncManager*)manager")
require(
    "currentWatchDownloadTitle" not in status_body
    and "numberOfLines = 1" in watch_controller.split("UILabel* syncLabel", 1)[1].split("[header addSubview:syncLabel]", 1)[0],
    "The Watch list header status must be one stable line and must not jump between changing episode titles during parallel downloads.",
)
require(
    "sizeThatFits" not in header_layout_body
    and "ICAppleWatchHeaderLineHeight" in header_layout_body
    and "reservesStatus = showsStorage" in header_layout_body
    and "storageLabel.numberOfLines = 1" in watch_controller,
    "The iPhone Watch list header must use fixed text slots; download/storage text content must not change header height.",
)

detail_body = objc_method(scene_delegate, "- (NSString*)carPlayEpisodeDetailText:(CDEpisode*)episode")
item_body = objc_method(scene_delegate, "- (CPListItem*)carPlayListItemForEpisode:(CDEpisode*)episode")
require(
    "episode.feed.title" in detail_body
    and "[parts insertObject:podcastTitle atIndex:0]" in detail_body,
    "CarPlay episode detail text must start with the podcast name so episode lists are identifiable at a glance.",
)
require(
    "carPlayArtworkURLForEpisode" in scene_delegate
    and "localImageForImageURL:artworkURL" in item_body
    and "loadImageForURL:artworkURL" in item_body
    and "image:cachedImage" in item_body,
    "CarPlay episode rows must use episode/feed artwork instead of text-only list items.",
)
