#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


doc = read("CLAUDE.md")
indexer = read("Classes/Model/ICSpotlightIndexer.m")
content_intents = read("Classes/AppIntents/ICContentIntents.swift")
indexer_header = read("Classes/Model/ICSpotlightIndexer.h")
database_h = read("Classes/Model/DatabaseManager.h")
database_m = read("Classes/Model/DatabaseManager.m")
scene = read("Classes/InstacastSceneDelegate.m")
project = read("Instacast.xcodeproj/project.pbxproj")

require("TODO iOS 27 Siri / Apple Intelligence" in doc, "Project docs must track iOS 27-only Siri work as TODO.")
for token in [
    "AppSchema.AudioEntity.podcastEpisode",
    "AppSchema.AudioIntent.playAudio",
    "IndexedEntity",
    "AppIntentsTesting",
]:
    require(token in doc, f"Project docs missing iOS 27 TODO token: {token}")

for token in [
    "#import <CoreSpotlight/CoreSpotlight.h>",
    "ICSpotlightPodcastPrefix = @\"podcast:\"",
    "ICSpotlightEpisodePrefix = @\"episode:\"",
    "indexSearchableItems:",
    "deleteSearchableItemsWithDomainIdentifiers:",
    "deleteSearchableItemsWithIdentifiers:",
    "textContent",
]:
    require(token in indexer, f"Spotlight indexer missing required Core Spotlight behavior: {token}")

for token in [
    "extension ICPodcastEntity: IndexedEntity, URLRepresentableEntity",
    "extension ICEpisodeEntity: IndexedEntity, URLRepresentableEntity",
    '"https://instacast.ch/share/podcast?url=\\(.id)"',
    '"https://instacast.ch/share/episode?url=\\(\\.$feedURL)&guid=\\(\\.$guid)"',
    '@Property(title: "Feed URL") var feedURL: String',
    '@Property(title: "Episode GUID") var guid: String',
    "struct ICOpenPodcastIntent: OpenIntent",
    "struct ICOpenEpisodeIntent: OpenIntent",
    "@Parameter(title: \"Podcast\") var target: ICPodcastEntity",
    "@Parameter(title: \"Episode\") var target: ICEpisodeEntity",
    "final class ICSpotlightAppEntityBridge: NSObject",
    "searchableItem.associateAppEntity",
]:
    require(token in content_intents, f"Spotlight App Entity bridge missing iOS 18 contract: {token}")

require(
    "instacastplus://" not in content_intents,
    "URLRepresentableEntity must use the production universal-link routes, never a custom URL scheme.",
)

require(
    content_intents.count("@available(iOS 18.0, *)") >= 5
    and "if (@available(iOS 18.0, *))" in indexer,
    "Indexed entities, open intents, and Objective-C association calls must remain gated from iOS 17.",
)
require(
    'identifier:snapshot[@"sourceURL"]' in indexer
    and 'identifier:snapshot[@"objectHash"]' in indexer
    and 'feedURL:snapshot[@"sourceURL"]' in indexer
    and 'guid:snapshot[@"guid"]' in indexer,
    "Spotlight association must preserve AppEntity IDs (podcast source URL and episode object hash).",
)
require(
    "feedUID" not in content_intents and "feedUID" not in indexer,
    "Podcast association must use its existing source-URL ID without adding another identifier property.",
)
require(
    "associatePodcastWithSearchableItem:" in indexer
    and "associateEpisodeWithSearchableItem:" in indexer,
    "Existing CSSearchableItems are not associated with their matching App Entities.",
)
require(
    "indexAppEntities" not in content_intents and "indexAppEntities" not in indexer,
    "App Entities must be associated with existing searchable items, not indexed in a duplicate pipeline.",
)

for token in [
    "ICSpotlightTranscriptTextForEpisodeHash",
    "srtURLFor:",
    "ICSpotlightGeneratedChapterTitlesForEpisodeHash",
    "chaptersJSONURLFor:",
    "[episode sortedChapters]",
    "episode.transcripts",
]:
    require(token in indexer, f"Spotlight indexer must include transcript/chapter source: {token}")

require("subscribed) {" in indexer, "Spotlight indexing must include all subscribed feeds, including parked feeds.")
require("parked == NO" not in indexer, "Spotlight indexer must not exclude parked podcasts.")
require("parked == NO" not in database_m, "Spotlight migration/update path must not exclude parked podcasts.")

for token in [
    "@class ICFeed, ICEpisode, ICMedia, ICFTSController, ICSpotlightIndexer",
    "ICSpotlightIndexer* spotlightIndexer",
]:
    require(token in database_h, f"DatabaseManager header missing Spotlight exposure: {token}")

for token in [
    "_spotlightIndexer = [[ICSpotlightIndexer alloc] init]",
    "[self _migrateSpotlight]",
    "kDefaultSpotlightMigrationDone",
    "feedRequest.predicate = [NSPredicate predicateWithFormat:@\"subscribed == YES\"]",
    'name:@"ICTranscriptionDidChangeNotification"',
    "transcriptionDidChangeNotification:",
    "[self.objectContext performBlock:",
    "[self.spotlightIndexer updateEpisode:episode]",
    "[self.spotlightIndexer addEpisode:episode]",
    "[self.spotlightIndexer removeFeed:(CDFeed*)deletedObject]",
]:
    require(token in database_m, f"DatabaseManager missing Spotlight hook: {token}")

for token in [
    "#import <CoreSpotlight/CoreSpotlight.h>",
    "CSSearchableItemActionType",
    "CSSearchableItemActivityIdentifier",
    "objectHashFromEpisodeUniqueIdentifier:",
    "sourceURLStringFromPodcastUniqueIdentifier:",
    "showShowNotesOfEpisode:episode",
    "episodesControllerWithFeed:feed",
]:
    require(token in scene, f"SceneDelegate missing Spotlight routing behavior: {token}")

for token in [
    "ICSpotlightIndexer.m in Sources",
    "ICSpotlightIndexer.h",
    "CoreSpotlight.framework in Frameworks",
]:
    require(token in project, f"Xcode project missing Spotlight build entry: {token}")

for token in [
    "+ (NSString*)podcastUniqueIdentifierForSourceURLString:",
    "+ (NSString*)episodeUniqueIdentifierForObjectHash:",
    "+ (NSString*)sourceURLStringFromPodcastUniqueIdentifier:",
    "+ (NSString*)objectHashFromEpisodeUniqueIdentifier:",
]:
    require(token in indexer_header, f"Spotlight identifier parser missing from public header: {token}")

print("Core Spotlight podcast/episode regression checks passed.")
