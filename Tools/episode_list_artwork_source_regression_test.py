#!/usr/bin/env python3
"""Pin the per-list episode-artwork versus podcast-artwork setting contract."""

from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"
MODEL9 = MODEL_DIR / "Model9.xcdatamodel" / "contents"


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(MODEL9.exists(), "A shipped Model8 requires an additive Model9 for the durable list setting.")
current_version = plistlib.loads((MODEL_DIR / ".xccurrentversion").read_bytes())
require(
    current_version.get("_XCCurrentVersionName") == "Model9.xcdatamodel",
    "Model9 must be the selected Core Data model.",
)
project = read("Instacast.xcodeproj/project.pbxproj")
require(
    "Model9.xcdatamodel" in project
    and "/* Model9.xcdatamodel */" in project
    and "currentVersion" in project,
    "The Xcode model version group must include and select Model9.",
)

model_root = ET.parse(MODEL9).getroot()
episode_list_entity = next(
    entity for entity in model_root.findall("entity") if entity.get("name") == "EpisodeList"
)
artwork_attribute = next(
    (attribute for attribute in episode_list_entity.findall("attribute")
     if attribute.get("name") == "usePodcastArtwork"),
    None,
)
require(
    artwork_attribute is not None
    and artwork_attribute.get("attributeType") == "Boolean"
    and artwork_attribute.get("defaultValueString") == "NO",
    "EpisodeList.usePodcastArtwork must be an additive Boolean defaulting to the existing episode-artwork behavior.",
)

model_header = read("Classes/Model/CDEpisodeList.h")
model_implementation = read("Classes/Model/CDEpisodeList.m")
require(
    "@property (nonatomic) BOOL usePodcastArtwork;" in model_header
    and "@dynamic usePodcastArtwork;" in model_implementation,
    "CDEpisodeList must expose the persisted artwork choice.",
)

editor = read("Classes/EpisodeListEditorViewController.m")
require(
    "@property (nonatomic) BOOL usePodcastArtwork;" in editor
    and "self.usePodcastArtwork = list.usePodcastArtwork;" in editor
    and "self.usePodcastArtwork = NO;" in editor
    and "list.usePodcastArtwork = self.usePodcastArtwork;" in editor,
    "The list editor must load, default, and save the artwork choice.",
)
require(
    '#import "SettingsValuesTableViewController.h"' in editor
    and 'cell.textLabel.text = @"Artwork".ls;' in editor
    and 'cell.detailTextLabel.text = self.usePodcastArtwork ? @"Podcast Artwork".ls : @"Episode Artwork".ls;' in editor
    and "SettingsValuesTableViewController* controller = [SettingsValuesTableViewController tableViewController];" in editor
    and "controller.selectedValue = @(self.usePodcastArtwork);" in editor
    and "controller.values = @[ @NO, @YES ];" in editor
    and 'controller.titles = @[ @"Episode Artwork".ls, @"Podcast Artwork".ls ];' in editor
    and "self.usePodcastArtwork = [value boolValue];" in editor,
    "Appearance must be a one-line detail setting that opens the standard checked-value submenu.",
)

episodes_controller = read("Classes/EpisodesTableViewController.m")
list_controller = read("Classes/ListEpisodesTableViewController.m")
require(
    "[self artworkURLForEpisode:episode]" in episodes_controller
    and "- (NSURL*) artworkURLForEpisode:(CDEpisode*)episode" in episodes_controller,
    "All episode-list artwork loads must use one overridable resolver.",
)
require(
    "episodeList.usePodcastArtwork" in list_controller
    and "return episode.feed.imageURL;" in list_controller,
    "A configured smart list must resolve podcast artwork instead of episode artwork.",
)

german = read("Resources/de.lproj/Localizable.strings")
english = read("Resources/en.lproj/Localizable.strings")
for source, language in ((german, "German"), (english, "English")):
    require('"Artwork"' in source, f"{language} Artwork localization is missing.")
    require('"Episode Artwork"' in source, f"{language} Episode Artwork localization is missing.")
    require('"Podcast Artwork"' in source, f"{language} Podcast Artwork localization is missing.")

backup_data = read("Classes/InstacastBackupData.h")
backup_export = read("Classes/ImportExportSettingsViewController.m")
backup_parser = read("Classes/InstacastBackupParser.m")
backup_import = read("Classes/InstacastBackupImporter.m")
require(
    "@property (nonatomic) BOOL usePodcastArtwork;" in backup_data
    and "<usePodcastArtwork>" in backup_export
    and 'isEqualToString:@"usePodcastArtwork"' in backup_parser
    and "usePodcastArtwork = backupList.usePodcastArtwork;" in backup_import,
    "Backup export, parse, and import must preserve the list artwork choice symmetrically.",
)

sync_engine = read("Classes/ICiCloudSyncManager+EngineRecords.swift")
sync_changes = read("Classes/ICiCloudSyncManager+LocalChanges.swift")
sync_apply = read("Classes/ICiCloudSyncManager+RemoteApply.swift")
require(
    '"usePodcastArtwork": list.usePodcastArtwork' in sync_engine
    and '"usePodcastArtwork"' in sync_changes
    and 'payload["usePodcastArtwork"]' in sync_apply
    and "list.usePodcastArtwork = usePodcastArtwork" in sync_apply,
    "iCloud list settings must publish, observe, fingerprint, and apply the artwork choice.",
)

print("Episode-list artwork-source regression checks passed")
