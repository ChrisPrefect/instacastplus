#!/usr/bin/env python3
"""Regression contract for the shared server transcription client."""

from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


manager = read("Classes/ServerTranscriptionManager.swift")
queue = read("Classes/TranscriptionQueue.swift")
settings = read("Classes/TranscriptionSettingsViewController.m")
episode_list = read("Classes/EpisodesTableViewController.m")
episode_detail = read("Classes/EpisodeViewController.m")
engine = read("Classes/TranscriptionEngine.swift")
chapters = read("Classes/ChapterGenerator.swift")
queue_ui = read("Classes/TranscriptionQueueViewController.m")
defines_h = read("Classes/Defines.h")
defines_m = read("Classes/Defines.m")
backup_export = read("Classes/ImportExportSettingsViewController.m")
backup_import = read("Classes/InstacastBackupImporter.m")
project = read("Instacast.xcodeproj/project.pbxproj")

require(
    'https://transcript.instacast.ch/api/v1/' in manager
    and 'Authorization' in manager
    and 'X-Instacast-Client-ID' in manager
    and 'X-Instacast-App-Version' in manager
    and 'X-Instacast-Platform' in manager,
    "The server client does not send the documented authenticated API headers.",
)
require(
    'callback_url' not in manager and 'Webhook' not in manager,
    "The iOS client must poll the API and must not register a webhook callback.",
)
for kind in ('"transcript_srt"', '"chapters_json"', '"ads_json"', '"summary_json"'):
    require(kind in manager, f"Ready server results do not require {kind}.")
require(
    'SHA256.hash(data: data)' in manager
    and 'importServerSRTData' in manager
    and 'saveServerAnalysis' in manager,
    "Server artifacts are not integrity-checked and atomically imported through the local formats.",
)
require(
    'publisherChapters(for: episode, fallback: chapters)' in manager
    and 'ads.map' in manager
    and 'saveServerAnalysis' in manager,
    "Server sponsors are not overlaid onto existing client chapters.",
)
require(
    'Sponsor: \\(segment.title)' in chapters
    and 'Array(cueIDs[first...last])' in chapters,
    "Server sponsor ranges are not rebased to complete local transcript cues.",
)
require(
    'parsePersistedSRT(content)' in engine
    and 'importServerSRTData' in engine
    and 'saveImportedTranscriptCues(cues' in engine,
    "Server SRT data is not validated before it replaces the persisted transcript.",
)
require(
    'kServerTranscriptionEnabled' in defines_h
    and 'kAutomaticTranscriptionBackend' in defines_h
    and 'ServerTranscriptionEnabled' in defines_m
    and 'AutomaticTranscriptionBackend' in defines_m,
    "Server and automatic-backend settings have no shared defaults keys.",
)
for relative in ('Resources/Defaults.plist', 'Resources-iPad/Defaults.plist'):
    with (ROOT / relative).open('rb') as handle:
        defaults = plistlib.load(handle)
    require(defaults.get('ServerTranscriptionEnabled') is False, f'{relative} must default server transcription to off.')
    require(defaults.get('AutomaticTranscriptionBackend') == 'local', f'{relative} must default automatic work to local.')
require(
    # The automatic-backend row only exists while both backends are enabled; the
    # choice itself is a pushed submenu, never an action sheet.
    '_showsAutomaticBackendRow' in settings
    and '_pushAutomaticBackendChooser' in settings
    and 'UIAlertControllerStyleActionSheet' not in settings
    and 'kAutomaticTranscriptionBackend' in settings
    and 'kServerTranscriptionEnabled' in settings,
    "The transcription settings hub does not offer a single global automatic backend choice.",
)
require(
    'resolvedAutomaticBackend' in queue,
    "A stale automatic-backend preference must not disable automatic work when only one backend is enabled.",
)
require(
    'ServerTranscriptionManager.shared.enqueueAutomaticEpisodes([episode])' in queue
    and 'automaticBackend == "server"' in queue,
    "Automatic work is not routed exclusively to the selected server backend.",
)
require(
    'serverAutomaticItems' in queue
    and 'requiresNetworkConnectivity' in queue
    and 'scheduleAutomaticBackgroundProcessingIfNeeded()' in manager,
    "Automatic server jobs are not included in the durable BGProcessing wake-up path.",
)
require(
    'Server transkribieren' in episode_list
    and 'Lokal transkribieren' in episode_list
    and 'Server transkribieren' in episode_detail
    and 'Lokal transkribieren' in episode_detail,
    "Manual episode menus do not expose separate local and server actions.",
)
require(
    'displayItems' in queue
    and 'displayItems' in queue_ui
    and 'usesServerTranscription' in queue_ui,
    "Server jobs are not shown, retried, and removed through the transcription list.",
)
require(
    'serverTranscriptionEnabled' in backup_export
    and 'automaticTranscriptionBackend' in backup_export
    and 'serverTranscriptionEnabled' in backup_import
    and 'automaticTranscriptionBackend' in backup_import,
    "Server settings are not backed up and restored symmetrically.",
)
require(
    'ServerTranscriptionManager.swift' in project,
    "ServerTranscriptionManager.swift is not a member of the app target.",
)

print("Server transcription API regression checks passed.")
