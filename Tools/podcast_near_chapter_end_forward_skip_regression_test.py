#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


defines_h = read("Classes/Defines.h")
defines_m = read("Classes/Defines.m")
defaults = read("Resources/Defaults.plist")
feed_settings = read("Classes/FeedSettingsViewController.m")
playback_manager = read("Classes/PlaybackManager.m")
exporter = read("Classes/ImportExportSettingsViewController.m")
importer = read("Classes/InstacastBackupImporter.m")
parser = read("Classes/InstacastBackupParser.m")
icloud_sync = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])
project_notes = read("CLAUDE.md")
de_strings = read("Resources/de.lproj/Localizable.strings")
en_strings = read("Resources/en.lproj/Localizable.strings")

playback_cell_block = feed_settings.split("else if (indexPath.section == kPlaybackSection)", 1)[1].split("else if (indexPath.section == kAutoSkipSection)", 1)[0]
playback_case0 = playback_cell_block.split("case 0:", 1)[1].split("case 1:", 1)[0]
playback_case1 = playback_cell_block.split("case 1:", 1)[1].split("case 2:", 1)[0]
playback_case4 = playback_cell_block.split("case 4:", 1)[1].split("case 5:", 1)[0]

for key in ["PlayerNearChapterEndForwardSkipMode", "PlayerNearChapterEndForwardSkipWindow"]:
    require(f"extern NSString* {key};" in defines_h, f"{key} must be declared.")
    require(f'NSString* {key} = @"{key}";' in defines_m, f"{key} must be defined.")
    require(f"<key>{key}</key>" in defaults, f"{key} must have an explicit default.")

require(
    "<key>PlayerNearChapterEndForwardSkipMode</key>\n\t<integer>0</integer>" in defaults,
    "Near-chapter-end forward skip must default to Off.",
)
require(
    "<key>PlayerNearChapterEndForwardSkipWindow</key>\n\t<integer>180</integer>" in defaults,
    "Near-chapter-end forward skip window must default to 3 minutes.",
)

require(
    "- (BOOL)_nearChapterEndForwardSkipEnabled" in feed_settings
    and "[self.feed integerForKey:PlayerNearChapterEndForwardSkipMode] > 0" in feed_settings
    and "return [self _nearChapterEndForwardSkipEnabled] ? 6 : 5;" in feed_settings,
    "Podcast settings must hide the chapter-end window row while the near-chapter-end skip is Off.",
)
require(
    "switch (playbackRow)" in playback_cell_block
    and '"Continuous Playback".ls' in playback_case0
    and '"Speed".ls' in playback_case1,
    "Podcast playback settings must show Continuous Playback first and Speed second.",
)
require(
    "PlayerNearChapterEndForwardSkipMode" in feed_settings
    and "PlayerNearChapterEndForwardSkipWindow" in feed_settings
    and "@[ @(0), @(1), @(5), @(10), @(15), @(20) ]" in feed_settings
    and "@[ @(60), @(120), @(180), @(240), @(300) ]" in feed_settings,
    "Podcast settings must expose the requested mode and chapter-end window values.",
)
require(
    '"Sponsoren am Kapitelende überspringen".ls' in feed_settings
    and '"Sponsoren am Kapitelende überspringen:".ls' not in feed_settings
    and '"Ende des Kapitels ab".ls' in feed_settings
    and '"Sponsor-Segmente, die am Ende eines Kapitels eingefügt sind, können mit einem Druck auf Vorwärts-Spulen übersprungen werden. Es wird direkt zum nächsten Kapitel gesprungen und je nach Einstellung zusätzlich einige Sekunden weiter.".ls' in feed_settings,
    "Podcast settings must label and briefly explain the new behavior.",
)
require(
    "UITableViewCellStyleSubtitle" in playback_case4
    and "ChapterEndSponsorSkipCell" in playback_case4
    and "cell.detailTextLabel.text = localizedKey.ls;" in playback_case4,
    "The long sponsor-skip setting must show the selected value below the title instead of squeezing it into a trailing detail label.",
)

for strings, language in [(de_strings, "German"), (en_strings, "English")]:
    for key in [
        "Sponsoren am Kapitelende überspringen",
        "Ende des Kapitels ab",
        "Ein",
        "Ein + 5 Sekunden",
        "Ein + 10 Sekunden",
        "Ein + 15 Sekunden",
        "Ein + 20 Sekunden",
        "Sponsor-Segmente, die am Ende eines Kapitels eingefügt sind, können mit einem Druck auf Vorwärts-Spulen übersprungen werden. Es wird direkt zum nächsten Kapitel gesprungen und je nach Einstellung zusätzlich einige Sekunden weiter.",
    ]:
        require(f'"{key}"' in strings, f"{language} localization is missing {key}.")
    require('"Sponsoren am Kapitelende überspringen:"' not in strings, f"{language} localization must not keep the old colon title.")

seek_forward = playback_manager.split("- (void) seekForward", 1)[1].split("- (void) seekBackward", 1)[0]
require(
    "[self _forwardSkipTargetNearChapterEndFromTime:self.time]" in seek_forward
    and "[self seekToTime:[self _adjustTimeAfterSkipZone:chapterTarget]];" in seek_forward
    and "return;" in seek_forward,
    "seekForward must consult the near-chapter-end target before applying the normal skip period.",
)
near_end_helper = playback_manager.split("- (NSTimeInterval)_forwardSkipTargetNearChapterEndFromTime:(NSTimeInterval)time", 1)[1].split("- (void) seekBackward", 1)[0]
require(
    "[feed integerForKey:PlayerNearChapterEndForwardSkipMode]" in near_end_helper
    and "[feed integerForKey:PlayerNearChapterEndForwardSkipWindow]" in near_end_helper
    and "NSInteger extraSeconds = (mode == 1) ? 0 : mode;" in near_end_helper,
    "Near-chapter-end skip must read the podcast settings and map On to a 0-second offset.",
)
require(
    "ICMetadataChapter* nextChapter = self.chapters[i + 1];" in near_end_helper
    and "NSTimeInterval nextChapterStart = CMTimeGetSeconds(nextChapter.start);" in near_end_helper
    and "nextChapterStart - time <= windowSeconds" in near_end_helper
    and "NSTimeInterval target = nextChapterStart + extraSeconds;" in near_end_helper,
    "Near-chapter-end skip must jump to the next chapter plus the configured offset only inside the window.",
)

require(
    '<setting key=\\"%@\\" value=' in exporter
    and 'path isEqualToString:@"instacast/podcasts/podcast/settings/setting"' in parser
    and '_currentPodcast.settings[key] = value;' in parser
    and "for (NSString *originalKey in podcast.settings)" in importer
    and "[feed setInteger:intVal forKey:key]" in importer,
    "Podcast FeedProperty backup export/import must preserve integer settings like the near-chapter-end options.",
)

subscription_payload = icloud_sync.split("nonisolated static func subscriptionPayload(for feed:", 1)[1].split("return [", 1)[0]
subscription_apply = icloud_sync.split("if let properties = payload[\"properties\"] as? [[String: Any]]", 1)[1].split("if didMutate", 1)[0]
property_apply = icloud_sync.split("func applyFeedPropertyPayload", 1)[1].split("func queueSubscriptionRecord", 1)[0]
internal_keys = icloud_sync.split("nonisolated static let internalFeedPropertyKeys", 1)[1].split("]", 1)[0]
for key in ["PlayerNearChapterEndForwardSkipMode", "PlayerNearChapterEndForwardSkipWindow"]:
    require(key not in internal_keys, f"{key} must not be treated as an internal feed property.")
require(
    "for property in feed.properties as? Set<CDFeedProperty> ?? []" in subscription_payload
    and "!internalFeedPropertyKeys.contains(key)" in subscription_payload
    and '"key": stableFeedPropertyKey(key, feedUID: feedUID)' in subscription_payload
    and '"int32Value": Int(property.int32Value)' in subscription_payload,
    "iCloud subscription payload must include non-internal integer FeedProperties.",
)
require(
    "applyFeedPropertyPayload(property, to: feed)" in subscription_apply
    and "cdProperty.int32Value = int32Value" in property_apply,
    "iCloud subscription apply must restore integer FeedProperties.",
)
require(
    "PlayerNearChapterEndForwardSkipMode" in project_notes
    and "PlayerNearChapterEndForwardSkipWindow" in project_notes
    and "Backup-Export/Import" in project_notes
    and "Subscription-Sync" in project_notes,
    "Project notes must document that near-chapter-end podcast settings are durable and synced.",
)
