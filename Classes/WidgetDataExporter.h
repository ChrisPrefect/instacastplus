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

@end

NS_ASSUME_NONNULL_END
