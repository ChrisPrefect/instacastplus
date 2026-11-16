//
//  WidgetDataExporter.h
//  Instacast
//
//  Writes JSON snapshots of app state to the App Group shared container
//  for consumption by WidgetKit widgets. Also copies artwork thumbnails.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WidgetDataExporter : NSObject

/// Last played episode dict (cached for fallback display and resume).
@property (nonatomic, strong, readonly, nullable) NSDictionary *lastPlayedEpisodeDict;

+ (instancetype)sharedExporter;

/// Called once at app launch (in AppDelegate didFinishLaunching).
/// Registers for all relevant NSNotifications.
- (void)startObserving;

/// Force full snapshot export (call in sceneDidEnterBackground).
- (void)exportAllSnapshots;

/// Targeted exports
- (void)exportNowPlayingSnapshot;
- (void)exportListsSnapshot;
- (void)exportStatsSnapshot;
- (void)exportSettingsSnapshot;

/// Reload widget timelines (debounced, calls WidgetCenter)
- (void)reloadWidgetTimelines;

/// Runs one Now Playing widget button action in this process. The widget's buttons are
/// AudioPlaybackIntents that the system executes in the app (launching it in the background
/// if needed), so this is called directly instead of through the pending-action files.
/// A chapter row also passes the episode it belongs to and the chapter's start time, so it
/// still works when its timeline is no longer loaded (for example after a relaunch).
/// Main thread only.
- (void)performWidgetControlAction:(NSString *)action
                      chapterIndex:(nullable NSNumber *)chapterIndex
         chapterTimelineIdentifier:(nullable NSString *)chapterTimelineIdentifier
                 episodeIdentifier:(nullable NSString *)episodeIdentifier
                  chapterStartTime:(nullable NSNumber *)chapterStartTime;

@end

NS_ASSUME_NONNULL_END
