//
//  ICUserDefaults.h
//  Instacast
//
//  Created by Martin Hering on 18.12.12.
//
//

#import <Foundation/Foundation.h>

extern NSString* InstacastErrorDomain;

extern NSString* DirectoryThirdLanguageChoice;
extern NSString* DirectorySelectedLanguage;

extern NSString* SelectedAppLanguage;

extern NSString* IntelligentSleepTimerAlwaysActive;
extern NSString* ScreenTimerAlwaysActive;
extern NSString* ScreenTouchIntelligentSleep;
extern NSString* VolumeChangeIntelligentSleep;
extern NSString* DeviceMovementIntelligentSleep;

extern NSString* PlayerColorPerPodcastActive;
extern NSString* PlayerThemeColorCode;
extern NSString* PlayerThemeColorHexCode;
extern NSString* InterfaceThemeDefaultActive;
extern NSString* InterfaceThemeColorCode;
extern NSString* InterfaceThemeColorHexCode;

extern NSString* ShowApplicationBadgeForUnseen;
extern NSString* LastRefreshSubscriptionDate;
extern NSString* FirstLaunchDate;
extern NSString* MediaLibraryImportedFeedTitles;
extern NSString* EnabledBackgroundPlayback;

extern NSString* ActiveContentFilter;
extern NSString* WelcomeMessageVersion;
extern NSString* EnableCachingOver3G;
extern NSString* EnableCachingImagesOver3G;
extern NSString* EnableRefreshingOver3G;
extern NSString* AutoCacheNewAudioEpisodes;
extern NSString* AutoCacheNewVideoEpisodes;

extern NSString* AutoCacheStorageLimit;
extern NSString* UISoundEnabled;
extern NSString* PlayerSkipBackPeriod;
extern NSString* PlayerSkipForwardPeriod;
extern NSString* PlayerAutoSkipEndPeriod;
extern NSString* PlayerAutoSkipStartPeriod;
extern NSString* PlayerReplayAfterPause;
extern NSString* DropBoxRootPath;
extern NSString* LinkDropBox;

extern NSString* FeedSortOrder;
extern NSString* FeedSortKey;
extern NSString* SortOrderNewerFirst;
extern NSString* SortOrderOlderFirst;

extern NSString* FeedListSortMode;

extern NSString* DefaultPlaybackSpeed;
extern NSString* DefaultIntelligentSleepTimer;
extern NSString* UncompletedSleepTimeInterval;
extern NSString* LastSelectedSleepTimer;


extern NSString* EnableManualRefreshFinishedNotification;
extern NSString* EnableManualDownloadFinishedNotification;
extern NSString* EnableNewEpisodeNotification;

extern NSString* DisableAutoLock;
extern NSString* EnableStreamingOver3G;


extern NSString* UIStateSelectedFeed;
extern NSString* UIStateSelectedEpisode;

extern NSString* ReadLaterService;
extern NSString* ReadLaterServiceNone;
extern NSString* ReadLaterServiceInstapaper;
extern NSString* ReadLaterServiceReadability;
extern NSString* ReadLaterServiceReadItLater;

extern NSString* AllowSendingDiagnostics;
enum {
	DiagnosticsDontSend = 0,
	DiagnosticsAskBeforeSending = 1,
	DiagnosticsAutomaticallySend = 2
};
extern NSString* AutomaticallySendDiagnostics;

extern NSString* SharingFullName;
extern NSString* SharingTwitterHandle;

extern NSString* AutoDeleteAfterFinishedPlaying;
extern NSString* AutoDeleteAfterMarkedAsPlayed;
extern NSString* AutoDeleteNewsMode;
extern NSString* ContinuousPlayFromFeed;
extern NSString* AutoDownloadWhileStreaming;

extern NSString* kDefaultShowUnavailableEpisodes;

extern NSString* kDefaultPlayerControls;
typedef NS_ENUM(NSInteger, DefaultPlayerControls) {
    kPlayerSeekingControls,
    kPlayerSeekingAndSkippingChaptersControls,
    kPlayerSkippingControls
};
extern NSString* kDefaultDontDeleteUpNextWhenChangingEpisode;

extern NSString* kDefaultAppearanceMode;

typedef NS_ENUM(NSInteger, ICAppearanceMode) {
    ICAppearanceModeAutomatic = 0,  // Default - follows system
    ICAppearanceModeLight = 1,
    ICAppearanceModeDark = 2
};

#if TARGET_OS_IPHONE==1
#else
extern NSString* AutoRefresh;
enum {
    AutoRefreshNever = 1,
    AutoRefreshOncePerDay,
    AutoRefreshEvery12Hours,
    AutoRefreshEvery6Hours,
    AutoRefreshEveryHour,
    AutoRefreshEvery15Minutes,
};
typedef NSInteger AutoRefreshInterval;
#endif

extern NSString* kICDurationValueTransformer;
extern NSString* kICPubdateValueTransformer;

extern NSString* kUIPersistenceMainSidebarItem;
extern NSString* kUIPersistenceSubscriptionsSelectedFeedUID;
extern NSString* kUIPersistenceSubscriptionsSearchTerm;
extern NSString* kUIPersistencePlaylistsSelectedPlaylistUID;
extern NSString* kUIPersistenceBookmarkSelectedEpisodeGUID;
extern NSString* kUIPersistenceDirectorySearchSearchString;
extern NSString* kUIPersistenceDirectorySearchSelectedScopeIndex;

// Smart Home MQTT
extern NSString* SmarthomeMQTTEnabled;
extern NSString* SmarthomeMQTTHost;
extern NSString* SmarthomeMQTTPort;
extern NSString* SmarthomeMQTTUsername;
extern NSString* SmarthomeMQTTPassword;
extern NSString* SmarthomeAllowControl;
extern NSString* SmarthomeWiFiOnly;
extern NSString* SmarthomeDeviceName;

extern NSString* OpenLinksInExternalBrowser;

// iCloud Sync
extern NSString* iCloudSyncEnabled;
extern NSString* iCloudSyncPlaybackStatus;
extern NSString* iCloudSyncNowPlaying;
extern NSString* iCloudSyncSubscriptions;
extern NSString* iCloudSyncFeedSettings;
extern NSString* iCloudSyncAppSettings;
extern NSString* iCloudSyncDownloadStatus;
extern NSString* iCloudSyncDeviceID;
extern NSString* iCloudSyncLastSyncDate;
extern NSString* iCloudSyncServerChangeToken;
extern NSString* iCloudSyncInitialSyncCompleted;

extern NSString* AudioSessionSleepTimerDidExpireNotification;
extern NSString* ApplicationDidDetectMotionNotification;

