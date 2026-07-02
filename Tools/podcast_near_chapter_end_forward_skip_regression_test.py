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
de_strings = read("Resources/de.lproj/Localizable.strings")
en_strings = read("Resources/en.lproj/Localizable.strings")


for key in ["PlayerNearChapterEndForwardSkipMode", "PlayerNearChapterEndForwardSkipWindow"]:
    require(f"extern NSString* {key};" in defines_h, f"{key} must be declared.")
    require(f'NSString* {key} = @"{key}";' in defines_m, f"{key} must be defined.")
    require(f"<key>{key}</key>" in defaults, f"{key} must have an explicit default.")

require(
    "<key>PlayerNearChapterEndForwardSkipMode</key>\n\t<integer>0</integer>" in defaults,
    "Near-chapter-end forward skip must default to Off.",
)
require(
    "<key>PlayerNearChapterEndForwardSkipWindow</key>\n\t<integer>60</integer>" in defaults,
    "Near-chapter-end forward skip window must default to 1 minute.",
)

require(
    "- (BOOL)_nearChapterEndForwardSkipEnabled" in feed_settings
    and "[self.feed integerForKey:PlayerNearChapterEndForwardSkipMode] > 0" in feed_settings
    and "return [self _nearChapterEndForwardSkipEnabled] ? 6 : 5;" in feed_settings,
    "Podcast settings must hide the chapter-end window row while the near-chapter-end skip is Off.",
)
require(
    "NSInteger playbackRow = indexPath.row;" in feed_settings
    and "if (![self _nearChapterEndForwardSkipEnabled] && playbackRow >= 3)" in feed_settings
    and "playbackRow++;" in feed_settings
    and "switch (playbackRow)" in feed_settings,
    "Podcast playback rows after the hidden window setting must keep mapping to Speed and Continuous Playback.",
)
require(
    "PlayerNearChapterEndForwardSkipMode" in feed_settings
    and "PlayerNearChapterEndForwardSkipWindow" in feed_settings
    and "@[ @(0), @(1), @(5), @(10), @(15), @(20) ]" in feed_settings
    and "@[ @(60), @(120), @(180), @(240), @(300) ]" in feed_settings,
    "Podcast settings must expose the requested mode and chapter-end window values.",
)
require(
    '"Nahe am Ende eines Kapitels zum nächsten Kapitel springen".ls' in feed_settings
    and '"Ende des Kapitels ab".ls' in feed_settings
    and '"When skipping forward near a chapter end, jump to the next chapter; + seconds skips sponsor tails after the boundary.".ls' in feed_settings,
    "Podcast settings must label and briefly explain the new behavior.",
)

for strings, language in [(de_strings, "German"), (en_strings, "English")]:
    for key in [
        "Nahe am Ende eines Kapitels zum nächsten Kapitel springen",
        "Ende des Kapitels ab",
        "Ein",
        "Ein + 5 Sekunden",
        "Ein + 10 Sekunden",
        "Ein + 15 Sekunden",
        "Ein + 20 Sekunden",
        "When skipping forward near a chapter end, jump to the next chapter; + seconds skips sponsor tails after the boundary.",
    ]:
        require(f'"{key}"' in strings, f"{language} localization is missing {key}.")

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
    and "for (NSString *originalKey in podcast.settings)" in importer
    and "[feed setInteger:intVal forKey:key]" in importer,
    "Podcast FeedProperty backup export/import must preserve integer settings like the near-chapter-end options.",
)
