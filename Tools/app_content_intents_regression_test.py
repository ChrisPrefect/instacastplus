#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


content = read("Classes/AppIntents/ICContentIntents.swift")
bridge = read("Classes/AppIntents/ICIntentBridge.swift")
shortcuts = read("Classes/AppIntents/ICAppShortcuts.swift")
project = read("Instacast.xcodeproj/project.pbxproj")

for token in [
    "struct ICPodcastEntity: AppEntity, Sendable",
    "struct ICEpisodeEntity: AppEntity, Sendable",
    "static let defaultQuery = ICPodcastEntityQuery()",
    "static let defaultQuery = ICEpisodeEntityQuery()",
    "struct ICPodcastEntityQuery: EntityStringQuery",
    "struct ICEpisodeEntityQuery: EntityStringQuery",
]:
    require(token in content, f"Content AppEntity layer missing: {token}")

for token in [
    "await ICIntentBridge.podcastInfos(forIDs: identifiers).map(ICPodcastEntity.init)",
    "await ICIntentBridge.matchingPodcasts(string).map(ICPodcastEntity.init)",
    "await ICIntentBridge.subscribedPodcasts().map(ICPodcastEntity.init)",
    "await ICIntentBridge.episodeInfos(forIDs: identifiers).map(ICEpisodeEntity.init)",
    "await ICIntentBridge.matchingEpisodes(string).map(ICEpisodeEntity.init)",
    "await ICIntentBridge.recentEpisodes().map(ICEpisodeEntity.init)",
]:
    require(token in content, f"Entity query is not bridged through sendable DTOs: {token}")

for token in [
    "struct ICPlayPodcastIntent: AudioPlaybackIntent",
    "struct ICPlayEpisodeIntent: AudioPlaybackIntent",
    "@Parameter(title: \"Podcast\")",
    "@Parameter(title: \"Episode\")",
    "await ICIntentBridge.playNewestEpisode(ofPodcastID: podcast.id)",
    "await ICIntentBridge.playEpisode(withID: episode.id)",
]:
    require(token in content, f"Parameterized playback intent missing: {token}")

require(
    'request.predicate = NSPredicate(format: "subscribed == YES")' in bridge,
    "Podcast entity suggestions must include parked podcasts by using only subscribed == YES.",
)
require("parked == NO" not in bridge, "App Intent podcast queries must not exclude parked podcasts.")

for token in [
    "intent: ICPlayPodcastIntent()",
    "intent: ICPlayEpisodeIntent()",
    "Play \\(\\.$podcast) in \\(.applicationName)",
    "Play \\(\\.$episode) in \\(.applicationName)",
]:
    require(token in shortcuts, f"App Shortcuts provider missing parameterized shortcut: {token}")

for token in [
    "ICContentIntents.swift",
    "ICContentIntents.swift in Sources",
]:
    require(token in project, f"Xcode project missing content intents build entry: {token}")

print("Podcast and episode App Intent regression checks passed.")
