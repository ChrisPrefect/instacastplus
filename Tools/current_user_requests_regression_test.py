#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


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


transcription_settings = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
playback_settings = (ROOT / "Classes" / "PlaybackSettingsViewController.m").read_text()
notification_settings = (ROOT / "Classes" / "NotificationSettingsViewController.m").read_text()
watch_controller = (ROOT / "Classes" / "AppleWatchEpisodesViewController.m").read_text()
main_controller = (ROOT / "Classes" / "MainViewController_4.m").read_text()
image_functions_h = (ROOT / "Classes" / "ImageFunctions.h").read_text()
image_functions_m = (ROOT / "Classes" / "ImageFunctions.m").read_text()
playback_controls = (ROOT / "Classes" / "PlaybackControlsViewController.m").read_text()
fullscreen_video = (ROOT / "Classes" / "PlayerFullscreenVideoViewController.m").read_text()
watch_views = (ROOT / "InstacastWatch" / "WatchEpisodeViews.swift").read_text()
cache_header = (ROOT / "Classes" / "CacheManager.h").read_text()
cache_manager = (ROOT / "Classes" / "CacheManager.m").read_text()
playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
episodes_controller = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
episode_controller = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
de_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
en_strings = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


require(
    "TSSectionIntro" in transcription_settings
    and "Lege den Finger länger auf eine Episode" in transcription_settings
    and "Kontextmenü" in transcription_settings
    and "Downloads > Transkribieren" in transcription_settings
    and "Sprechblasen-Symbol" in transcription_settings
    and "Podcast eigene Kapitel" in transcription_settings,
    "Transcription settings must explain long-press start, monitoring, player transcript button, and existing podcast chapters.",
)
for strings in (de_strings, en_strings):
    require(
        "Lege den Finger länger auf eine Episode" in strings
        and "Downloads > Transkribieren" in strings,
        "Transcription how-to copy must be localized in German and English resources.",
    )


require(
    "ICSkipIntervalImage" in image_functions_h
    and "goforward" in image_functions_m
    and "gobackward" in image_functions_m,
    "Skip buttons need one shared circular-arrow image helper that draws the configured seconds.",
)
require(
    '"Player Backward"' not in playback_controls
    and '"Player Forward"' not in playback_controls
    and "ICSkipIntervalImage(NO" in playback_controls
    and "ICSkipIntervalImage(YES" in playback_controls,
    "Main player controls must use circular skip arrows with the configured seconds, not the old double-arrow assets.",
)
require(
    '"Player Backward"' not in fullscreen_video
    and '"Player Forward"' not in fullscreen_video
    and "ICSkipIntervalImage(NO" in fullscreen_video
    and "ICSkipIntervalImage(YES" in fullscreen_video,
    "Fullscreen video controls must use the same circular skip arrows with seconds.",
)
require(
    'Image(systemName: skipSymbolName)' in watch_views
    and "skipSymbolBaseName" in watch_views
    and "numberedSymbolSeconds" in watch_views
    and "drawsNumberOverlay" in watch_views,
    "Watch skip controls must use numbered circular-arrow symbols when SF Symbols has the configured interval.",
)


system_controls_block = objc_method(playback_settings, "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath")
require(
    "controller.footerTexts" in system_controls_block
    and "System Controls Seeking Explanation" in playback_settings
    and "System Controls Seeking Chapters Explanation" in playback_settings
    and "System Controls Skipping Explanation" in playback_settings,
    "Playback > System Controls must explain Seeking, Seeking and Skipping Chapters, and Skipping under the three choices.",
)
for strings in (de_strings, en_strings):
    require(
        "System Controls Seeking Explanation" in strings
        and "System Controls Seeking Chapters Explanation" in strings
        and "System Controls Skipping Explanation" in strings,
        "System Controls explanations must be localized.",
    )


require(
    "kFailureSection" in notification_settings
    and "kBadgeSection" in notification_settings
    and "kPushNotificationsSection" in notification_settings
    and "return @\"Push Notifications\".ls;" in notification_settings
    and 'return @"Types".ls;' not in notification_settings,
    "Notification settings must split refresh-failure and app badge into separate sections and rename Types to Push Notifications.",
)
for strings in (de_strings, en_strings):
    require('"Push Notifications"' in strings, "Push Notifications header must be localized.")


empty_cell_block = watch_controller.split("if (self.states.count == 0) {", 1)[1].split("AppleWatchEpisodeState* state = self.states[indexPath.row];", 1)[0]
watch_sidebar_block = main_controller.split("appleWatchItem.subtitle", 1)[1].split("};", 1)[0]
require(
    '"Watch-App öffnen"' in watch_controller
    and "_watchInstallButtonAction:" in watch_controller
    and "UITableViewCellAccessoryDisclosureIndicator" not in empty_cell_block,
    "Watch setup instructions must use a separate button instead of making the whole instruction row a link.",
)
require(
    '"Einrichten".ls' not in watch_sidebar_block,
    "The Apple Watch sidebar item must not show the setup subtitle.",
)


require(
    "beginStreamingCacheForEpisode" in cache_header
    and "updateStreamingCacheForEpisode" in cache_header
    and "finishStreamingCacheForEpisode" in cache_header
    and "streamingCacheProgressForEpisode" in cache_manager,
    "Auto-download while streaming must be tracked by CacheManager so Downloads and episode rows see progress.",
)
require(
    "beginStreamingCacheForEpisode:anEpisode" in playback_manager
    and "updateStreamingCacheForEpisode:playingEpisode" in playback_manager
    and "finishStreamingCacheForEpisode:innerSelf.episode" in playback_manager,
    "Playback stream caching must publish begin/progress/finish state to CacheManager.",
)


require(
    "loadCuesForChapterGeneration" in queue_source
    and "episode.transcripts" in queue_source
    and "No SRT for" not in queue_source,
    "Chapter generation must load cues from generated SRT or podcast transcript sources; it must not fail just because no SRT file exists.",
)
require(
    "hasChapterGenerationTranscript" in episodes_controller
    and "hasChapterGenerationTranscript" in episode_controller,
    "Episode menus must base the Kapitel generieren action on transcripts that the chapter queue can actually consume.",
)
