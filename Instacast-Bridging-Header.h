//
//  Instacast-Bridging-Header.h
//  Instacast
//
//  Bridging header for Swift → Objective-C access
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

#import "VemedioKit.h"
#import "VemedioDatabase.h"

#import "Defines.h"
#import "CDModel.h"
#import "CDEpisode.h"
#import "CDFeed.h"
#import "CDFeedProperty.h"
#import "CDChapter.h"
#import "CDMedium.h"
#import "DatabaseManager.h"
#import "CacheManager.h"
#import "PlaybackManager.h"
#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"
#import "SubscriptionManager.h"
#import "EpisodeLoadingManager.h"
#import "ICFeed.h"
#import "ICMetadata.h"
#import "ICMetadataParser.h"
#import "ICAppearanceManager.h"
#import "Application.h"

// App Intents (Siri / Shortcuts) support
#import "CDList.h"
#import "PlayerSpeedButton.h"
// Widget playback buttons run as AudioPlaybackIntents in the app process
#import "WidgetDataExporter.h"

#import "TranscriptionQueueViewController.h"
#if DEBUG && TARGET_OS_SIMULATOR
#import "PlayerInfoViewController_v5.h"
#import "PlaybackViewController.h"
#endif
