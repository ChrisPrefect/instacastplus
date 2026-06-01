#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def source_slice(source: str, start_marker: str, end_marker: str) -> str:
    start = source.find(start_marker)
    end = source.find(end_marker, start + len(start_marker)) if start != -1 else -1
    require(start != -1 and end != -1, f"Could not locate source slice {start_marker!r}.")
    return source[start:end]


engine = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
queue = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
settings = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
queue_ui = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
episode = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
episodes = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
options = (ROOT / "Classes" / "OptionsViewController.m").read_text()
image_functions = (ROOT / "Classes" / "ImageFunctions.m").read_text()
backend = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
playback = (ROOT / "Classes" / "PlaybackManager.m").read_text()
playback_h = (ROOT / "Classes" / "PlaybackManager.h").read_text()
scene_delegate = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
player = (ROOT / "Classes" / "PlayerController.m").read_text()
de_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
en_strings = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()


credential_store = source_slice(engine, "@objc class ICRemoteChapterCredentialStore", "private final class ICTextModelDownloadOperation")
require(
    "kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock," in credential_store
    and "kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly" not in credential_store,
    "AI credentials must use migratable Keychain accessibility so encrypted device backups can restore them on a new phone.",
)
require(
    "migrateStoredSecretsForDeviceBackupIfNeeded()" in credential_store
    and "SecItemUpdate(query as CFDictionary, attributes as CFDictionary)" in credential_store,
    "Existing AI credentials must be migrated in place to migratable Keychain accessibility, not only newly saved keys.",
)
require(
    "backupCredentialValues" in credential_store
    and "restoreBackupCredentialValues" in credential_store
    and "openAIAPIKey" in credential_store
    and "anthropicAPIKey" in credential_store
    and "kimiAPIKey" in credential_store,
    "AI credentials must remain included in InstacastPlus backup export/import.",
)

require(
    'NSLocalizedString(@"Transkribieren", nil)' in settings
    and 'NSLocalizedString(@"Kapitel generieren", nil)' in settings
    and 'NSLocalizedString(@"Voice to Text", nil)' not in settings
    and 'NSLocalizedString(@"Text zu Kapitel", nil)' not in settings,
    "Transcription settings model labels must be Transkribieren and Kapitel generieren, not Voice to Text/Text zu Kapitel.",
)
require(
    'NSLocalizedString("Transkribieren", comment: "")' in engine
    and 'NSLocalizedString("Kapitel generieren", comment: "")' in engine,
    "Downloadable model role titles must match the user-facing settings labels.",
)

how_to = "Lege den Finger länger auf eine Episode"
require(
    how_to in settings
    and "Kontextmenü" in settings
    and "Downloads > Transkribieren" in settings
    and "Sprechblasen-Symbol" in settings
    and "Podcast eigene Kapitel" in settings,
    "Transcription intro copy must explain long-press start, progress location, transcript button, and podcast-provided chapters.",
)
for strings in (de_strings, en_strings):
    require(
        how_to in strings
        and "Downloads > Transkribieren" in strings,
        "The revised transcription how-to copy must be localized in German and English resources.",
    )

require(
    'NSLocalizedString(@"Kapitel generieren", nil)' in episode
    and 'NSLocalizedString(@"Kapitel generieren", nil)' in episodes
    and 'NSLocalizedString(@"Chapters generieren", nil)' not in episode
    and 'NSLocalizedString(@"Chapters generieren", nil)' not in episodes,
    "Episode menus must use Kapitel generieren as the action label.",
)

options_footer = source_slice(
    options,
    "- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section",
    "- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section",
)
require(
    'CGRectMake(0, 0, tableView.frame.size.width, 119)' in options_footer
    and 'CGRectMake(20, 5, footerView.frame.size.width-40, 119)' in options_footer
    and '"Version %@ (%@)\\nPublisher: Chris Thomann \\nOriginally developed by Martin Hering \\nThank you Martin!"' in options_footer
    and "[NSBundle buildVersion]" in options_footer
    and "Developer:" not in options_footer
    and "Claude" not in options_footer
    and "Opus" not in options_footer
    and "Codex" not in options_footer
    and "Devendra" not in options_footer
    and "Tasia" not in options_footer
    and "Build " not in options_footer
    and "CFBundleVersion" not in options_footer,
    "Settings credits footer must keep the original credit text without the removed developer-line whitespace.",
)

require(
    "secondsText.length >= 3 ? sizeValue * 0.30f : sizeValue * 0.38f" in image_functions
    and "boundingRectWithSize" in image_functions
    and "ceilf((sizeValue - textSize.height) * 0.5f)" in image_functions,
    "Skip interval image must draw larger, visually centered seconds text.",
)

local_model_folder = source_slice(backend, "private nonisolated func localModelFolder", "    }\n\n    // MARK: - Compute Options")
require(
    "WhisperKitBackend.hasCompiledModelFiles(in: modelDir)" in local_model_folder
    and "contents.contains(where: { $0.hasSuffix(\".mlmodelc\") })" not in local_model_folder,
    "Whisper downloaded-state detection must recurse for compiled Core ML models instead of checking only top-level files.",
)

require(
    ">= 0.01" in engine
    and ">= 0.1" not in source_slice(engine, "nonisolated(unsafe) var lastCheckpointProg", "switch effectiveEngine"),
    "Transcription checkpoints must be saved often enough that a short background switch does not restart visible progress.",
)

background_pause = source_slice(queue, "private func finishBackgroundPause", "    // MARK: - Processing")
require(
    "item.error = nil" in background_pause
    and "item.progress = 0" not in background_pause
    and 'phase: "background"' in background_pause
    and 'phase: "error"' not in background_pause,
    "Background GPU pauses must be transient background pauses, not hidden failures that clear progress.",
)
require(
    'if ([phase isEqualToString:@"background"])' in queue_ui
    and "Transkription pausiert (%d%%)" in queue_ui
    and "cell.progressView.hidden = NO" in queue_ui,
    "Queue UI must show paused transcription progress instead of a hidden interrupted row.",
)

require(
    "useCachedFileIfAvailableAfterStreamingDownload" in playback_h
    and "useCachedFileIfAvailableAfterStreamingDownload" in playback
    and "autostart:wasPlaying" in playback
    and "useCachedFileIfAvailableAfterStreamingDownload" in scene_delegate,
    "Playback must switch to the saved file after stream-caching finishes and the app returns to the foreground.",
)

player_view_did_load = source_slice(player, "- (void)viewDidLoad", "- (void)viewWillTransitionToSize")
cached_tint_index = player_view_did_load.find("Apply cached tint color immediately")
first_update_controls_index = player_view_did_load.find("[self.controller updateControlsUI]")
require(
    cached_tint_index != -1
    and first_update_controls_index != -1
    and cached_tint_index < first_update_controls_index,
    "Player cached tint must be applied before controls update during initial loading.",
)
