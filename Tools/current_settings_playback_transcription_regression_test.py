#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


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


defines_h = read("Classes/Defines.h")
playback_settings = read("Classes/PlaybackSettingsViewController.m")
episodes_controller = read("Classes/EpisodesTableViewController.m")
episodes_cell_h = read("Classes/EpisodesTableViewCell.h")
episodes_cell_m = read("Classes/EpisodesTableViewCell.m")
transcription_queue = read("Classes/TranscriptionQueueViewController.m")
downloads_cell = read("Classes/DownloadsTableViewCell.m")
playback_controls = read("Classes/PlaybackControlsViewController.m")
fullscreen_video = read("Classes/PlayerFullscreenVideoViewController.m")
playback_view = read("Classes/PlaybackViewController.m")
metadata_h = read("Classes/Metadata/ICMetadata.h")
playback_manager = read("Classes/PlaybackManager.m")
chapter_generator = read("Classes/ChapterGenerator.swift")
feed_settings = read("Classes/FeedSettingsViewController.m")
list_episodes = read("Classes/ListEpisodesTableViewController.m")
bookmarks = read("Classes/BookmarksTableViewController.m")
subscription_manager = read("Classes/Model/SubscriptionManager.m")
de_strings = read("Resources/de.lproj/Localizable.strings")
en_strings = read("Resources/en.lproj/Localizable.strings")


require(
    "ICTapOnEpisodeActionOpenContextMenu = 2" in defines_h,
    "Tap on Episode needs a third enum value for opening the long-press menu.",
)
require(
    "ICTapOnEpisodeActionOpenContextMenu" in playback_settings
    and "Open Long-Press Menu" in playback_settings,
    "Playback settings must expose the third Tap on Episode choice.",
)
require(
    "primaryActionMenuButton" in episodes_cell_h
    and "showsMenuAsPrimaryAction = YES" in episodes_cell_m,
    "Episode cells need a primary-action menu button so a normal tap can open the native UIMenu.",
)
require(
    "cell.primaryActionMenuButton.menu = [self _contextMenuForIndexPath:indexPath]" in episodes_controller
    and "cell.primaryActionMenuButton.hidden = NO" in episodes_controller,
    "Episode rows must attach the existing long-press menu to the tap overlay when the setting is selected.",
)
context_menu_block = objc_method(episodes_controller, "- (UIMenu *) _contextMenuForIndexPath:(NSIndexPath *)indexPath")
require(
    "ICTapOnEpisodeActionOpenContextMenu" in context_menu_block
    and '"Play Episode"' in context_menu_block
    and '"Episode Info"' in context_menu_block,
    "The tap-menu mode must include both Play and Episode Info because tap itself no longer performs either.",
)


require(
    "cell.timeLabel.textAlignment = NSTextAlignmentCenter" in transcription_queue,
    "Transcription queue seconds label must be centered under the info button.",
)
require(
    "CGRectGetMaxX(bounds)-rightContentAccessoryWidth-5" in downloads_cell.replace(" ", ""),
    "Downloads cell must position the seconds label under the inset right accessory, not at the screen edge.",
)
require(
    "_estimatedRemainingTextForItem:" in transcription_queue
    and "Transkription läuft (%d%%, %@ verbleibend)" in transcription_queue
    and "Kapitel werden erstellt (%d%%, %@ verbleibend)" in transcription_queue,
    "Transcription rows must estimate remaining time and show it beside the percent.",
)
for strings in (de_strings, en_strings):
    require(
        "Open Long-Press Menu" in strings
        and "Transkription läuft (%d%%, %@ verbleibend)" in strings
        and "Kapitel werden erstellt (%d%%, %@ verbleibend)" in strings,
        "New playback and transcription status strings must be localized in German and English.",
    )


require(
    "playingEpisode.feed" in playback_controls
    and "integerForKey:key" in playback_controls
    and "_configuredSkipSecondsForKey:PlayerSkipBackPeriod" in playback_controls
    and "_configuredSkipSecondsForKey:PlayerSkipForwardPeriod" in playback_controls,
    "Main player skip buttons must read the current episode feed's configured skip periods.",
)
require(
    "playingEpisode.feed" in fullscreen_video
    and "integerForKey:key" in fullscreen_video
    and "_configuredSkipSecondsForKey:PlayerSkipBackPeriod" in fullscreen_video
    and "_configuredSkipSecondsForKey:PlayerSkipForwardPeriod" in fullscreen_video,
    "Fullscreen video skip buttons must read the current episode feed's configured skip periods.",
)
require(
    "gestureRecognizerShouldBegin:" in playback_view
    and "UIControl" in playback_view
    and "velocity.y <= fabs(velocity.x)" in playback_view,
    "Player navigation-bar dismissal pan must not begin from controls and must require a downward vertical pan.",
)


require(
    "_autoSkipSponsorsEnabledForFeed:" in playback_manager
    and '@"Sponsor: "' in playback_manager
    and "matchingSkipNameForChapter:" in playback_manager
    and "includeGeneratedSponsors" not in playback_manager
    and "ICGeneratedSponsorSkipName" not in playback_manager
    and "autoSkipsChapterTitle:" in playback_manager,
    "Sponsor auto-skip must add `Sponsor: ` to the ordinary chapter keyword list without a second player classification.",
)
require(
    "titleByRemovingSponsorPrefix" in chapter_generator
    and "normalizedStructuralChapterTitle(titleByRemovingSponsorPrefix(title))" in chapter_generator
    and "normalizedAudioInterludeTitle(titleByRemovingSponsorPrefix(candidateTitle))" in chapter_generator,
    "Chapter generation must reject/normalize Sponsor-prefixed structural music titles like Sponsor: Musik-Outro.",
)


enum_body = feed_settings.split("enum {", 1)[1].split("};", 1)[0]
sections = [line.strip().rstrip(",") for line in enum_body.splitlines() if line.strip().startswith("k")]
require(
    sections.index("kAutoDeleteSettingsSection") < sections.index("kNewsModeSection") < sections.index("kPlaybackSection"),
    "News Mode must appear below Auto-Delete Content in podcast settings.",
)
require(
    '#import "CDSmartPlaylist.h"' in list_episodes
    and "_allowsPullToRefresh" in list_episodes
    and "if ([self _allowsPullToRefresh])" in list_episodes
    and "if (![self _allowsPullToRefresh])" in list_episodes,
    "Smart lists must not install or trigger pull-to-refresh.",
)


number_of_rows = objc_method(bookmarks, "- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)sectionIndex")
cell_for_row = objc_method(bookmarks, "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath")
require(
    "return [self.sections count];" in number_of_rows
    and "BookmarksPlaceholderCellItem" not in cell_for_row,
    "Bookmarks must not represent the empty state as a scrollable placeholder row.",
)
require(
    "self.tableView.backgroundView" in bookmarks
    and "self.tableView.scrollEnabled = hasBookmarks" in bookmarks
    and "self.navigationItem.rightBarButtonItem = hasBookmarks ? self.editButtonItem : nil" in bookmarks
    and "setToolbarHidden:!hasBookmarks" in bookmarks,
    "Empty Bookmarks must show only a static label and hide edit/bottom buttons.",
)


require(
    "- (BOOL)_feedNeedsDurationMetadataRefresh:(CDFeed*)feed" in subscription_manager
    and "_feedObjectIDsNeedingDurationMetadataRefreshForFeeds:" not in subscription_manager
    and "_feedNeedsDurationMetadataRefreshForFeedObjectID:" not in subscription_manager
    and "preparingRefreshOperations" not in subscription_manager,
    "Refresh duration metadata checks must not add a Core Data preflight before parser operations are queued.",
)
require(
    "_autoDownloadEpisodesInFeedAsynchronously:" in subscription_manager
    and "_autoDownloadEpisode:nil sortedEpisodes:thisSortedEpisodes" in subscription_manager
    and "autoDownloadEpisodesInFeed:feed" not in objc_method(subscription_manager, "- (void) _finishParsingFeed:(CDFeed*)feed url:(NSURL*)url shouldAutoDownload:(BOOL)shouldAutoDownload"),
    "Subscribe/refresh auto-download selection must be scheduled off the UI path.",
)

print("Current settings/playback/transcription regression checks passed.")
