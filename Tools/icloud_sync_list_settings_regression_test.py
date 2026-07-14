#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
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
    raise AssertionError(f"Unterminated method body: {signature}")


def source_between(source: str, start: str, end: str) -> str:
    require(start in source, f"{start} is missing.")
    require(end in source, f"{end} is missing.")
    return source.split(start, 1)[1].split(end, 1)[0]


manager = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])
editor = read("Classes/EpisodeListEditorViewController.m")
exporter = read("Classes/ImportExportSettingsViewController.m")
importer = read("Classes/InstacastBackupImporter.m")

editor_save = method_body(editor, "- (void) save")
for expected in [
    "list.name = self.name",
    "list.includedFeeds = [NSSet setWithArray:[self.selectedPodcasts array]]",
    '[USER_DEFAULTS setObject:mainMenuUIDs forKey:@"MainMenuListUIDs"]',
]:
    require(expected in editor_save, f"Episode list editor must still persist {expected}.")

require(
    "<episodeLists>" in exporter and "<includedFeeds>" in exporter and "<mainMenuListUIDs>" in exporter,
    "Backup export proves list filters and main-menu visibility are durable user data.",
)
require(
    "importEpisodeListsFromBackup" in importer and "existingList.includedFeeds = feeds" in importer,
    "Backup import must keep the same list-filter contract the iCloud payload now syncs.",
)

record_builder = method_body(manager, "nonisolated static func subscriptionListSettingsRecordForSyncEngineCallback")
for field in ['"episodeLists"', '"mainMenuListUIDs"']:
    require(field in record_builder, f"ICSubscriptionListSettings must upload {field}.")
require(
    "episodeListPayloadsForSyncEngineCallback()" in record_builder,
    "Subscription list settings must materialize CDEpisodeList payloads off the main thread.",
)

payload_builder = method_body(manager, "nonisolated static func episodeListPayloadsForSyncEngineCallback")
require("newBackgroundContext()" in payload_builder, "Episode-list payload building must not fetch lists on the main context.")
require('entityName: "EpisodeList"' in payload_builder, "Episode-list payload building must fetch CDEpisodeList rows.")
require('relationshipKeyPathsForPrefetching = ["includedFeeds"]' in payload_builder, "Included feeds must be prefetched in one list-settings fetch.")

single_payload = method_body(manager, "nonisolated static func episodeListPayloadForSyncEngineCallback")
for field in [
    '"uid"',
    '"name"',
    '"icon"',
    '"rank"',
    '"query"',
    '"audio"',
    '"video"',
    '"downloaded"',
    '"downloading"',
    '"notDownloaded"',
    '"unplayed"',
    '"unfinished"',
    '"played"',
    '"starred"',
    '"notStarred"',
    '"orderBy"',
    '"descending"',
    '"groupByPodcast"',
    '"continuousPlayback"',
    '"includedFeedURLs"',
]:
    require(field in single_payload, f"Episode-list payload is missing {field}.")
require("sourceURL_" in single_payload, "Included podcasts must sync by stable feed source URL, not local object IDs.")

fingerprint = method_body(manager, "nonisolated static func subscriptionListSettingsFingerprint")
require("episodeListPayloadsForSyncEngineCallback()" in fingerprint, "Episode-list metadata must affect the list-settings fingerprint.")
require("mainMenuListUIDsForSyncEngineCallback()" in fingerprint, "Main-menu list visibility must affect the list-settings fingerprint.")

has_local = method_body(manager, "nonisolated static func hasLocalSubscriptionListSettings")
require("hasLocalEpisodeListSettings()" in has_local, "A customized episode-list state must be publishable even without manual feed order.")
require("hasLocalMainMenuListSettings()" in has_local, "Main-menu visibility must be publishable as subscription list settings.")

apply_remote = method_body(manager, "func applyRemoteSubscriptionListSettings")
for call in ["applyRemoteEpisodeLists", "applyRemoteMainMenuListUIDs"]:
    require(call in apply_remote, f"Remote subscription-list settings must call {call}.")
require(
    "hasRemoteEpisodeLists" in apply_remote and "hasRemoteMainMenuListUIDs" in apply_remote,
    "Empty-record and LWW guards must consider list filters and main-menu visibility, not only sort order.",
)

apply_lists = method_body(manager, "func applyRemoteEpisodeLists")
require('entityName: "EpisodeList"' in apply_lists, "Applying list settings must fetch existing CDEpisodeList objects by uid.")
require("applyRemoteEpisodeListPayload" in apply_lists, "Applying list settings must delegate each payload to a narrow updater.")

apply_single = method_body(manager, "func applyRemoteEpisodeListPayload")
for assignment in [
    "list.name = name",
    "list.icon = icon",
    "list.rank = rank",
    "list.query = query",
    "list.audio = audio",
    "list.video = video",
    "list.downloaded = downloaded",
    "list.downloading = downloading",
    "list.notDownloaded = notDownloaded",
    "list.unplayed = unplayed",
    "list.unfinished = unfinished",
    "list.played = played",
    "list.starred = starred",
    "list.notStarred = notStarred",
    "list.orderBy = orderBy",
    "list.descending = descending",
    "list.groupByPodcast = groupByPodcast",
    "list.continuousPlayback = continuousPlayback",
    "list.includedFeeds = includedFeeds",
]:
    require(assignment in apply_single, f"Applying remote episode lists must update {assignment}.")
require("remoteAppliedObjectIDs.insert(list.objectID)" in apply_single, "Remote list mutations must be echo-suppressed.")
require("list.invalidateCaches()" in apply_single, "Changing synced list filters must invalidate list caches.")

apply_menu = method_body(manager, "func applyRemoteMainMenuListUIDs")
require('defaults.set(mainMenuListUIDs, forKey: "MainMenuListUIDs")' in apply_menu, "Remote main-menu visibility must update MainMenuListUIDs.")
require("MainMenuListUIDsDidChangeNotification" in apply_menu, "Applying main-menu visibility must refresh sidebar/menu UI.")

insert_filter = method_body(manager, "nonisolated static func syncRelevantInsertedObjectIDs")
update_filter = method_body(manager, "nonisolated static func syncRelevantUpdatedObjectIDs")
require('case "EpisodeList":' in insert_filter, "New local episode lists must queue subscription list settings.")
require('case "EpisodeList":' in update_filter, "Edited local episode lists must queue subscription list settings.")
require("syncRelevantEpisodeListKeys" in update_filter, "Episode-list queueing must be limited to payload fields.")

process_objects = method_body(manager, "func journalLocalOutboxObjects")
require(
    "(inserted + updated).contains" in process_objects,
    "Core Data list changes must be carried through the local-change journal.",
)
require("subscriptionListSettingsRecordID()" in process_objects, "List changes must queue the ICSubscriptionListSettings singleton.")

transient_keys = method_body(manager, "nonisolated static func transientSettingsKeysForSyncEngineCallback")
require('"MainMenuListUIDs"' in transient_keys, "MainMenuListUIDs must not be duplicated in scalar app-settings sync.")

print("iCloud list settings regression checks passed.")
