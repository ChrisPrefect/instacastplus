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
extern NSString* DeviceMovementSensitivity;
extern NSString* DisableSleepTimerInCarPlay;

extern NSString* PlayerColorPerPodcastActive;
extern NSString* PlayerThemeColorCode;
extern NSString* PlayerThemeColorHexCode;
extern NSString* InterfaceThemeDefaultActive;
extern NSString* InterfaceThemeColorCode;
extern NSString* InterfaceThemeColorHexCode;
extern NSString* WidgetThemeDefaultActive;
extern NSString* WidgetThemeColorCode;
extern NSString* WidgetThemeColorHexCode;

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
extern NSString* UIHapticsEnabled;
extern NSString* PlayerSkipBackPeriod;
extern NSString* PlayerSkipForwardPeriod;
extern NSString* PlayerNearChapterEndForwardSkipMode;
extern NSString* PlayerNearChapterEndForwardSkipWindow;
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
extern NSString* EnableRefreshFailureNotification;
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
extern NSString* PodcastRefreshOnAppStart;
extern NSString* KeepNewestEpisodesCount;
extern NSString* ContinuousPlayFromFeed;
extern NSString* AutoDownloadWhileStreaming;
extern NSString* AppleWatchSendLatestCount;
extern NSString* AppleWatchOnlyUnplayed;

extern NSString* ICiCloudSyncEpisodesEnabled;
extern NSString* ICiCloudSyncSubscriptionsEnabled;
extern NSString* ICiCloudSyncSettingsEnabled;
extern NSString* ICiCloudSyncStateDidChangeNotification;
extern NSString* ICiCloudSyncDevicesDidChangeNotification;

extern NSString* kDefaultShowUnavailableEpisodes;

extern NSString* kDefaultPlayerControls;
typedef NS_ENUM(NSInteger, DefaultPlayerControls) {
    kPlayerSeekingControls,
    kPlayerSeekingAndSkippingChaptersControls,
    kPlayerSkippingControls
};
extern NSString* kDefaultDontDeleteUpNextWhenChangingEpisode;

extern NSString* kDefaultAppearanceMode;
extern NSString* kDefaultDarkModePureBlack;
extern NSString* kDefaultFontSizeLarger;
extern NSString* kDefaultTranscriptHighlightStyle;

typedef NS_ENUM(NSInteger, ICTranscriptHighlightStyle) {
    ICTranscriptHighlightBold = 0,       // Bold + colored (default)
    ICTranscriptHighlightBackground = 1  // Color + subtle background
};

typedef NS_ENUM(NSInteger, ICAppearanceMode) {
    ICAppearanceModeAutomatic = 0,  // Default - follows system
    ICAppearanceModeLight = 1,
    ICAppearanceModeDark = 2
};

extern NSString* TapOnEpisodeAction;
typedef NS_ENUM(NSInteger, ICTapOnEpisodeAction) {
    ICTapOnEpisodeActionPlay = 0,
    ICTapOnEpisodeActionShowNotes = 1,
    ICTapOnEpisodeActionOpenContextMenu = 2
};

extern NSString* EpisodeSwipeRightAction;
extern NSString* EpisodeSwipeLeftAction;
typedef NS_ENUM(NSInteger, ICEpisodeSwipeAction) {
    ICEpisodeSwipeActionTogglePlayed = 0,
    ICEpisodeSwipeActionToggleFavorite,
    ICEpisodeSwipeActionDownload,
    ICEpisodeSwipeActionAddToPlayNext,
    ICEpisodeSwipeActionDelete,
    ICEpisodeSwipeActionEpisodeInfo,
    ICEpisodeSwipeActionTranscribe,
    ICEpisodeSwipeActionSendToAppleWatch
};

extern NSString* EnabledPlaybackSpeedsKey;

// Transcription & Chapters
BOOL ICAITranscriptionFeaturesAvailable(void);
BOOL ICAITranscriptionFeaturesEnabled(void);
extern NSString* kLocalTranscriptionEnabled;         // BOOL - local transcription/chapter actions enabled
extern NSString* kServerTranscriptionEnabled;        // BOOL - shared server transcription actions enabled
extern NSString* kAutomaticTranscriptionBackend;     // @"local" or @"server"
extern NSString* kTranscriptionEngine;              // "WhisperKit" or "Apple"
extern NSString* kTranscriptionWhisperModel;         // "large-v3-turbo" or "small"
extern NSString* kTranscriptionAutoDefault;           // BOOL - auto-transcribe new episodes
extern NSString* kChapterAutoDefault;                 // BOOL - auto-generate chapters
extern NSString* kTranscriptionEverActivated;         // BOOL - set to YES after first transcription
extern NSString* kAutoSkipSponsors;                   // BOOL - auto-skip sponsor chapters
extern NSString* kTranscriptionFirstRunShown;         // BOOL - first-run dialog shown

// Per-Feed keys (stored via CDFeedProperty)
extern NSString* kFeedPropertyAutoTranscribe;         // "default", "yes", "no"
extern NSString* kFeedPropertyAutoChapters;            // "default", "yes", "no"
extern NSString* kFeedPropertyAutoSkipSponsors;        // "default", "yes", "no"

// Transcription status values
typedef NS_ENUM(NSInteger, ICTranscriptionStatus) {
    ICTranscriptionStatusNone = 0,
    ICTranscriptionStatusQueued,
    ICTranscriptionStatusDownloadingModel,
    ICTranscriptionStatusAnalyzingMusic,
    ICTranscriptionStatusTranscribing,
    ICTranscriptionStatusGeneratingChapters,
    ICTranscriptionStatusCompleted,
    ICTranscriptionStatusFailed
};

// Notifications
extern NSString* ICTranscriptionDidStartNotification;
extern NSString* ICTranscriptionDidProgressNotification;
extern NSString* ICTranscriptionDidFinishNotification;
extern NSString* ICTranscriptionDidFailNotification;
extern NSString* ICTranscriptionQueueDidChangeNotification;
extern NSString* ICTranscriptionSettingsDidChangeNotification;

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
extern NSString* kUIPersistenceListScrollPositions;
extern NSString* kUIPersistenceListScrollPositionsLastModified;
extern NSString* ICListScrollPositionsDidChangeNotification;

FOUNDATION_EXPORT NSDictionary<NSString*, NSNumber*>* ICListScrollPositionsSnapshot(void);
FOUNDATION_EXPORT NSDate* ICListScrollPositionsLastModifiedDate(void);
FOUNDATION_EXPORT NSNumber* ICListScrollPositionForKey(NSString* key);
FOUNDATION_EXPORT void ICUpdateListScrollPositionForKey(NSString* key, CGFloat offsetY);
FOUNDATION_EXPORT void ICApplySyncedListScrollPositions(NSDictionary<NSString*, NSNumber*>* positions, NSDate* lastModified);

#if TARGET_OS_IPHONE
@class UIScrollView;
FOUNDATION_EXPORT void ICStoreScrollPositionForScrollView(NSString* key, UIScrollView* scrollView);
FOUNDATION_EXPORT void ICScheduleStoreScrollPositionForScrollView(NSString* key, UIScrollView* scrollView, NSTimeInterval delay);
FOUNDATION_EXPORT void ICRestoreScrollPositionForScrollView(NSString* key, UIScrollView* scrollView);
#endif

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
extern NSString* AmazonAffiliateEnabled;


extern NSString* AudioSessionSleepTimerDidExpireNotification;
extern NSString* ApplicationDidDetectMotionNotification;
