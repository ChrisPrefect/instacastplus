//
//  ICUserDefaults.h
//  Instacast
//
//  Created by Martin Hering on 18.12.12.
//
//

#import "Defines.h"

NSString* InstacastErrorDomain = @"InstacastErrorDomain";

NSString* DirectoryThirdLanguageChoice = @"DirectoryThirdLanguageChoice";
NSString* DirectorySelectedLanguage = @"DirectorySelectedLanguage";

NSString* SelectedAppLanguage = @"SelectedAppLanguage";

NSString* IntelligentSleepTimerAlwaysActive = @"IntelligentSleepTimerAlwaysActive";
NSString* ScreenTimerAlwaysActive = @"ScreenTimerAlwaysActive";
NSString* ScreenTouchIntelligentSleep = @"ScreenTouchIntelligentSleep";
NSString* VolumeChangeIntelligentSleep = @"VolumeChangeIntelligentSleep";
NSString* DeviceMovementIntelligentSleep = @"DeviceMovementIntelligentSleep";

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
