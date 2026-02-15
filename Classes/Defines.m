//
//  ICUserDefaults.h
//  Instacast
//
//  Created by Martin Hering on 18.12.12.
//
//

#import "Defines.h"
#import <math.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif

NSString* InstacastErrorDomain = @"InstacastErrorDomain";

NSString* DirectoryThirdLanguageChoice = @"DirectoryThirdLanguageChoice";
NSString* DirectorySelectedLanguage = @"DirectorySelectedLanguage";

NSString* SelectedAppLanguage = @"SelectedAppLanguage";

NSString* IntelligentSleepTimerAlwaysActive = @"IntelligentSleepTimerAlwaysActive";
NSString* ScreenTimerAlwaysActive = @"ScreenTimerAlwaysActive";
NSString* ScreenTouchIntelligentSleep = @"ScreenTouchIntelligentSleep";
NSString* VolumeChangeIntelligentSleep = @"VolumeChangeIntelligentSleep";
NSString* DeviceMovementIntelligentSleep = @"DeviceMovementIntelligentSleep";
NSString* DisableSleepTimerInCarPlay = @"DisableSleepTimerInCarPlay";

NSString* PlayerColorPerPodcastActive = @"PlayerColorPerPodcastActive";
NSString* PlayerThemeColorCode = @"PlayerThemeColorCode";
NSString* PlayerThemeColorHexCode = @"PlayerThemeColorHexCode";
NSString* InterfaceThemeDefaultActive = @"InterfaceThemeDefaultActive";
NSString* InterfaceThemeColorCode = @"InterfaceThemeColorCode";
NSString* InterfaceThemeColorHexCode = @"InterfaceThemeColorHexCode";


NSString* ShowApplicationBadgeForUnseen = @"ShowApplicationBadgeForUnseen";
NSString* LastRefreshSubscriptionDate = @"LastRefreshSubscriptionDate";
NSString* FirstLaunchDate = @"FirstLaunchDate";
NSString* MediaLibraryImportedFeedTitles = @"MediaLibraryImportedFeedTitles";
NSString* EnabledBackgroundPlayback = @"EnabledBackgroundPlayback";
NSString* WelcomeMessageVersion = @"WelcomeMessageVersion";

NSString* EnableCachingOver3G = @"EnableCachingOver3G";
NSString* EnableCachingImagesOver3G = @"EnableCachingImagesOver3G";
NSString* EnableRefreshingOver3G = @"EnableRefreshingOver3G";
NSString* AutoCacheNewAudioEpisodes = @"AutoCacheNewAudioEpisodes";
NSString* AutoCacheNewVideoEpisodes = @"AutoCacheNewVideoEpisodes";
NSString* AutoCacheStorageLimit = @"AutoCacheStorageLimit";
NSString* UISoundEnabled = @"UISoundEnabled";
NSString* PlayerSkipBackPeriod = @"PlayerSkipBackPeriod";
NSString* PlayerSkipForwardPeriod = @"PlayerSkipForwardPeriod";
NSString* PlayerAutoSkipEndPeriod = @"PlayerAutoSkipEndPeriod";
NSString* PlayerAutoSkipStartPeriod = @"PlayerAutoSkipStartPeriod";
NSString* PlayerReplayAfterPause = @"ReplayAfterPause";
NSString* DropBoxRootPath = @"DropBoxRootPath";
NSString* LinkDropBox = @"LinkDropBox";

NSString* FeedSortOrder = @"FeedSortOrder";
NSString* FeedSortKey = @"FeedSortKey";

NSString* SortOrderNewerFirst = @"NewerFirst";
NSString* SortOrderOlderFirst = @"OlderFirst";

NSString* FeedListSortMode = @"FeedListSortMode";

NSString* DefaultPlaybackSpeed = @"DefaultPlaybackSpeed";
NSString* DefaultIntelligentSleepTimer = @"DefaultIntelligentSleepTimer";
NSString* EnableManualRefreshFinishedNotification = @"EnableManualRefreshFinishedNotification";
NSString* EnableManualDownloadFinishedNotification = @"EnableManualDownloadFinishedNotification";
NSString* EnableNewEpisodeNotification = @"EnableNewEpisodeNotification";
NSString* UncompletedSleepTimeInterval = @"UncompletedSleepTimeInterval";
NSString* LastSelectedSleepTimer = @"LastSelectedSleepTimer";

NSString* DisableAutoLock = @"DisableAutoLock";

NSString* EnableStreamingOver3G = @"EnableStreamingOver3G";

NSString* UIStateSelectedFeed = @"UIStateSelectedFeed";
NSString* UIStateSelectedEpisode = @"UIStateSelectedEpisode";

NSString* ReadLaterService = @"ReadLaterService";
NSString* ReadLaterServiceNone = @"None";
NSString* ReadLaterServiceInstapaper = @"Instapaper";
NSString* ReadLaterServiceReadability = @"Readability";
NSString* ReadLaterServiceReadItLater = @"Pocket";

NSString* AllowSendingDiagnostics = @"AllowSendingDiagnostics";
NSString* AutomaticallySendDiagnostics = @"AutomaticallySendDiagnostics";

NSString* SharingFullName = @"SharingFullName";
NSString* SharingTwitterHandle= @"SharingTwitterHandle";

NSString* AutoDeleteAfterFinishedPlaying = @"AutoDeleteAfterFinishedPlaying";
NSString* AutoDeleteAfterMarkedAsPlayed = @"AutoDeleteAfterMarkedAsPlayed";
NSString* AutoDeleteNewsMode = @"AutoDeleteNewsMode";
NSString* KeepNewestEpisodesCount = @"KeepNewestEpisodesCount";
NSString* PauseFeedSynchronization = @"PauseFeedSynchronization";
NSString* ContinuousPlayFromFeed = @"ContinuousPlayFromFeed";
NSString* AutoDownloadWhileStreaming = @"AutoDownloadWhileStreaming";

NSString* kDefaultShowUnavailableEpisodes = @"ShowUnavailableEpisodes";

NSString* kDefaultPlayerControls = @"PlayerControls";
NSString* kDefaultAppearanceMode = @"AppearanceMode";
NSString* kDefaultDontDeleteUpNextWhenChangingEpisode = @"DontDeleteUpNextWhenChangingEpisode";

#if TARGET_OS_IPHONE==1
#else
NSString* AutoRefresh = @"AutoRefresh";
#endif

NSString* kICDurationValueTransformer = @"ICDurationValueTransformer";
NSString* kICPubdateValueTransformer = @"ICPubdateValueTransformer";


NSString* kUIPersistenceMainSidebarItem = @"SelectedMainSidebarItem";
NSString* kUIPersistenceSubscriptionsSelectedFeedUID = @"SubscriptionsSelectedFeedUID";
NSString* kUIPersistenceSubscriptionsSearchTerm = @"SubscriptionsSearchTerm";
NSString* kUIPersistencePlaylistsSelectedPlaylistUID = @"DefaultPlaylistsSelectedPlaylistUID";
NSString* kUIPersistenceBookmarkSelectedEpisodeGUID = @"DefaultBookmarkSelectedEpisodeGUID";
NSString* kUIPersistenceListScrollPositions = @"ListScrollPositions";
NSString* kUIPersistenceListScrollPositionsLastModified = @"ListScrollPositionsLastModified";
NSString* ICListScrollPositionsDidChangeNotification = @"ICListScrollPositionsDidChangeNotification";

// Smart Home MQTT
NSString* SmarthomeMQTTEnabled = @"SmarthomeMQTTEnabled";
NSString* SmarthomeMQTTHost = @"SmarthomeMQTTHost";
NSString* SmarthomeMQTTPort = @"SmarthomeMQTTPort";
NSString* SmarthomeMQTTUsername = @"SmarthomeMQTTUsername";
NSString* SmarthomeMQTTPassword = @"SmarthomeMQTTPassword";
NSString* SmarthomeAllowControl = @"SmarthomeAllowControl";
NSString* SmarthomeWiFiOnly = @"SmarthomeWiFiOnly";
NSString* SmarthomeDeviceName = @"SmarthomeDeviceName";

NSString* OpenLinksInExternalBrowser = @"OpenLinksInExternalBrowser";

// iCloud Sync
NSString* iCloudSyncEnabled = @"iCloudSyncEnabled";
NSString* iCloudSyncPlaybackStatus = @"iCloudSyncPlaybackStatus";
NSString* iCloudSyncNowPlaying = @"iCloudSyncNowPlaying";
NSString* iCloudSyncSubscriptions = @"iCloudSyncSubscriptions";
NSString* iCloudSyncFeedSettings = @"iCloudSyncFeedSettings";
NSString* iCloudSyncAppSettings = @"iCloudSyncAppSettings";
NSString* iCloudSyncDownloadStatus = @"iCloudSyncDownloadStatus";
NSString* iCloudSyncLists = @"iCloudSyncLists";
NSString* iCloudSyncUpNext = @"iCloudSyncUpNext";
NSString* iCloudSyncDeviceID = @"iCloudSyncDeviceID";
NSString* iCloudSyncLastSyncDate = @"iCloudSyncLastSyncDate";
NSString* iCloudSyncServerChangeToken = @"iCloudSyncServerChangeToken";
NSString* iCloudSyncInitialSyncCompleted = @"iCloudSyncInitialSyncCompleted";

NSString* AudioSessionSleepTimerDidExpireNotification = @"AudioSessionSleepTimerDidExpireNotification";
NSString* ApplicationDidDetectMotionNotification = @"ApplicationDidDetectMotionNotification";

static NSDictionary<NSString*, NSNumber*>* _validatedListScrollPositionsDictionary(NSDictionary* rawPositions)
{
    if (![rawPositions isKindOfClass:[NSDictionary class]]) {
        return @{};
    }

    NSMutableDictionary<NSString*, NSNumber*>* validated = [NSMutableDictionary dictionaryWithCapacity:[rawPositions count]];
    [rawPositions enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
        if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSNumber class]]) {
            validated[(NSString*)key] = (NSNumber*)obj;
        }
    }];
    return [validated copy];
}

NSDictionary<NSString*, NSNumber*>* ICListScrollPositionsSnapshot(void)
{
    NSDictionary* rawPositions = [USER_DEFAULTS objectForKey:kUIPersistenceListScrollPositions];
    return _validatedListScrollPositionsDictionary(rawPositions);
}

NSDate* ICListScrollPositionsLastModifiedDate(void)
{
    id value = [USER_DEFAULTS objectForKey:kUIPersistenceListScrollPositionsLastModified];
    return [value isKindOfClass:[NSDate class]] ? (NSDate*)value : nil;
}

NSNumber* ICListScrollPositionForKey(NSString* key)
{
    if (![key isKindOfClass:[NSString class]] || [key length] == 0) {
        return nil;
    }
    return ICListScrollPositionsSnapshot()[key];
}

void ICUpdateListScrollPositionForKey(NSString* key, CGFloat offsetY)
{
    if (![key isKindOfClass:[NSString class]] || [key length] == 0) {
        return;
    }

    NSDictionary<NSString*, NSNumber*>* current = ICListScrollPositionsSnapshot();
    NSNumber* previousOffset = current[key];
    if (previousOffset && fabs(previousOffset.doubleValue - offsetY) < 0.5) {
        return;
    }

    NSMutableDictionary<NSString*, NSNumber*>* updated = [current mutableCopy];
    updated[key] = @(offsetY);

    [USER_DEFAULTS setObject:updated forKey:kUIPersistenceListScrollPositions];
    [USER_DEFAULTS setObject:[NSDate date] forKey:kUIPersistenceListScrollPositionsLastModified];
    [USER_DEFAULTS synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:ICListScrollPositionsDidChangeNotification object:nil];
}

void ICApplySyncedListScrollPositions(NSDictionary<NSString*, NSNumber*>* positions, NSDate* lastModified)
{
    if (!lastModified) {
        return;
    }

    NSDate* localLastModified = ICListScrollPositionsLastModifiedDate();
    if (localLastModified && [lastModified compare:localLastModified] != NSOrderedDescending) {
        return;
    }

    NSDictionary<NSString*, NSNumber*>* validated = _validatedListScrollPositionsDictionary(positions);
    [USER_DEFAULTS setObject:validated forKey:kUIPersistenceListScrollPositions];
    [USER_DEFAULTS setObject:lastModified forKey:kUIPersistenceListScrollPositionsLastModified];
    [USER_DEFAULTS synchronize];
}

#if TARGET_OS_IPHONE
static UIEdgeInsets _effectiveInsetsForScrollView(UIScrollView* scrollView)
{
    if (@available(iOS 11.0, *)) {
        return scrollView.adjustedContentInset;
    }
    return scrollView.contentInset;
}

static CGFloat _clampedOffsetYForScrollView(UIScrollView* scrollView, CGFloat offsetY)
{
    UIEdgeInsets insets = _effectiveInsetsForScrollView(scrollView);
    CGFloat minOffset = -insets.top;
    CGFloat maxOffset = scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds) + insets.bottom;
    if (maxOffset < minOffset) {
        maxOffset = minOffset;
    }
    return MIN(MAX(offsetY, minOffset), maxOffset);
}

static void _updateScrollPositionWithDelay(NSString* key, CGFloat offsetY, NSTimeInterval delay)
{
    static NSMutableDictionary<NSString*, NSNumber*>* pendingOffsets = nil;
    static NSMutableDictionary<NSString*, NSNumber*>* pendingTokens = nil;
    static unsigned long long tokenCounter = 0;

    if (!pendingOffsets) {
        pendingOffsets = [[NSMutableDictionary alloc] init];
        pendingTokens = [[NSMutableDictionary alloc] init];
    }

    if (delay <= 0) {
        [pendingTokens removeObjectForKey:key];
        [pendingOffsets removeObjectForKey:key];
        ICUpdateListScrollPositionForKey(key, offsetY);
        return;
    }

    tokenCounter++;
    NSNumber* token = @(tokenCounter);
    pendingOffsets[key] = @(offsetY);
    pendingTokens[key] = token;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delay, 0) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSNumber* currentToken = pendingTokens[key];
        if (!currentToken || ![currentToken isEqualToNumber:token]) {
            return;
        }

        NSNumber* pendingOffset = pendingOffsets[key];
        [pendingTokens removeObjectForKey:key];
        [pendingOffsets removeObjectForKey:key];

        if (pendingOffset) {
            ICUpdateListScrollPositionForKey(key, pendingOffset.doubleValue);
        }
    });
}

void ICStoreScrollPositionForScrollView(NSString* key, UIScrollView* scrollView)
{
    ICScheduleStoreScrollPositionForScrollView(key, scrollView, 0);
}

void ICScheduleStoreScrollPositionForScrollView(NSString* key, UIScrollView* scrollView, NSTimeInterval delay)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ICScheduleStoreScrollPositionForScrollView(key, scrollView, delay);
        });
        return;
    }

    if (!scrollView || !scrollView.window || ![key isKindOfClass:[NSString class]] || [key length] == 0) {
        return;
    }

    CGFloat offsetY = _clampedOffsetYForScrollView(scrollView, scrollView.contentOffset.y);
    _updateScrollPositionWithDelay(key, offsetY, delay);
}

void ICRestoreScrollPositionForScrollView(NSString* key, UIScrollView* scrollView)
{
    if (!scrollView) {
        return;
    }
    NSNumber* storedOffset = ICListScrollPositionForKey(key);
    if (!storedOffset) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!scrollView.window) {
            return;
        }

        [scrollView layoutIfNeeded];
        CGFloat offsetY = storedOffset.doubleValue;

        // Legacy/stale absolute offset 0 causes clipped top content when top inset is > 0.
        UIEdgeInsets insets = _effectiveInsetsForScrollView(scrollView);
        CGFloat minOffset = -insets.top;
        if (fabs(offsetY) < 0.5f && minOffset < -0.5f) {
            offsetY = minOffset;
        }

        offsetY = _clampedOffsetYForScrollView(scrollView, offsetY);
        [scrollView setContentOffset:CGPointMake(scrollView.contentOffset.x, offsetY) animated:NO];
    });
}
#endif
