#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def source_between(source: str, start: str, end: str) -> str:
    if start not in source:
        return ""
    tail = source.split(start, 1)[1]
    if end not in tail:
        return tail
    return tail.split(end, 1)[0]


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        if start < 0:
            return ""

        line_end = source.find("\n", start)
        if line_end < 0:
            return ""
        if source[start:line_end].strip().endswith(";"):
            search_start = line_end + 1
            continue
        break

    candidates = []
    for marker in ("\n- (", "\n+ (", "\n    private func ", "\n    func ", "\n    @objc", "\n#pragma mark"):
        index = source.find(marker, start + len(signature))
        if index > start:
            candidates.append(index)

    end = min(candidates) if candidates else len(source)
    return source[start:end]


failures = []


def bug_present(condition: bool, message: str) -> None:
    if condition:
        failures.append(message)


fts = read("Classes/Model/ICFTSController.m")
database_manager = read("Classes/Model/DatabaseManager.m")
subscriptions = read("Classes/SubscriptionsTableViewController.m")
feed_episodes = read("Classes/FeedEpisodesTableViewController.m")
player_info = read("Classes/PlayerInfoViewController_v5.m")
image_cache = read("Classes/ImageCacheManager.m")
subscription_cell = read("Classes/SubscriptionTableViewCell.m")
episodes_controller = read("Classes/EpisodesTableViewController.m")
episode_cell = read("Classes/EpisodesTableViewCell.m")
cd_feed = read("Classes/Model/CDFeed.m")
cd_episode_list = read("Classes/Model/CDEpisodeList.m")
list_episodes_controller = read("Classes/ListEpisodesTableViewController.m")
widget_exporter = read("Classes/WidgetDataExporter.m")
apple_charts = read("Classes/ApplePodcastChartsClient.m")
directory_search = read("Classes/DirectorySearchViewController.m")
itunes_store = read("Classes/STITunesStore.m")
scene_delegate = read("Classes/InstacastSceneDelegate.m")
app_delegate = read("Classes/InstacastAppDelegate.m")
backup_importer = read("Classes/InstacastBackupImporter.m")
icloud_sync = read("Classes/ICiCloudSyncManager.swift")
transcription_queue = read("Classes/TranscriptionQueue.swift")
transcription_engine = read("Classes/TranscriptionEngine.swift")
audio_analyzer = read("Classes/AudioAnalyzer.swift")
chapter_generator = read("Classes/ChapterGenerator.swift")


add_episode = method_body(fts, "- (void) addEpisode:")
remove_episode = method_body(fts, "- (void) removeEpisode:")
remove_feed = method_body(fts, "- (void) removeFeed:")
index_feeds = method_body(fts, "- (void) indexFeeds:")
feed_search = method_body(fts, "- (NSSet*) feedUIDsForSearchTerm:")
episode_search = method_body(fts, "- (NSSet*) episodeUIDsForSearchTerm:")
index_feeds_db_block = source_between(index_feeds, "[self.queue inDatabase:", "\n    }];")
fts_update_observer = source_between(
    database_manager,
    "for(NSManagedObject* updatedObject in updatedObjects)",
    "for(NSManagedObject* deletedObject in deletedObjects)",
)

bug_present(
    "[self.queue inDatabase:" in add_episode and "episode." in add_episode,
    "FTS addEpisode reads CDEpisode properties inside the FMDB queue instead of snapshotting on the Core Data context queue.",
)
bug_present(
    "[self.queue inDatabase:" in index_feeds and "feed.episodes" in index_feeds_db_block,
    "FTS migration/indexFeeds reads CDFeed/CDEpisode relationships inside the FMDB queue.",
)
bug_present(
    "episode.guid" in add_episode and "episode.objectHash" in remove_episode,
    "FTS episode INSERT uses guid as uid, but DELETE uses objectHash; deleted episodes leave stale FTS rows.",
)
bug_present(
    "DELETE FROM feeds WHERE uid" in remove_feed and "DELETE FROM episodes" not in remove_feed,
    "FTS removeFeed deletes only the feed row and leaves all episode rows for that feed.",
)
bug_present(
    "[self.ftsController addEpisode:" in fts_update_observer and "removeEpisode" not in fts_update_observer and "updateEpisode" not in fts_update_observer,
    "FTS update handling inserts changed episodes/feeds again instead of updating or replacing existing rows.",
)
bug_present(
    "stringWithFormat:@\"title:%@*" in feed_search and "stringWithFormat:@\"title:%@*" in episode_search,
    "FTS search builds MATCH expressions directly from user input, so FTS syntax characters can break or change searches.",
)


subscription_search = method_body(subscriptions, "- (void) _searchTermDidChange")
feed_update_fetch = method_body(feed_episodes, "- (void) _updateFetchController")
bug_present(
    "feedUIDsForSearchTerm" in subscription_search and "dispatch_get_global_queue" not in subscription_search and "performFetch:nil" in subscription_search and "reloadData" in subscription_search,
    "Subscription search runs synchronous FTS, Core Data fetch, and table reload on the main search path.",
)
bug_present(
    "episodeUIDsForSearchTerm" in feed_update_fetch and "performFetch:nil" in feed_update_fetch,
    "Feed episode search runs synchronous FTS and Core Data fetch on the main search path.",
)


transcript_timer = method_body(player_info, "- (void)_updateTranscriptSyncTimerState")
transcript_active_index = method_body(player_info, "- (NSInteger)_activeTranscriptCueIndexForPlaybackTime:")
transcript_focus = method_body(player_info, "- (void)_focusTranscriptCueAtIndex:")
transcript_rebuild = method_body(player_info, "- (void)_rebuildTranscriptLines")
transcript_search = method_body(player_info, "- (void)_performTranscriptSearch:")
transcript_clear_search = method_body(player_info, "- (void)_clearTranscriptSearchHighlights")
bug_present(
    "scheduledTimerWithTimeInterval:0.2" in transcript_timer,
    "Transcript sync uses a 0.2s main-thread timer.",
)
bug_present(
    "for (NSInteger idx = 0;" in transcript_active_index,
    "Transcript sync linearly scans all cues on each timer tick.",
)
bug_present(
    "ensureLayoutForCharacterRange:NSMakeRange(0, layoutManager.textStorage.length)" in transcript_focus,
    "Transcript focus forces full UITextView layout on cue changes.",
)
bug_present(
    "ensureLayoutForCharacterRange:NSMakeRange(0, self.transcriptTextView.textStorage.length)" in transcript_rebuild,
    "Transcript rebuild eagerly lays out the full attributed transcript on main.",
)
bug_present(
    "rangeOfString:term" in transcript_search and "while (searchRange.location < fullText.length)" in transcript_search and "dispatch_get_global_queue" not in transcript_search,
    "Transcript search scans the full transcript on every text change.",
)
bug_present(
    "removeAttribute:NSBackgroundColorAttributeName range:NSMakeRange(0, textStorage.length)" in transcript_clear_search,
    "Transcript search clears highlighting over the entire text storage on every edit.",
)


local_image = method_body(image_cache, "- (IC_IMAGE*) localImageForImageURL:")
subscription_cell_setter = method_body(subscription_cell, "- (void) setObjectValue:")
player_reload = method_body(player_info, "- (void) reload\n")
set_chapters = method_body(player_info, "- (void) setChapters:")
episode_height = method_body(episodes_controller, "- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:")
proposed_height = method_body(episode_cell, "+ (CGFloat) proposedHeightWithObjectValue:(id)objectValue tableSize:(CGSize)tableSize imageSize:(CGSize)imageSize embedded:(BOOL)embedded editing:(BOOL)editing upNextStyle:(BOOL)upNextStyle")
bug_present(
    "initWithContentsOfFile" in local_image,
    "localImageForImageURL synchronously decodes disk images.",
)
bug_present(
    "localImageForImageURL" in subscription_cell_setter and "initWithContentsOfFile" in local_image,
    "Subscription cells call synchronous disk image decoding during cell configuration.",
)
bug_present(
    "boundingRectWithSize" in proposed_height and "heightCache" not in proposed_height and "proposedHeightWithObjectValue" in episode_height,
    "Episode row height calculation does uncached attributed-string measurement on the table height path.",
)
bug_present(
    "[self reloadData]" in player_reload and "[self.tableView reloadData]" in player_reload and "[self.tableView reloadData]" in set_chapters and "_suppressChapterReload" not in set_chapters,
    "Player reload can trigger table reloads both through setChapters and again in reload.",
)


episodes_count = method_body(cd_feed, "- (NSInteger) episodesCount")
unplayed_count = method_body(cd_feed, "- (NSInteger) unplayedCount")
last_played = method_body(cd_feed, "- (NSDate*) lastPlayed")
last_pub_date = method_body(cd_feed, "- (NSDate*) lastPubDate")
sort_menu = source_between(subscriptions, "UIAction* unplayedAction", "#pragma mark - Rename Feed")
bug_present(
    "countForFetchRequest" in episodes_count and "countForFetchRequest" in unplayed_count and "_updateUnplayedCount" in subscription_cell and "calculateCountsWithCompletion" not in subscription_cell,
    "Feed cells can trigger Core Data countForFetchRequest calls for visible rows.",
)
bug_present(
    ("sortFeedsByKey:@\"unplayedCount\"" in sort_menu or "a.lastPlayed" in sort_menu or "a.lastPubDate" in sort_menu) and "sortedArrayUsingDescriptors" in last_played and "sortedArrayUsingDescriptors" in last_pub_date,
    "Feed sorting invokes expensive computed Core Data properties for all feeds on main.",
)


filter_downloaded = method_body(feed_episodes, "-(void) downloadedUpdateEpisodes")
cdepisode_sorted = method_body(cd_episode_list, "- (NSArray*) _sortedEpisodesWithFetchLimit:")
list_update = method_body(list_episodes_controller, "- (void) updateEpisodes")
bug_present(
    "[CacheManager sharedCacheManager].cachedEpisodes" in filter_downloaded and "reloadData" in filter_downloaded,
    "Downloaded filter scans all cached episodes and reloads the table on main.",
)
bug_present(
    "episodeUIDsForSearchTerm" in cdepisode_sorted and "executeFetchRequest" in cdepisode_sorted and "executeFetchRequest" in cdepisode_sorted.split("fetchRequest2", 1)[-1] and "[self.list sortedEpisodes]" in list_update,
    "Episode lists can run FTS plus two Core Data fetches synchronously when updating visible lists.",
)


widget_start = method_body(widget_exporter, "- (void)startObserving")
widget_lists = method_body(widget_exporter, "- (void)exportListsSnapshot")
widget_export_list = method_body(widget_exporter, "- (void)_exportEpisodesForList:")
widget_stats = method_body(widget_exporter, "- (void)exportStatsSnapshot")
widget_action = method_body(widget_exporter, "- (void)_widgetControlAction:")
bug_present(
    "dispatch_async(dispatch_get_main_queue()" in widget_start and "exportListsSnapshot" in widget_start and "exportStatsSnapshot" in widget_start and "dispatch_async(self.listsExportQueue" not in widget_lists and "_readListeningLog" in widget_stats,
    "Widget exporter initial snapshot runs list/stats export on the main queue.",
)
bug_present(
    "sortedEpisodesWithLimit" in widget_export_list and "_writeJSON" in widget_export_list,
    "Widget list export synchronously sorts list episodes and writes JSON.",
)
bug_present(
    "_readListeningLog" in widget_stats and "numberOfCachedEpisodes" in widget_stats and "unplayedList.numberOfEpisodes" in widget_stats,
    "Widget stats export synchronously reads logs, cache counts, and unplayed list counts.",
)
bug_present(
    "dataWithContentsOfURL" in widget_action and "JSONObjectWithData" in widget_action and "dispatch_get_global_queue" not in widget_action,
    "Widget control action reads/parses the pending action file on the main queue.",
)


charts_fetch = method_body(apple_charts, "- (void)fetchTopPodcastsWithCountryCode:")
charts_cached = method_body(apple_charts, "- (NSArray *)cachedTopPodcastsForCountryCode:")
charts_load = method_body(apple_charts, "- (NSDictionary *)_loadDiskCacheForKey:")
directory_load_charts = method_body(directory_search, "- (void)_loadCharts")
itunes_async = method_body(itunes_store, "- (void) startStoreSearchForSearchString:")
itunes_sync = method_body(itunes_store, "- (NSArray*) storeSearchResultForSearchString:")
charts_fetch_main_block = source_between(charts_fetch, "dispatch_async(dispatch_get_main_queue()", "\n        });")
itunes_async_main_block = source_between(itunes_async, "dispatch_async(dispatch_get_main_queue()", "\n\t\t\t\t});")
bug_present(
    "dispatch_async(dispatch_get_main_queue()" in charts_fetch and "dispatch_get_global_queue" not in charts_fetch and ("_parseData" in charts_fetch_main_block or "_saveDiskCache" in charts_fetch_main_block),
    "Apple Podcast chart network completion parses JSON and writes cache on main.",
)
bug_present(
    "_loadDiskCacheForKey" in charts_cached and "dataWithContentsOfURL" in charts_load and "_parseData" in charts_load and "cachedTopPodcastsForCountryCode" in directory_load_charts and "dispatch_get_global_queue" not in directory_load_charts,
    "Apple Podcast chart cached load performs disk read and JSON parse on the caller thread.",
)
bug_present(
    "dispatch_async(dispatch_get_main_queue()" in itunes_async and "_searchResultsForData:data" in itunes_async_main_block,
    "iTunes search parses JSON after dispatching back to the main queue.",
)
bug_present(
    "dispatch_semaphore_wait" in itunes_sync and "storeSearchResultForSearchString" in directory_search,
    "iTunes store synchronous search can block callers for up to the URL timeout.",
)


backup_episode_import = source_between(backup_importer, "if (cat == ICBackupImportEpisodeStatus)", "} else {")
backup_guid_index = method_body(backup_importer, "+ (void)_buildGuidIndex")
backup_skip = source_between(backup_importer, "static BOOL _skipCurrentFeed", "+ (void)skipCurrentFeed")
bug_present(
    "runOnMain(^{\n                        feedCount = [self _importEpisodeStatusForPodcastAtIndex" in backup_episode_import,
    "Backup episode-status import runs each feed's large Core Data mutation on the main queue.",
)
bug_present(
    "for (CDFeed *feed in DMANAGER.feeds)" in backup_guid_index and "for (CDEpisode *ep in feed.episodes)" in backup_guid_index,
    "Backup GUID index construction loops all feeds and episodes on the main context.",
)
bug_present(
    "static BOOL _skipCurrentFeed = NO;" in backup_importer and "+ (void)skipCurrentFeed" in backup_importer and "while (!feedDone" in backup_importer,
    "Backup skip state is a shared static BOOL read by the import queue without synchronization.",
)
bug_present(
    "findEpisodeWithGuid" in backup_importer and "CDFeed *feed = [DMANAGER feedWithSourceURL:feedURL]" in method_body(backup_importer, "+ (NSInteger)_importEpisodeStatusForPodcastAtIndex:"),
    "Backup import has URL-resolution helpers but episode-status import still looks up feeds by the raw backup URL.",
)


icloud_queue_all = method_body(icloud_sync, "private func queueAllEpisodeStateRecords")
icloud_set_episode_date = method_body(icloud_sync, "private func setEpisodeLocalModifiedDate")
icloud_background = method_body(icloud_sync, "@objc func performBackgroundSyncWithCompletion")
bug_present(
    "@MainActor" in icloud_sync and "for feed in databaseManager.feeds" in icloud_queue_all and "for episode in feed.episodes" in icloud_queue_all,
    "iCloud sync queues all episode-state records by scanning every feed/episode on MainActor.",
)
bug_present(
    "var dates = episodeLocalModifiedDates()" in icloud_set_episode_date and "setSyncMetadata(dates" in icloud_set_episode_date,
    "iCloud sync rewrites the full episode local-modified-date dictionary per changed episode.",
)
bug_present(
    "Task { @MainActor in" in icloud_background and "fetchChanges()" in icloud_background,
    "iCloud background sync runs CKSyncEngine fetch work from a MainActor task.",
)


bug_present(
    "@MainActor" in transcription_queue and "private func persistQueue()" in transcription_queue and "data.write(to: queueFileURL" in transcription_queue,
    "TranscriptionQueue is MainActor-isolated but persists queue JSON synchronously.",
)
bug_present(
    "@MainActor" in transcription_engine and "try Data(contentsOf: url)" in transcription_engine and "checkpointCache[episodeHash]" not in transcription_engine,
    "TranscriptionEngine is MainActor-isolated and contains synchronous file reads.",
)
bug_present(
    "@MainActor" in audio_analyzer and "try Data(contentsOf: url)" in audio_analyzer and "Task.detached" not in method_body(audio_analyzer, "private func loadCachedTimeline"),
    "AudioAnalyzer is MainActor-isolated and reads cached timelines synchronously.",
)
bug_present(
    "@MainActor" in chapter_generator and "try Data(contentsOf: url)" in chapter_generator and "_loadedChaptersCache[episodeHash]" not in chapter_generator,
    "ChapterGenerator is MainActor-isolated and reads generated chapter JSON synchronously.",
)


if failures:
    print(f"Confirmed {len(failures)} reproducible bug proofs:")
    for index, failure in enumerate(failures, 1):
        print(f"{index}. {failure}")
    raise SystemExit(1)

print("No source-level UI-stutter bug proofs found.")
