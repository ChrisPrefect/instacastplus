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
