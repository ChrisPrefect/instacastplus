from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def read(path: str) -> str:
    return (ROOT / path).read_text()


project = read("Instacast.xcodeproj/project.pbxproj")
manager = read("Classes/AppleWatchSyncManager.m")
defaults = read("Resources/Defaults.plist")
database_manager = read("Classes/Model/DatabaseManager.m")
model = ElementTree.parse(ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model.xcdatamodel" / "contents").getroot()
watch_download_manager = read("InstacastWatch/WatchDownloadManager.swift")
watch_connectivity = read("InstacastWatch/WatchConnectivityController.swift")
watch_player = read("InstacastWatch/WatchPlayerController.swift")
watch_views = read("InstacastWatch/WatchEpisodeViews.swift")
watch_chapter_extractor = read("InstacastWatch/WatchChapterExtractor.swift")
watch_plist = read("InstacastWatch/Info.plist")
watch_complication_path = ROOT / "InstacastWatchWidgets" / "WatchComplicationWidget.swift"
watch_complication = watch_complication_path.read_text() if watch_complication_path.exists() else ""
feed_settings = read("Classes/FeedSettingsViewController.m")
episodes_table = read("Classes/EpisodesTableViewController.m")
episode_view = read("Classes/EpisodeViewController.m")
main_view = read("Classes/MainViewController_4.m")
cell = read("Classes/EpisodesTableViewCell.m")
apple_watch_controller = read("Classes/AppleWatchEpisodesViewController.m")
donation_view = read("Classes/DonationViewController.m")


watch_entity = model.find("./entity[@name='AppleWatchEpisodeState']")
require(watch_entity is not None, "Model5 must define AppleWatchEpisodeState.")
watch_attributes = {attribute.attrib["name"] for attribute in watch_entity.findall("attribute")}
require(
    {
        "episodeHash",
        "feedIdentifier",
        "selectionSource",
        "watchStatus",
        "watchAddedDate",
        "watchDownloadedDate",
        "watchLastSeenDate",
        "watchLastError",
        "watchActualDuration",
        "watchActualFileSize",
        "lastPhonePosition",
        "lastPhonePositionDate",
        "lastWatchPosition",
        "lastWatchPositionDate",
        "watchConsumed",
        "watchConsumedDate",
    }.issubset(watch_attributes),
    "AppleWatchEpisodeState is missing required sync/status attributes.",
)

require("#define MODEL_VERSION 5" in database_manager, "The active Core Data model version must be Model5.")
require("AppleWatchEpisodeState.m in Sources" in project and "Model5.xcdatamodeld in Sources" in project, "The app target must compile the new Watch state model.")
require("Model/AppleWatchEpisodeState" not in project, "AppleWatchEpisodeState must be referenced relative to the existing Model group, not Classes/Model/Model.")

require(
    "InstacastWatch" in project
    and "productType = \"com.apple.product-type.application\";" in project
    and "WATCHOS_DEPLOYMENT_TARGET = 9.0;" in project
    and 'dstPath = "$(CONTENTS_FOLDER_PATH)/Watch";' in project
    and "InstacastWatch.app in Embed Watch Content" in project
    and "WatchConnectivity.framework in Frameworks" in project,
    "The Xcode project must contain and embed the executable watchOS app target inside the iOS app's Watch folder with WatchConnectivity.",
)

require(
    "WatchChapterExtractor.swift in Sources" in project,
    "The Watch target must compile the local media chapter extractor.",
)

require(
    "<key>WKApplication</key>" in watch_plist
    and "<key>WKWatchKitApp</key>" not in watch_plist,
    "The executable Watch app Info.plist must use WKApplication without the legacy WKWatchKitApp key.",
)

require(
    "<key>CFBundleDisplayName</key>" in watch_plist
    and "<string>InstacastPlus</string>" in watch_plist,
    "The Watch app display name must match the iOS app name shown to users.",
)

require(
    "<key>UIBackgroundModes</key>" in watch_plist
    and "<string>audio</string>" in watch_plist,
    "The Watch app must declare audio background mode so local episode playback continues after wrist down/app backgrounding.",
)

require(
    "policy: .longFormAudio" in watch_player
    and "mode: .default" in watch_player
    and "activate(options: [])" in watch_player
    and "setActive(true)" not in watch_player,
    "The Watch player must activate a long-form audio route before starting playback; a foreground-style audio session stops shortly after backgrounding on watchOS.",
)

require(
    'Text("InstacastPlus")' in watch_views
    and "foregroundStyle(accentColor)" in watch_views,
    "The Watch UI title must match the shipped app display name and use the synced accent color.",
)

require(
    "font(.system(size: 30" not in watch_views
    and "return episode.podcastTitle" in watch_views
    and "return subtitle" not in watch_views.split("private var secondaryText", 1)[1].split("private var progressFraction", 1)[0],
    "The Watch episode list must use a compact app title and must not spend row space on episode descriptions.",
)

require(
    "WatchArtworkLoader" in watch_views
    and "URLSession.shared.data(from: url)" in watch_views
    and "cachesDirectory" in watch_views,
    "The Watch list artwork must be cached locally instead of relying on transient AsyncImage fetches.",
)

require(
    ".toolbar" not in watch_views,
    "The Watch episode list must not render the refresh action as a large toolbar button over the empty state.",
)

require(
    "InstacastWatch/Assets.xcassets/AppIcon.appiconset/Contents.json" in {
        str(path.relative_to(ROOT)) for path in (ROOT / "InstacastWatch" / "Assets.xcassets").rglob("*")
    }
    and "Assets.xcassets in Resources" in project
    and "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" in project,
    "The Watch target must bundle a real AppIcon asset catalog so the iOS Watch app can list it with an icon.",
)

require(
    watch_complication_path.exists()
    and "struct WatchComplicationWidget" in watch_complication
    and ".supportedFamilies([.accessoryCircular" in watch_complication
    and ".accessoryInline" in watch_complication
    and ".accessoryCorner" in watch_complication
    and ".accessoryRectangular" in watch_complication
    and "InstacastWatchWidgets.appex" in project
    and "SDKROOT = watchos;" in project.split("InstacastWatchWidgets", 1)[1],
    "The app must ship a watchOS WidgetKit complication target so InstacastPlus appears in the Watch face complication picker.",
)

require(
    "<key>AppleWatchSendLatestCount</key>" in defaults
    and "<key>AppleWatchOnlyUnplayed</key>" in defaults
    and "<true/>" in defaults,
    "Defaults must define the per-feed Apple Watch latest-count and unplayed-only settings.",
)

require(
    "episode.video" in manager
    and "episode.archived" in manager
    and "episode.preferedMedium.fileURL" in manager
    and "AppleWatchSendLatestCount" in manager
    and "AppleWatchOnlyUnplayed" in manager
    and "ICAppleWatchSelectionSourceManual" in manager
    and "ICAppleWatchSelectionSourceLatestRule" in manager,
    "The iPhone manifest source must use the real episode media URL, exclude unsupported episodes, and support manual/latest-rule selection.",
)

require(
    'ICAppleWatchManifestReplace = @"manifest.replace"' in manager
    and "updateApplicationContext:payload" in manager
    and "[session transferUserInfo:payload]" in manager
    and "[session sendMessage:payload" in manager
    and "needsManifestSyncAfterActivation" in manager
    and "playback.watchPosition" in manager
    and "watch.downloaded" in manager
    and "watch.storageStatus" in manager,
    "The iPhone sync manager must use immediate/current manifest delivery, retry after WC activation, and the planned status/playback protocol.",
)

require(
    '#import "EpisodesTableViewCell.h"' in apple_watch_controller
    and '#import "ImageCacheManager.h"' in apple_watch_controller
    and "EpisodeViewController" not in apple_watch_controller
    and "pushViewController" not in apple_watch_controller
    and "trailingSwipeActionsConfigurationForRowAtIndexPath" in apple_watch_controller
    and "moveRowAtIndexPath" in apple_watch_controller
    and "canMoveRowAtIndexPath" in apple_watch_controller
    and "storageLabel" in apple_watch_controller
    and "storageProgressTrackView" in apple_watch_controller,
    "The iOS Apple Watch list must use normal episode cells, expose storage/reorder/removal controls, and must not navigate into show notes.",
)

require(
    "UISegmentedControl" not in apple_watch_controller
    and "ICAppleWatchEpisodesSortMode" not in apple_watch_controller
    and "configuration.title = @\"Jetzt synchronisieren\".ls" not in apple_watch_controller,
    "The iOS Apple Watch page must not expose ambiguous sort segments or an oversized text sync button.",
)

require(
    'self.title = @"Folgen auf Apple Watch".ls' in apple_watch_controller
    and 'systemImageNamed:@"pencil"' in apple_watch_controller
    and '@"checkmark"' in apple_watch_controller
    and "toggleEditMode:" in apple_watch_controller
    and "UITableViewCellEditingStyleDelete" in apple_watch_controller
    and "commitEditingStyle" in apple_watch_controller,
    "The iOS Apple Watch page must use the final list title, icon-only edit control, and a normal edit-mode delete control.",
)

require(
    '"%ld auf der Watch".ls' not in apple_watch_controller
    and "downloadedCount" not in apple_watch_controller,
    "The iOS Apple Watch header must not repeat the number of Watch episodes above the visible list.",
)

require(
    "moveEpisodeAtIndex" in manager
    and "visibleEpisodeStates" in manager
    and "playbackOrder" in manager
    and "accentColorHex" in manager
    and "imageURL" in manager
    and "subtitle" in manager,
    "The iPhone manifest must mirror the manual list order and send theme/media metadata to the Watch.",
)

require(
    "SuppressedAutomaticEpisodeHashes" in manager
    and "deleteObject:state" in manager
    and "watch.deleted" in manager
    and "watch.downloadEvicted" in manager,
    "Watch-side deletions must remove the episode on iOS and suppress automatic re-adds without confusing storage evictions with user deletes.",
)

require(
    "visibleEpisodeStates" in manager
    and "removingFromWatch" in manager.split("- (NSArray<AppleWatchEpisodeState*>*)visibleEpisodeStates", 1)[1].split("- (AppleWatchEpisodeState*)stateForEpisodeHash", 1)[0]
    and "_suppressAutomaticEpisodeHash" in manager.split("- (void)removeEpisodeFromWatch:(CDEpisode*)episode", 1)[1].split("- (void)prioritizeEpisodeOnWatch:(CDEpisode*)episode", 1)[0],
    "Episodes removed from the iOS Watch list must disappear from the visible list and must not be re-added by automatic feed rules.",
)

require(
    "configuration.allowsCellularAccess = true" in watch_download_manager
    and "configuration.sessionSendsLaunchEvents = true" in watch_download_manager
    and "configuration.waitsForConnectivity = true" in watch_download_manager
    and "URLSessionConfiguration.background" in watch_download_manager
    and "request.allowsCellularAccess = true" in watch_download_manager
    and "AVURLAsset(url: fileURL)" in watch_download_manager,
    "The Watch must download via background URLSession with cellular allowed and measure actual downloaded files.",
)

require(
    "reattachDownloadTasks" in watch_download_manager
    and "getAllTasks" in watch_download_manager
    and "reconcileManifestWithDownloadTasks" in watch_download_manager
    and "episode.status == .downloading" in watch_download_manager,
    "The Watch download manager must reattach and reconcile background URLSession tasks after launch/background delivery.",
)

require(
    "episode.status == .queued" in watch_download_manager
    and "episode.status == .queued || episode.status == .failed" not in watch_download_manager,
    "Failed Watch downloads must not be retried automatically by the queue runner.",
)

require(
    "HTTPURLResponse" in watch_download_manager
    and "200..<300" in watch_download_manager
    and "downloadValidationError" in watch_download_manager
    and "isPlayable" in watch_download_manager,
    "The Watch download manager must reject HTTP errors, empty files, and unplayable downloads before marking episodes downloaded.",
)

require(
    "WatchChapterExtractor.shared.extractChapters" in watch_download_manager
    and "item.chapters = chapterMetadata.chapters" in watch_download_manager
    and "item.chapterArtworkBaseURL = chapterMetadata.artworkBaseURL" in watch_download_manager,
    "The Watch download manager must extract chapters and chapter artwork from the downloaded media file before marking it ready.",
)

require(
    "stagedLocation" in watch_download_manager
    and "moveItem(at: location, to: stagedLocation)" in watch_download_manager
    and "downloadValidationError(for: downloadTask, fileURL: stagedLocation)" in watch_download_manager,
    "The Watch download manager must move URLSession's temporary file before returning from didFinishDownloadingTo.",
)

require(
    "InstacastWatchDownload-\\(UUID().uuidString).tmp" not in watch_download_manager,
    "The Watch download staging file must not force a .tmp extension onto playable media files.",
)

require(
    "await asset.load(.duration)" in watch_download_manager
    and "asset.duration" not in watch_download_manager,
    "The Watch download manager must read media duration through the non-deprecated watchOS asset-loading API.",
)

require(
    "case \"manifest.replace\"" in watch_connectivity
    and "case \"manifest.removeEpisodes\"" in watch_connectivity
    and "case \"download.prioritize\"" in watch_connectivity
    and "case \"playback.phoneState\"" in watch_connectivity
    and "didReceiveApplicationContext" in watch_connectivity
    and "delivery: .live" in watch_download_manager
    and "delivery: .current" in watch_player,
    "The Watch connectivity controller must receive the planned manifest, command, playback, and current-state messages without reliably queueing live progress.",
)

require(
    "updateAccentColorHex" in watch_connectivity
    and "accentColorHex" in watch_connectivity
    and "playbackOrder" in read("InstacastWatch/WatchEpisode.swift")
    and "imageURL" in read("InstacastWatch/WatchEpisode.swift")
    and "subtitle" in read("InstacastWatch/WatchEpisode.swift"),
    "The Watch model must accept accent color, artwork, subtitle, and playback order from the iPhone manifest.",
)

require(
    "playback.watchPosition" in watch_player
    and "playback.watchFinished" in watch_player
    and "WatchManifestStore.shared.updateEpisode" in watch_player
    and "episode.consumed = true" in watch_player,
    "The Watch player must persist and report playback positions and completion.",
)

require(
    "seek(by seconds" in watch_player
    and "nextPlayableEpisode" in watch_player
    and "tickPlaybackPosition" in watch_player,
    "The Watch player must expose seek controls, update visible playback position, and continue with the next episode in mirrored order.",
)

require(
    "do {" in watch_player
    and "catch" in watch_player
    and "guard player.play()" in watch_player
    and "markEpisodePlaybackFailed" in watch_player,
    "The Watch player must not enter playing state when AVAudioPlayer creation or playback fails.",
)

require(
    ".volumeAvailableCapacityKey" in read("InstacastWatch/WatchStorageManager.swift")
    and "attributesOfFileSystem" not in read("InstacastWatch/WatchStorageManager.swift"),
    "The Watch storage manager must measure free space with the real watchOS URL resource key.",
)

require(
    "chapterArtworkDirectory" in read("InstacastWatch/WatchStorageManager.swift")
    and "removeChapterArtwork(for:" in read("InstacastWatch/WatchStorageManager.swift"),
    "The Watch storage manager must clean up locally extracted chapter artwork with the episode download.",
)

require(
    "guard bytesNeeded > 0" not in read("InstacastWatch/WatchStorageManager.swift")
    and "50 * 1024 * 1024" in read("InstacastWatch/WatchStorageManager.swift")
    and "playbackOrder" in read("InstacastWatch/WatchStorageManager.swift"),
    "The Watch storage manager must keep minimum free space and evict from the bottom of the mirrored Watch order.",
)

require(
    "Apple Watch" in feed_settings
    and "AppleWatchSendLatestCount" in feed_settings
    and "AppleWatchOnlyUnplayed" in feed_settings
    and "rebuildAutomaticSelectionsAndSync" in feed_settings
    and "[[AppleWatchSyncManager sharedManager] rebuildAutomaticSelectionsAndSync];" not in feed_settings.split("- (void)viewDidAppear:(BOOL)animated", 1)[1].split("- (void) updateAppearance", 1)[0]
    and "An Apple Watch senden" in episodes_table
    and "Von Apple Watch entfernen" in episodes_table
    and "Priorisiert auf Watch laden" in episodes_table
    and "An Apple Watch senden" in episode_view
    and "kMainSidebarItemAppleWatch" in main_view
    and "watchIndicator" in cell,
    "The iPhone UI must expose feed rules, manual episode actions, the Watch sidebar page, and downloaded indicators.",
)

require(
    "heightForHeaderInSection" in feed_settings
    and "section == kAppleWatchSection" in feed_settings
    and "return 44" in feed_settings,
    "The per-podcast Apple Watch settings header must reserve enough height above the first setting row.",
)

for localization in ("Resources/en.lproj/Localizable.strings", "Resources/de.lproj/Localizable.strings"):
    strings = read(localization)
    for key in (
        "Neueste Episoden senden",
        "Nur ungespielte Episoden",
        "An Apple Watch senden",
        "Von Apple Watch entfernen",
        "Priorisiert auf Watch laden",
        "Wartet auf Apple Watch",
        "Die Apple Watch lädt ausgewählte Audiodateien selbst über WLAN oder Mobilfunk.",
    ):
        require(f'"{key}" =' in strings, f"{localization} is missing Apple Watch localization key: {key}")

require(
    "Localizable.strings in Resources" in project
    and "InstacastWatch/en.lproj/Localizable.strings" in project
    and "InstacastWatch/de.lproj/Localizable.strings" in project,
    "The Watch target must bundle localized Apple Watch UI strings.",
)

require(
    "NavigationStack" in watch_views
    and "WatchEpisodeListView" in watch_views
    and "WatchPlayerView" in watch_views
    and "navigationDestination(for: String.self)" in watch_views
    and "WatchArtworkLoader" in watch_views
    and "player.play(episode)" in watch_views
    and "playerPath = [episode.episodeHash]" in watch_views
    and "ThinProgressLine" in watch_views
    and "Von Watch entfernen" in watch_views,
    "The Watch UI must provide direct list playback, artwork, progress, a dedicated player page, retry, and removal controls.",
)

require(
    "NavigationLink" not in watch_views
    and "WatchEpisodeDetailView" not in watch_views
    and "checkmark.circle.fill" not in watch_views,
    "The Watch list must not navigate through an intermediate detail screen or show an unexplained green checkmark.",
)

require(
    'Image(systemName: "circle.fill")' not in watch_views
    and "playedIndicator" not in watch_views,
    "The Watch episode rows must not show an unexplained round status dot.",
)

require(
    'return isCurrent ? "speaker.wave.2.fill" : "applewatch"' not in watch_views
    and "statusIconName" not in watch_views
    and "NowPlayingControls" not in watch_views,
    "The Watch episode rows must not show a redundant Watch icon or inline player controls.",
)

require(
    "ScrollView" not in watch_views
    and '.navigationTitle("Episode")' not in watch_views
    and "Slider(" not in watch_views
    and "value: Binding" not in watch_views
    and "playerProgressFraction" in watch_views
    and "CompactSkipButton" in watch_views,
    "The Watch player must be a non-scrolling page with a compact progress bar, no generic Episode title, and no watchOS slider stepper controls.",
)

require(
    "ScrubbableProgressLine" in watch_views
    and "DragGesture(minimumDistance: 0)" in watch_views
    and "player.seek(to: duration * fraction)" in watch_views
    and "formatCompactDuration" in watch_views
    and "formatPlayerTime" in watch_views
    and "chapters: episode.chapters" in watch_views
    and "ChapterMarkerLine" in watch_views
    and "chapterTitleText" in watch_views
    and "lineLimit(2, reservesSpace: true)" in watch_views.split("Text(chapterTitleText)", 1)[1].split("ScrubbableProgressLine", 1)[0]
    and ".frame(height: compact ? 16 : 20)" in watch_views.split("private struct ScrubbableProgressLine", 1)[1]
    and "formatClock(" not in watch_views,
    "The Watch player progress must be scrubable, show chapter markers, reserve a stable two-line chapter title, and use second-level player time labels without changing compact list durations.",
)

require(
    "episode.currentChapter(at: currentPosition)" in watch_views
    and "ChapterArtworkImage" in watch_views
    and "chapterTitle" in watch_views
    and "currentChapter.imageFileName" in watch_views,
    "The Watch player must show the current chapter title and chapter artwork when the downloaded media provides them.",
)

require(
    "struct WatchChapter" in read("InstacastWatch/WatchEpisode.swift")
    and "var chapters: [WatchChapter]" in read("InstacastWatch/WatchEpisode.swift")
    and "var chapterArtworkBaseURL: URL?" in read("InstacastWatch/WatchEpisode.swift")
    and "decodeIfPresent([WatchChapter].self, forKey: .chapters) ?? []" in read("InstacastWatch/WatchEpisode.swift"),
    "The Watch episode model must persist extracted chapters and migrate older manifests without chapter data.",
)

require(
    "loadMetadata(for: .id3Metadata)" in watch_chapter_extractor
    and '"CHAP"' in watch_chapter_extractor
    and "loadChapterMetadataGroups" in watch_chapter_extractor
    and "CGImageDestinationCreateWithData" in watch_chapter_extractor
    and "WatchChapterExtractionResult" in watch_chapter_extractor,
    "The Watch chapter extractor must parse local ID3/M4A chapter metadata and normalize chapter artwork for local display.",
)

require(
    "skipForwardSeconds" in read("InstacastWatch/WatchEpisode.swift")
    and "skipBackwardSeconds" in read("InstacastWatch/WatchEpisode.swift")
    and "decodeIfPresent(Int.self, forKey: .skipForwardSeconds) ?? 30" in read("InstacastWatch/WatchEpisode.swift")
    and "decodeIfPresent(Int.self, forKey: .skipBackwardSeconds) ?? 30" in read("InstacastWatch/WatchEpisode.swift")
    and "PlayerSkipForwardPeriod" in manager
    and "PlayerSkipBackPeriod" in manager
    and '"skipForwardSeconds"' in manager
    and '"skipBackwardSeconds"' in manager
    and "player.seek(by: -Double(episode.skipBackwardSeconds))" in watch_views
    and "player.seek(by: Double(episode.skipForwardSeconds))" in watch_views,
    "Configured global/per-podcast skip durations must be mirrored to the Watch and used by the Watch player controls.",
)

require(
    "storageProgressTrackView" in apple_watch_controller
    and "storageUsedProgressView" in apple_watch_controller
    and "storagePodcastProgressView" in apple_watch_controller
    and '"Watch lädt Podcasts (%@/%@)"' in apple_watch_controller
    and '"%ld auf der Watch\\n%ld werden geladen"' not in apple_watch_controller
    and "showsPlaybackProgress = NO" in apple_watch_controller,
    "The iOS Apple Watch page must show stable Watch download/storage status and disable normal cell playback progress bars.",
)

require(
    '#import "PlaybackViewController.h"' in apple_watch_controller
    and '#import "AudioSession.h"' in apple_watch_controller
    and "playComboButtonAction:" in apple_watch_controller
    and "cell.playAccessoryButton.userInteractionEnabled = YES" in apple_watch_controller
    and "PlaybackViewController* playbackController" in apple_watch_controller,
    "The iOS Apple Watch episode list play buttons must start normal iPhone playback instead of being disabled.",
)

require(
    "fallbackPriceForRow" not in donation_view
    and '"$1"' not in donation_view
    and '"$5"' not in donation_view
    and '"$15"' not in donation_view
    and '"$20"' not in donation_view
    and "cell.userInteractionEnabled = (product != nil)" in donation_view,
    "The donation page must not show hard-coded USD fallback prices; it must wait for StoreKit localized prices from the signed-in account.",
)

require(
    "Installiere die InstacastPlus-Watch-App über die Watch-App auf deinem iPhone" in apple_watch_controller
    and "manager.supported && manager.paired && manager.watchAppInstalled" in apple_watch_controller
    and "newStates = @[]" in apple_watch_controller
    and "self.storageLabel.text = canManageWatchApp ? [self _storageTextForManager:manager] : nil" in apple_watch_controller
    and "self.navigationItem.rightBarButtonItem = canManageWatchApp ? self.editIconButtonItem : nil" in apple_watch_controller,
    "The iOS Apple Watch page must render the not-installed state as setup text only, without storage, episode rows, or edit controls.",
)

require(
    "configurationWithPointSize:27" in main_view
    and "systemImageNamed:@\"applewatch\" withConfiguration:watchSymbolConfiguration" in main_view,
    "The main sidebar Apple Watch symbol must be sized consistently with the other sidebar icons.",
)

require(
    "showsPlaybackProgress" in read("Classes/EpisodesTableViewCell.h")
    and "!self.showsPlaybackProgress" in cell,
    "Episode cells must expose a switch to hide playback progress in the Apple Watch management list.",
)

require(
    "watchUsedBytes" in read("Classes/AppleWatchSyncManager.h")
    and "watchTotalBytes" in read("Classes/AppleWatchSyncManager.h")
    and "currentWatchDownloadTitle" in read("Classes/AppleWatchSyncManager.h")
    and "currentWatchDownloadedBytes" in read("Classes/AppleWatchSyncManager.h")
    and "currentWatchExpectedBytes" in read("Classes/AppleWatchSyncManager.h")
    and '"usedBytes"' in watch_connectivity
    and '"totalBytes"' in watch_connectivity,
    "The phone must track Watch filesystem usage and the active Watch download from Watch status/progress messages.",
)

require(
    "indicatorY" in cell
    and "self.transcriptIndicatorVisible" in cell
    and "if (self.transcriptIndicatorVisible)" in cell
    and "_watchIndicator.frame = CGRectMake(indicatorX, indicatorY" in cell,
    "The episode cell must place the Watch indicator independently when the transcript indicator is hidden.",
)
