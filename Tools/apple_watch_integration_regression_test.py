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
watch_plist = read("InstacastWatch/Info.plist")
feed_settings = read("Classes/FeedSettingsViewController.m")
episodes_table = read("Classes/EpisodesTableViewController.m")
episode_view = read("Classes/EpisodeViewController.m")
main_view = read("Classes/MainViewController_4.m")
cell = read("Classes/EpisodesTableViewCell.m")
apple_watch_controller = read("Classes/AppleWatchEpisodesViewController.m")


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
    'Text("InstacastPlus")' in watch_views
    and "foregroundStyle(accentColor)" in watch_views,
    "The Watch UI title must match the shipped app display name and use the synced accent color.",
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
    and "UIButtonConfiguration" in apple_watch_controller,
    "The iOS Apple Watch list must use normal episode cells, expose storage/reorder/removal controls, and must not navigate into show notes.",
)

require(
    "UISegmentedControl" not in apple_watch_controller
    and "ICAppleWatchEpisodesSortMode" not in apple_watch_controller
    and "configuration.title = @\"Jetzt synchronisieren\".ls" not in apple_watch_controller,
    "The iOS Apple Watch page must not expose ambiguous sort segments or an oversized text sync button.",
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
    and "AsyncImage" in watch_views
    and "player.play(episode)" in watch_views
    and "playerPath = [episode.episodeHash]" in watch_views
    and "ProgressView(value:" in watch_views
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
    "storageProgressView" in apple_watch_controller
    and "UIProgressView" in apple_watch_controller
    and '"Watch lädt \\"%@\\" (%@/%@)"' in apple_watch_controller
    and '"%ld auf der Watch\\n%ld werden geladen"' not in apple_watch_controller
    and "showsPlaybackProgress = NO" in apple_watch_controller,
    "The iOS Apple Watch page must show current Watch download/storage status and disable normal cell playback progress bars.",
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
