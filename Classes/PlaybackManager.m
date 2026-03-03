//
//  PlaybackManager.m
//  Instacast
//
//  Created by Martin Hering on 05.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <AVFoundation/AVFoundation.h>
#if TARGET_OS_IPHONE
#import <MediaPlayer/MediaPlayer.h>
#import <CarPlay/CarPlay.h>
#import "PlayerView.h"
#else
#import "AudioSession_OSX.h"
#import "ICPlayerView_OSX.h"
#import "PlaybackManager+Mikey.h"
#import "PlaybackManager+AudioDevice.h"
#import "PlaybackManager+RemoteControl.h"
#import "ICSharingManager.h"
#endif



#import "ImageFunctions.h"
#import "CDModel.h"
#import "CDEpisode+ShowNotes.h"
#import "CDChapter.h"
#import "ICMetadataParser.h"
#import "ICImageCacheOperation.h"
#import <MediaPlayer/MediaPlayer.h>

#define SEND_UPDATE [self _sendUpdateNotification];

#if !TARGET_OS_IPHONE
#ifdef __MAC_10_9
#define ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR 1
#endif
#endif

NSString* PlaybackManagerDidStartNotification = @"MPPlaybackManagerDidStartNotification";
NSString* PlaybackManagerDidEndNotification = @"MPPlaybackManagerDidEndNotification";
NSString* PlaybackManagerDidUpdateNotification = @"MPPlaybackManagerDidUpdateNotification";
NSString* PlaybackManagerDidChangeEpisodeNotification = @"MPPlaybackManagerDidChangeEpisodeNotification";
NSString* PlaybackManagerEpisodeDidFinishNotification = @"MPPlaybackManagerEpisodeDidFinishNotification";


#if TARGET_OS_IPHONE
static NSString* kMediaItemInstacastCurrentArtwork =  @"Instacast_currentArtwork";
static NSString* kMediaItemInstacastEpisodeHash =  @"Instacast_episodeHash";
#endif

static NSString* kDefaultTemporaryPlaybackPositions = @"TemporaryPlaybackPositions";
static NSString* kDefaultPlaybackVolume = @"PlaybackVolume";

enum {
	IdleState,
	InitializedState,
	ShouldRunState,
	RunningState,
	VideoPausedInBackground
};


@interface AudioSession ()
@property (nonatomic, readwrite, strong) CDEpisode* episode;
@property (nonatomic, readwrite, strong) NSMutableArray* playlist;
@property BOOL autoStopDisabled;
@end

@interface PlaybackManager ()
@property (nonatomic, readwrite, strong) CDEpisode* playingEpisode;
@property (nonatomic, readwrite, getter=isReady) BOOL ready;
@property (nonatomic, readwrite) BOOL failed;
@property (nonatomic, readwrite, getter=hasMovingVideo) BOOL movingVideo;
@property (nonatomic, readwrite) CGSize viewImageSize;

@property (nonatomic, readwrite, strong) AVURLAsset* mediaAsset;
@property (nonatomic, readwrite, strong) AVPlayer* player;
@property (readwrite, strong) PlayerView* playerView;
@property (nonatomic, readwrite, strong) NSDate* lastPauseDate;
@property (nonatomic, readwrite, strong) NSDate* playStartDate;

@property (nonatomic) BOOL changingEpisode;
@property (nonatomic) BOOL changingPosition;

@property (readwrite, strong) NSArray* chapters;
@property (readwrite, strong) NSArray* artworks;

@property (nonatomic, weak) NSTimer* controlTimer;
@property (nonatomic, strong) NSDate* controlStartDate;

#if TARGET_OS_IPHONE
@property (nonatomic) UIBackgroundTaskIdentifier bufferNextItemTaskIdentifier;
#endif

@property (nonatomic) double initialPlaybackTime;
@property (nonatomic, weak) id playbackObserver;
@property (nonatomic, weak) id positionObserver;
@property (assign) NSInteger state;

@property (nonatomic) BOOL inTransitionToNextTrack;
@property (nonatomic, strong) NSMutableDictionary* nowPlayingInfo;
@property (nonatomic, strong) NSTimer* nowPlayingDelayTimer;
@property (nonatomic) double seekingPosition;
@property (nonatomic, strong) NSDate* seekingPositionChangeDate;
@property (nonatomic, strong) ICMetadataChapter* seekingChapter;

// Chapter skip protection
@property (nonatomic) BOOL isAutoSkipping;
@property (nonatomic, strong) NSDate *lastAutoSkipDate;
@property (nonatomic, strong) NSArray *autoSkipMarkers;  // @[@{@"start": @(time), @"resume": @(time)}], resume == -1 → finish episode
@property (nonatomic) NSInteger suppressedSkipMarker;    // Manual seek protection: marker index to suppress
@end


@implementation PlaybackManager {
    float       _volume;
    float*      _chapterTimesIdx;
    float*      _artworkTimesIdx;
}

#pragma mark -

+ (PlaybackManager*) playbackManager;
{
	static PlaybackManager* gPlaybackManager = nil;
    static dispatch_once_t onceToken = 0;
    dispatch_once(&onceToken, ^{
        gPlaybackManager = [[PlaybackManager alloc] init];
    });
	return gPlaybackManager;
}



- (id) init
{
	if ((self = [super init]))
	{
#if TARGET_OS_IPHONE

        // overwrite current default on iOS, because we actually use the system volume
        [USER_DEFAULTS setFloat:1.0f forKey:kDefaultPlaybackVolume];
#else
        dispatch_async(dispatch_get_main_queue(), ^{
            [self initializeMikey];
            [self initializeAudioDeviceListener];
#ifndef APP_STORE
            [self initializeRemoteControl];
#endif
            [self _setAudioEndpointToCurrentSystemAudioDevice];
        });
#endif
	}
	
	return self;
}


- (void) _sendUpdateNotification
{
    if ([NSThread isMainThread]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerDidUpdateNotification object:self];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerDidUpdateNotification object:self];
        });
    }
}

- (void) _endNextItemHandover
{
#if TARGET_OS_IPHONE
	if (self.bufferNextItemTaskIdentifier != UIBackgroundTaskInvalid) {
		[App endBackgroundTask:self.bufferNextItemTaskIdentifier];
		self.bufferNextItemTaskIdentifier = UIBackgroundTaskInvalid;
	}
#endif
}

- (void) _startNextItemHandover
{
	[self _endNextItemHandover];
#if TARGET_OS_IPHONE
	self.bufferNextItemTaskIdentifier = [App beginBackgroundTaskWithExpirationHandler:^(void) {
        [App endBackgroundTask:self.bufferNextItemTaskIdentifier];
		self.bufferNextItemTaskIdentifier = UIBackgroundTaskInvalid;
	}];
	#endif
}

#if TARGET_OS_IPHONE
- (BOOL)_isCarPlaySceneConnectedForNowPlaying
{
#if TARGET_OS_MACCATALYST
    return NO;
#else
    if (@available(iOS 13.0, *))
    {
        NSSet<UIScene*>* connectedScenes = [UIApplication sharedApplication].connectedScenes;
        for (UIScene* scene in connectedScenes)
        {
            if ([scene.session.role isEqualToString:CPTemplateApplicationSceneSessionRoleApplication] &&
                scene.activationState != UISceneActivationStateUnattached &&
                scene.activationState != UISceneActivationStateBackground)
            {
                return YES;
            }
        }
    }
    return NO;
#endif
}

- (void)_setNowPlayingArtworkFromImage:(UIImage*)image
{
    if (!image) {
        return;
    }

    MPMediaItemArtwork* artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage * _Nonnull(CGSize size) {
        return image;
    }];
    if (artwork) {
        self.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork;
    }
}

- (void)_applyEpisodeArtworkToNowPlayingForEpisode:(CDEpisode*)episode forceRefresh:(BOOL)forceRefresh
{
    if (!episode) {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyArtwork];
        [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastEpisodeHash];
        return;
    }

    NSString* episodeHash = episode.objectHash ?: @"";
    NSString* currentEpisodeHash = self.nowPlayingInfo[kMediaItemInstacastEpisodeHash];
    BOOL hasArtwork = (self.nowPlayingInfo[MPMediaItemPropertyArtwork] != nil);
    if (!forceRefresh && [currentEpisodeHash isEqualToString:episodeHash] && hasArtwork) {
        return;
    }

    self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] = episodeHash;

    void (^clearArtworkIfCurrentEpisode)(void) = ^{
        CDEpisode* playingEpisode = self.playingEpisode;
        if (!playingEpisode || ![playingEpisode.objectHash isEqualToString:episodeHash]) {
            return;
        }
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyArtwork];
    };

    void (^displayImageIfCurrentEpisode)(UIImage*) = ^(UIImage* image) {
        if (!image) {
            return;
        }
        CDEpisode* playingEpisode = self.playingEpisode;
        if (!playingEpisode || ![playingEpisode.objectHash isEqualToString:episodeHash]) {
            return;
        }
        [self _setNowPlayingArtworkFromImage:image];
    };

    ImageCacheManager* imageManager = [ImageCacheManager sharedImageCacheManager];
    UIImage* cachedEpisodeImage = [imageManager localImageForImageURL:episode.imageURL size:320 grayscale:NO];
    if (cachedEpisodeImage) {
        displayImageIfCurrentEpisode(cachedEpisodeImage);
        return;
    }

    UIImage* cachedFeedImage = [imageManager localImageForImageURL:episode.feed.imageURL size:320 grayscale:NO];
    if (cachedFeedImage) {
        displayImageIfCurrentEpisode(cachedFeedImage);
        return;
    }

    if (episode.imageURL) {
        ICImageCacheOperation* episodeOperation = [[ICImageCacheOperation alloc] initWithURL:episode.imageURL size:320 grayscale:NO];
        episodeOperation.didEndBlock = ^(IC_IMAGE* image, NSError* error) {
            if (image) {
                displayImageIfCurrentEpisode(image);
                [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
                return;
            }

            if (episode.feed.imageURL) {
                ICImageCacheOperation* feedOperation = [[ICImageCacheOperation alloc] initWithURL:episode.feed.imageURL size:320 grayscale:NO];
                feedOperation.didEndBlock = ^(IC_IMAGE* feedImage, NSError* feedError) {
                    if (feedImage) {
                        displayImageIfCurrentEpisode(feedImage);
                    } else {
                        clearArtworkIfCurrentEpisode();
                    }
                    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
                };
                [imageManager addImageCacheOperation:feedOperation sender:self];
            } else {
                clearArtworkIfCurrentEpisode();
                [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
            }
        };
        [imageManager addImageCacheOperation:episodeOperation sender:self];
        return;
    }

    if (episode.feed.imageURL) {
        ICImageCacheOperation* feedOperation = [[ICImageCacheOperation alloc] initWithURL:episode.feed.imageURL size:320 grayscale:NO];
        feedOperation.didEndBlock = ^(IC_IMAGE* image, NSError* error) {
            if (image) {
                displayImageIfCurrentEpisode(image);
            } else {
                clearArtworkIfCurrentEpisode();
            }
            [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
        };
        [imageManager addImageCacheOperation:feedOperation sender:self];
        return;
    }

    clearArtworkIfCurrentEpisode();
}
#endif


- (void) _setNowPlayingInfoOfEpisode:(CDEpisode*)anEpisode
{
    //DebugLog(@"_setNowPlayingInfoOfEpisode");
#if TARGET_OS_IPHONE
    if (!self.nowPlayingInfo) {
        self.nowPlayingInfo = [NSMutableDictionary dictionary];
    }
    else if (![self.nowPlayingInfo isKindOfClass:[NSMutableDictionary class]])
    {
        self.nowPlayingInfo = [self.nowPlayingInfo mutableCopy];
    }
    
    
    [self.nowPlayingInfo setObject:@(MPMediaTypePodcast) forKey:MPMediaItemPropertyMediaType];
    
	
    NSString* podcastTitle = nil;
    NSString* episodeTitle = nil;
    NSString* chapterTitle = nil;
    
    if (anEpisode)
    {
        CDFeed* feed = anEpisode.feed;
        podcastTitle = feed.title;

        if (anEpisode.title && feed.title) {
            episodeTitle = [anEpisode cleanTitleUsingFeedTitle:feed.title];
        } else {
            episodeTitle = anEpisode.title;
        }

        if (feed.uid.length > 0) {
            [self.nowPlayingInfo setObject:feed.uid forKey:MPNowPlayingInfoCollectionIdentifier];
        } else {
            [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoCollectionIdentifier];
        }
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoCollectionIdentifier];
    }
    
    // Put the current chapter into the subtitle line where supported.
    if ([self.chapters count] > 0 && self.currentChapter >= 0 && self.currentChapter < [self.chapters count])
    {
        ICMetadataChapter* chapter = [self.chapters objectAtIndex:self.currentChapter];
        chapterTitle = chapter.title;
    }

    NSString* nowPlayingTitle = episodeTitle;
    NSString* nowPlayingArtist = podcastTitle;
    NSString* nowPlayingAlbum = chapterTitle;

    if ([self _isCarPlaySceneConnectedForNowPlaying]) {
        // CarPlay layout: top = episode, second line = current chapter, third line = podcast.
        NSString* carPlayTitle = (episodeTitle.length > 0) ? episodeTitle : podcastTitle;
        NSString* carPlayArtist = nil;
        NSString* carPlayAlbum = nil;

        if (chapterTitle.length > 0) {
            carPlayArtist = chapterTitle;
            if (podcastTitle.length > 0 &&
                ![podcastTitle isEqualToString:carPlayTitle] &&
                ![podcastTitle isEqualToString:carPlayArtist]) {
                carPlayAlbum = podcastTitle;
            }
        }
        else if (podcastTitle.length > 0 && ![podcastTitle isEqualToString:carPlayTitle]) {
            carPlayArtist = podcastTitle;
        }

        nowPlayingTitle = carPlayTitle;
        nowPlayingArtist = carPlayArtist;
        nowPlayingAlbum = carPlayAlbum;
    }

    if (nowPlayingTitle.length > 0) {
        [self.nowPlayingInfo setObject:nowPlayingTitle forKey:MPMediaItemPropertyTitle];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyTitle];
    }

    if (nowPlayingArtist.length > 0) {
        [self.nowPlayingInfo setObject:nowPlayingArtist forKey:MPMediaItemPropertyArtist];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyArtist];
    }

    if (nowPlayingAlbum.length > 0) {
        [self.nowPlayingInfo setObject:nowPlayingAlbum forKey:MPMediaItemPropertyAlbumTitle];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPMediaItemPropertyAlbumTitle];
    }

    
    // set image in case we have chapter based images
    if (!self.movingVideo && [self.artworks count] > 0 && self.currentArtwork >= 0 && self.currentArtwork < [self.artworks count])
    {
        ICMetadataImage* artwork = self.artworks[self.currentArtwork];
        NSNumber* currentArtwork = self.nowPlayingInfo[kMediaItemInstacastCurrentArtwork];
        NSString* episodeHash = anEpisode.objectHash ?: @"";
        NSString* currentEpisodeHash = self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] ?: @"";
        BOOL episodeChanged = ![currentEpisodeHash isEqualToString:episodeHash];
        
        if (!currentArtwork || [currentArtwork integerValue] != self.currentArtwork || episodeChanged)
        {
            NSInteger expectedArtworkIndex = self.currentArtwork;
            NSString* expectedEpisodeHash = episodeHash;
            [artwork loadPlatformImageWithCompletion:^(id platformImage) {
                CDEpisode* playingEpisode = self.playingEpisode;
                if (expectedEpisodeHash.length > 0 &&
                    (!playingEpisode || ![playingEpisode.objectHash isEqualToString:expectedEpisodeHash])) {
                    return;
                }

                if (platformImage)
                {
                    if (self.currentArtwork != expectedArtworkIndex) {
                        return;
                    }
                    [self _setNowPlayingArtworkFromImage:(UIImage*)platformImage];
                    self.nowPlayingInfo[kMediaItemInstacastCurrentArtwork] = @(expectedArtworkIndex);
                    if (expectedEpisodeHash.length > 0) {
                        self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] = expectedEpisodeHash;
                    } else {
                        [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastEpisodeHash];
                    }
                }
                else {
                    [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastCurrentArtwork];
                    [self _applyEpisodeArtworkToNowPlayingForEpisode:anEpisode forceRefresh:YES];
                }
                
                [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;

            }];
        }
        if (episodeHash.length > 0) {
            self.nowPlayingInfo[kMediaItemInstacastEpisodeHash] = episodeHash;
        } else {
            [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastEpisodeHash];
        }
    }
    else
    {
        BOOL hadChapterArtwork = (self.nowPlayingInfo[kMediaItemInstacastCurrentArtwork] != nil);
        [self.nowPlayingInfo removeObjectForKey:kMediaItemInstacastCurrentArtwork];
        [self _applyEpisodeArtworkToNowPlayingForEpisode:anEpisode forceRefresh:hadChapterArtwork];
    }
    
    [self.nowPlayingInfo setObject:[NSNumber numberWithFloat:self.duration] forKey:MPMediaItemPropertyPlaybackDuration];
    
    [self.nowPlayingInfo setObject:[NSNumber numberWithDouble:self.player.rate] forKey:MPNowPlayingInfoPropertyPlaybackRate];
    [self.nowPlayingInfo setObject:[NSNumber numberWithDouble:(double)self.time] forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    
    if (self.chapters && self.currentChapter >= 0) {
        [self.nowPlayingInfo setObject:[NSNumber numberWithUnsignedInteger:[self.chapters count]] forKey:MPNowPlayingInfoPropertyChapterCount];
        [self.nowPlayingInfo setObject:[NSNumber numberWithInteger:self.currentChapter] forKey:MPNowPlayingInfoPropertyChapterNumber];
    } else {
        [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoPropertyChapterCount];
        [self.nowPlayingInfo removeObjectForKey:MPNowPlayingInfoPropertyChapterNumber];
    }
    
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = self.nowPlayingInfo;
    if (@available(iOS 13.0, *)) {
        MPNowPlayingInfoCenter.defaultCenter.playbackState = (self.player.rate > 0.0f) ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
    }
    
#endif
}


- (void) _setupRemotePlaybackCenterWithEpisode:(CDEpisode*)episode
{
#if TARGET_OS_IPHONE
    MPRemoteCommandCenter *rcc = [MPRemoteCommandCenter sharedCommandCenter];
    
    // reset all commands first
    MPRemoteCommand *pauseCommand = rcc.pauseCommand;
    pauseCommand.enabled = NO;
    [pauseCommand removeTarget:self];
    //
    MPRemoteCommand *playCommand = rcc.playCommand;
    playCommand.enabled = NO;
    [playCommand removeTarget:self];
    
    MPRemoteCommand *togglePlayPauseCommand = rcc.togglePlayPauseCommand;
    togglePlayPauseCommand.enabled = NO;
    [togglePlayPauseCommand removeTarget:self];
    
    
    MPSkipIntervalCommand* skipBackwardIntervalCommand = rcc.skipBackwardCommand;
    skipBackwardIntervalCommand.enabled = NO;
    [skipBackwardIntervalCommand removeTarget:self];
    
    MPSkipIntervalCommand* skipForwardIntervalCommand = rcc.skipForwardCommand;
    skipForwardIntervalCommand.enabled = NO;
    [skipForwardIntervalCommand removeTarget:self];
    
    
    MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
    nextTrackCommand.enabled = NO;
    [nextTrackCommand removeTarget:self];
    
    MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
    previousTrackCommand.enabled = NO;
    [previousTrackCommand removeTarget:self];
    
    MPRemoteCommand* skipForwardCommand = rcc.seekForwardCommand;
    skipForwardCommand.enabled = NO;
    [skipForwardCommand removeTarget:self];
    
    MPRemoteCommand* seekBackwardCommand = rcc.seekBackwardCommand;
    seekBackwardCommand.enabled = NO;
    [seekBackwardCommand removeTarget:self];

    MPChangePlaybackPositionCommand* changePlaybackPositionCommand = rcc.changePlaybackPositionCommand;
    changePlaybackPositionCommand.enabled = NO;
    [changePlaybackPositionCommand removeTarget:self];
    
    
    if (episode)
    {
        CDFeed* feed = episode.feed;
        
        MPRemoteCommand *pauseCommand = rcc.pauseCommand;
        pauseCommand.enabled = YES;
        [pauseCommand addTarget:self action:@selector(_playPauseEvent:)];
        //
        MPRemoteCommand *playCommand = rcc.playCommand;
        playCommand.enabled = YES;
        [playCommand addTarget:self action:@selector(_playPauseEvent:)];
        
        MPRemoteCommand *togglePlayPauseCommand = rcc.togglePlayPauseCommand;
        togglePlayPauseCommand.enabled = YES;
        [togglePlayPauseCommand addTarget:self action:@selector(_playPauseEvent:)];

        MPChangePlaybackPositionCommand* changePlaybackPositionCommand = rcc.changePlaybackPositionCommand;
        changePlaybackPositionCommand.enabled = YES;
        [changePlaybackPositionCommand addTarget:self action:@selector(_changePlaybackPositionEvent:)];
        
        if ([feed integerForKey:kDefaultPlayerControls] == kPlayerSkippingControls)
        {
            MPSkipIntervalCommand* skipBackwardIntervalCommand = rcc.skipBackwardCommand;
            skipBackwardIntervalCommand.enabled = YES;
            [skipBackwardIntervalCommand addTarget:self action:@selector(_skipBackwardEvent:)];
            skipBackwardIntervalCommand.preferredIntervals = @[@([feed integerForKey:PlayerSkipBackPeriod])];
            
            MPSkipIntervalCommand* skipForwardIntervalCommand = rcc.skipForwardCommand;
            skipForwardIntervalCommand.enabled = YES;
            skipForwardIntervalCommand.preferredIntervals = @[@([feed integerForKey:PlayerSkipForwardPeriod])];
            [skipForwardIntervalCommand addTarget:self action:@selector(_skipForwardEvent:)];
            
            MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
            nextTrackCommand.enabled = YES;
            [nextTrackCommand addTarget:self action:@selector(_skipForwardEvent:)];
            
            MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
            previousTrackCommand.enabled = YES;
            [previousTrackCommand addTarget:self action:@selector(_skipBackwardEvent:)];
        }
        else
        {
            if ([feed integerForKey:kDefaultPlayerControls] == kPlayerSeekingAndSkippingChaptersControls)
            {
                MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
                nextTrackCommand.enabled = YES;
                [nextTrackCommand addTarget:self action:@selector(_nextChapterEvent:)];
                
                MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
                previousTrackCommand.enabled = YES;
                [previousTrackCommand addTarget:self action:@selector(_previousChapterEvent:)];
            }
            else
            {
                MPRemoteCommand* nextTrackCommand = rcc.nextTrackCommand;
                nextTrackCommand.enabled = YES;
                [nextTrackCommand addTarget:self action:@selector(_skipForwardEvent:)];
                
                MPRemoteCommand* previousTrackCommand = rcc.previousTrackCommand;
                previousTrackCommand.enabled = YES;
                [previousTrackCommand addTarget:self action:@selector(_skipBackwardEvent:)];
            }
            
            
            MPRemoteCommand* skipForwardCommand = rcc.seekForwardCommand;
            skipForwardCommand.enabled = YES;
            [skipForwardCommand addTarget:self action:@selector(_seekForwardEvent:)];
            
            MPRemoteCommand* seekBackwardCommand = rcc.seekBackwardCommand;
            seekBackwardCommand.enabled = YES;
            [seekBackwardCommand addTarget:self action:@selector(_seekBackwardEvent:)];
        }
        
    }
#endif
}

#if TARGET_OS_IPHONE

-(MPRemoteCommandHandlerStatus) _seekForwardEvent: (MPSeekCommandEvent *) seekEvent
{
    if (seekEvent.type == MPSeekCommandEventTypeBeginSeeking) {
        [self beginSeekingForward];
    }
    if (seekEvent.type == MPSeekCommandEventTypeEndSeeking) {
        [self endSeeking];
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

-(MPRemoteCommandHandlerStatus) _seekBackwardEvent: (MPSeekCommandEvent *) seekEvent
{
    if (seekEvent.type == MPSeekCommandEventTypeBeginSeeking) {
        [self beginSeekingBackward];
    }
    if (seekEvent.type == MPSeekCommandEventTypeEndSeeking) {
       [self endSeeking];
    }
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _playPauseEvent:(MPRemoteCommandEvent*)event
{
    [self playPause];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)_changePlaybackPositionEvent:(MPChangePlaybackPositionCommandEvent*)event
{
    if (!self.playingEpisode || self.duration <= 0) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }

    NSTimeInterval requestedTime = event.positionTime;
    requestedTime = MAX(0.0, MIN(requestedTime, self.duration));
    [self _suppressAutoSkipMarkerAtTime:requestedTime];
    [self seekToTime:requestedTime tolerance:NO];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _skipBackwardEvent:(MPRemoteCommandEvent*)event
{
    [self seekBackward];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _skipForwardEvent:(MPRemoteCommandEvent*)event
{
    [self seekForward];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _nextChapterEvent:(MPRemoteCommandEvent*)event
{
    [self nextChapter];
    return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus) _previousChapterEvent:(MPRemoteCommandEvent*)event
{
    [self previousChapter];
    return MPRemoteCommandHandlerStatusSuccess;
}
#endif

#pragma mark -

- (void) openWithEpisode:(CDEpisode*)anEpisode at:(NSTimeInterval)time autostart:(BOOL)autostart
{
	if (self.player) {
		self.changingEpisode = YES;
		[self closeAndSaveCurrentPosition:!self.inTransitionToNextTrack];
        self.inTransitionToNextTrack = NO;
	}

    [[NSNotificationCenter defaultCenter] postNotificationName:((self.changingEpisode) ? PlaybackManagerDidChangeEpisodeNotification : PlaybackManagerDidStartNotification) object:self];
	self.changingEpisode = NO;
	
    [self _setNowPlayingInfoOfEpisode:anEpisode];
    [self _setupRemotePlaybackCenterWithEpisode:anEpisode];
	
	// create background task until the first data is buffered and the app is ready to play
	[self _startNextItemHandover];
	
	self.ready = NO;
	self.failed = NO;
    self.movingVideo = NO;
	self.currentChapter = -1;
    self.currentArtwork = -1;
    self.initialPlaybackTime = time;
	
	CacheManager* eman = [CacheManager sharedCacheManager];
	CDMedium* media = [anEpisode preferedMedium];
	
	BOOL isCached = [eman episodeIsCached:anEpisode];
	NSURL* url = isCached ? [eman URLForCachedEpisode:anEpisode] : media.fileURL;

	// auto-download while streaming
	if (!isCached && [USER_DEFAULTS boolForKey:AutoDownloadWhileStreaming]) {
		[eman cacheEpisode:anEpisode];
	}

    // workaround for a bug in the feed parser up to version 3.0.2
    NSString* urlString = [url absoluteString];
    if ([urlString rangeOfString:@"%25"].location != NSNotFound) {
        urlString = [urlString stringByRemovingPercentEncoding];
        url = [NSURL URLWithString:urlString];
    }
	
    self.playingEpisode = anEpisode;
	self.state = InitializedState;
	
	self.mediaAsset = [AVURLAsset URLAssetWithURL:url options:nil];
	
	[self.mediaAsset loadValuesAsynchronouslyForKeys:@[@"tracks", @"duration"] completionHandler:^(void) {
		NSError *error = nil;
		AVKeyValueStatus tracksStatus = [self.mediaAsset statusOfValueForKey:@"tracks" error:&error];
		switch (tracksStatus) {
			case AVKeyValueStatusLoaded:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self _continueOpeningAsset:self.mediaAsset autostart:autostart];
                });
				break;
            }
			case AVKeyValueStatusFailed:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    ErrLog(@"AVAsset load failed: %@", [error description]);
                    self.failed = YES;
                    [self close];
                    SEND_UPDATE
                });
				break;
            }
			case AVKeyValueStatusCancelled:
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.mediaAsset = nil;
                    [self _endNextItemHandover];
                });
				break;
            }
            default:
                break;
		}
	}];
}

- (void)updateNowPlayingInfo {
    /*MPNowPlayingInfoCenter *nowPlayingInfoCenter = [MPNowPlayingInfoCenter defaultCenter];
    NSDictionary *nowPlayingInfo = @{
        MPMediaItemPropertyTitle: self.playingEpisode.title,
        MPMediaItemPropertyArtist: self.playingEpisode.author,
        MPMediaItemPropertyPlaybackDuration: @(self.playingEpisode.duration), // total duration in seconds
        MPNowPlayingInfoPropertyElapsedPlaybackTime: @(self.playingEpisode.position) // current time in seconds
    };
    nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo;*/
}


- (void) _continueOpeningAsset:(AVURLAsset*)asset autostart:(BOOL)autostart 
{
    if (self.initialPlaybackTime == 0) {
        // also handle special case, where we don't have a duration
        self.initialPlaybackTime = (self.playingEpisode.position < self.playingEpisode.duration - 5 || self.playingEpisode.duration < 1) ? self.playingEpisode.position : 0;

        // Check for temporary saved position first (user's last playback position)
        NSString* key = self.playingEpisode.objectHash;
        NSDictionary* playbackPositions = [USER_DEFAULTS objectForKey:kDefaultTemporaryPlaybackPositions];
        NSNumber* temporaryPosition = playbackPositions[key];
        if (temporaryPosition) {
            self.initialPlaybackTime = [temporaryPosition doubleValue];
        }

        // Apply start-skip only if we're starting from the beginning or before the skip point
        CDFeed* feed = self.playingEpisode.feed;
        double periodFeedStart = [feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_start_period", feed.uid]];
        double periodGeneralStart = [USER_DEFAULTS doubleForKey:PlayerAutoSkipStartPeriod];
        double skipStartPeriod = (periodFeedStart != 0.0) ? periodFeedStart : periodGeneralStart;

        // Only apply start-skip if current position is before the skip point
        if (skipStartPeriod > 0.0 && self.initialPlaybackTime < skipStartPeriod) {
            self.initialPlaybackTime = skipStartPeriod;
        }
    }
    
    AVPlayerItem* playerItem = [AVPlayerItem playerItemWithAsset:asset];
    if (!playerItem) {
        self.failed = YES;
        [self close];
        SEND_UPDATE
        return;
    }
    
    __weak PlaybackManager* weakSelf = self;
    
    [playerItem addTaskObserver:self forKeyPath:@"status" task:^(id obj, NSDictionary *change)
    {
        AVPlayerItem* currentItem = weakSelf.player.currentItem;
        if (currentItem.status == AVPlayerItemStatusReadyToPlay && weakSelf.state == InitializedState)
        {
            CDEpisode* episode = weakSelf.playingEpisode;
            CDFeed* feed = episode.feed;
            
            episode.lastPlayed = [NSDate date];
            [DMANAGER save];//DevD to do crashes            
            // check if we have moving video
            weakSelf.movingVideo = NO;
            
            NSArray* tracks = currentItem.tracks;
            for(AVPlayerItemTrack* track in tracks) {
                AVAssetTrack* assetTrack = track.assetTrack;
                
                if ([assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) //track.enabled && 
                {
                    CMFormatDescriptionRef formatDescription = (__bridge CMFormatDescriptionRef)[[assetTrack formatDescriptions] lastObject];
                    if (CMFormatDescriptionGetMediaSubType(formatDescription) != kCMVideoCodecType_JPEG) {
                        weakSelf.movingVideo = YES;
                        
                        CGSize videodimensions = CMVideoFormatDescriptionGetPresentationDimensions(formatDescription, true, true);
                        weakSelf.viewImageSize = videodimensions;
                        break;
                    }
                }
            }
            
#if TARGET_OS_IPHONE
            if ([weakSelf.player respondsToSelector:@selector(allowsAirPlayVideo)]) {
                weakSelf.player.allowsExternalPlayback = weakSelf.movingVideo;
            }
            
            if (!weakSelf.playerView && weakSelf.movingVideo) {
                weakSelf.playerView = [[PlayerView alloc] init];
                [(PlayerView*)weakSelf.playerView setPlayer:weakSelf.player];
            }
            
#else
            if (!weakSelf.playerView && weakSelf.movingVideo) {
                weakSelf.playerView = [[PlayerView alloc] initWithFrame:NSZeroRect];
                [(PlayerView*)weakSelf.playerView setPlayer:weakSelf.player];
            }
#endif
            
            
            if (weakSelf.initialPlaybackTime > 0) {
                [weakSelf seekToTime:weakSelf.initialPlaybackTime];
                weakSelf.initialPlaybackTime = 0;
            }
#if !TARGET_OS_IPHONE
            else {
                [[ICSharingManager sharedManager] triggerEvent:ICSharingServiceEpisodeDidStartPlaying object:weakSelf.playingEpisode];
            }
#endif
            
            weakSelf.ready = YES;
            weakSelf.state = (autostart) ? ShouldRunState : RunningState;
            if (!autostart) {
                [weakSelf _endNextItemHandover];
            }

            // don't use the setter, otherwise the value will be stored
            [weakSelf willChangeValueForKey:@"speedControl"];
            _speedControl = [feed integerForKey:DefaultPlaybackSpeed];
            _playbackRate = [weakSelf rateFromSpeedControl:_speedControl];
            [weakSelf didChangeValueForKey:@"speedControl"];

            [weakSelf willChangeValueForKey:@"duration"];
            [weakSelf didChangeValueForKey:@"duration"];

            SEND_UPDATE
            [weakSelf _startLoadingChapters];
            if (weakSelf.player.currentItem.playbackLikelyToKeepUp && autostart) {
                [weakSelf play];
                [weakSelf updateNowPlayingInfo];
            }
        }

        else if (weakSelf.player.currentItem.status == AVPlayerItemStatusFailed) {
            ErrLog(@"playback failed/interrupted due to error :%@", weakSelf.player.currentItem.error);
            weakSelf.failed = YES;
            [weakSelf close];
        }
    }];
    
    [playerItem addTaskObserver:self forKeyPath:@"playbackLikelyToKeepUp" task:^(id obj, NSDictionary *change)
    {
        if (weakSelf.state == ShouldRunState) {
            [weakSelf play];
            [weakSelf updateNowPlayingInfo];
        }
    }];

    [playerItem addTaskObserver:self forKeyPath:@"playbackBufferFull" task:^(id obj, NSDictionary *change)
     {
         if (weakSelf.state == ShouldRunState) {
             [weakSelf play];
             [weakSelf updateNowPlayingInfo];
         }
     }];
    
    
    [playerItem addTaskObserver:self forKeyPath:@"loadedTimeRanges" task:^(id obj, NSDictionary *change) {
        [self willChangeValueForKey:@"playableDuration"];
        [self didChangeValueForKey:@"playableDuration"];
        
        if ([self playableDuration] > 60 && self.state == ShouldRunState) {
            [self play];
            [self updateNowPlayingInfo];
        }
    }];
    
    
    
    self.player = [[AVPlayer alloc] initWithPlayerItem:playerItem];
    self.player.volume = [USER_DEFAULTS floatForKey:kDefaultPlaybackVolume];

#if ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR==1
    if ([NSBundle systemVersion] >= VM_SYSTEM_VERSION_OS_X_10_9 && [AVPlayer implementsSelector:@selector(audioOutputDeviceUniqueID)]) {
        [PlaybackManager setDataSourceOfAudioDeviceForEndpoint:self.audioEndpoint];
        self.player.audioOutputDeviceUniqueID = self.audioEndpoint.UID;
    }
#endif
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(playerItemDidPlayToEndTimeNotification:) name:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem];
    

    [self.player addTaskObserver:self forKeyPath:@"rate" task:^(id obj, NSDictionary *change)
    {
       // DebugLog(@"kPlayerRateChangedContext: %lf", weakSelf.player.rate);
        float rate = weakSelf.player.rate;
                
        if (rate > 0 && weakSelf.state == ShouldRunState) {
            weakSelf.state = RunningState;
            [weakSelf performSelector:@selector(_endNextItemHandover) withObject:nil afterDelay:1.0];
        }

        if (weakSelf.mediaAsset && rate == 0 && weakSelf.state == RunningState)
        {
            [weakSelf _saveCurrentPlaybackPosition];//DevD to do
        }
        
        if (weakSelf.ready) {
            [weakSelf willChangeValueForKey:@"paused"];
            [weakSelf didChangeValueForKey:@"paused"];
        }
        
        [weakSelf perform:^(id sender) {
            [weakSelf _setNowPlayingInfoOfEpisode:weakSelf.playingEpisode];
            [weakSelf _setupRemotePlaybackCenterWithEpisode:weakSelf.playingEpisode];
        } afterDelay:0.1];

        // Silent audio playback to keep app alive when paused in background
        if (rate == 0 && weakSelf.playingEpisode) {
            [[AudioSession sharedAudioSession] startSilentPlayback];
        } else {
            [[AudioSession sharedAudioSession] stopSilentPlayback];
        }

        if (@available(iOS 13.0, *)) {
            MPNowPlayingInfoCenter.defaultCenter.playbackState = (rate > 0.0f) ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
        }

        // Propagate the effective player state (rate-based paused/running) immediately.
        [weakSelf _sendUpdateNotification];
    }];

    self.playbackObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1,25000) queue:NULL usingBlock:^(CMTime time) {
        
        // make sure we're not resetting the position here when we first need to seek to it on startup
        CDEpisode* episode = weakSelf.playingEpisode;
        
        if (weakSelf.initialPlaybackTime == 0 && episode.duration < 5)
        {
            // update position on consumable
            AVPlayerItem* item = weakSelf.player.currentItem;
            
            CMTime duration = item.asset.duration;
            NSInteger dur = (duration.timescale != 0) ? duration.value/duration.timescale : 0;
            
            // add duration parameter to episode if there is none
            episode.duration = (int32_t)dur;
            [DMANAGER save];
        }
        // handle auto skip end
        /*NSInteger periodFeedEnd = [episode.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_end_period", episode.feed.uid]];
        NSInteger periodGeneralEnd =  [USER_DEFAULTS integerForKey:PlayerAutoSkipEndPeriod];
        NSInteger period = periodFeedEnd != 0 ? periodFeedEnd : periodGeneralEnd;
        if (period > 0) {
            AVPlayerItem* item = weakSelf.player.currentItem;
            CMTime duration = item.asset.duration;
            NSInteger dur = (duration.timescale != 0) ? duration.value/duration.timescale : 0;
            NSInteger currentTime = CMTimeGetSeconds(time);
            if (currentTime >= dur - period) {
                [weakSelf.player pause];
                [weakSelf close];
                
                _changingPosition = YES;
                episode.consumed = YES;
                episode.position = 0;
                
                [DMANAGER setEpisode:episode position:(double)dur];
                _changingPosition = NO;
                [DMANAGER save];
            }
        }*/
        
        // Handle auto skip end
        double periodFeedEnd = [episode.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_end_period", episode.feed.uid]];
        double periodGeneralEnd = [USER_DEFAULTS doubleForKey:PlayerAutoSkipEndPeriod];
        double skipEndPeriod = (periodFeedEnd != 0.0) ? periodFeedEnd : periodGeneralEnd;

        if (skipEndPeriod > 0.0 && !episode.consumed) {
            AVPlayerItem *item = weakSelf.player.currentItem;
            CMTime duration = item.asset.duration;

            // Only proceed if duration is valid and fully loaded
            if (CMTIME_IS_VALID(duration) && !CMTIME_IS_INDEFINITE(duration)) {
                double dur = CMTimeGetSeconds(duration);

                // Ensure duration is valid and greater than the skip period
                if (dur > skipEndPeriod) {
                    double currentTime = CMTimeGetSeconds(time);
                    double skipTriggerTime = dur - skipEndPeriod;

                    if (currentTime >= skipTriggerTime && currentTime < dur) {
                        [weakSelf.player pause];
                        [weakSelf close];

                        self->_changingPosition = YES;
                        if (!episode.consumed) {
                            [USER_DEFAULTS setInteger:[USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"] + 1 forKey:@"TotalEpisodesPlayedCount"];
                        }
                        episode.consumed = YES;
                        episode.position = 0;

                        [DMANAGER setEpisode:episode position:dur];
                        self->_changingPosition = NO;
                        [DMANAGER save];
                        // Remove consumed episode from Up Next playlist
                        [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
                    }
                }
            }
        }

        
        if (weakSelf.player.rate > 0)
        {
            __strong PlaybackManager* strongSelf = weakSelf;
            float targetRate = strongSelf->_playbackRate;
            if (targetRate <= 0) targetRate = [weakSelf rateFromSpeedControl:weakSelf.speedControl];
            if (fabs(weakSelf.player.rate - targetRate) > 0.02) {
                weakSelf.player.rate = targetRate;
            }

            NSInteger chapter = weakSelf.currentChapter;
            NSInteger artwork = weakSelf.currentArtwork;
            [weakSelf _findAndSetCurrentChapter:-1];
            [weakSelf _findAndSetCurrentArtwork];
            if (weakSelf.currentChapter > -1) {
                [weakSelf nextTimeAfterSkipChapter:episode];
            }
            
            if (weakSelf.currentChapter != chapter || weakSelf.currentArtwork != artwork) {
                [weakSelf _setNowPlayingInfoOfEpisode:episode];
            }
        }

        [weakSelf willChangeValueForKey:@"time"];
        [weakSelf didChangeValueForKey:@"time"];
        
        [weakSelf _sendUpdateNotification];
    }];
    
    
    self.positionObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(30,25000) queue:NULL usingBlock:^(CMTime time) {
        if (weakSelf.ready) {
            [weakSelf _temporarySavePosition];
        }
    }];
    
    [self.playingEpisode addTaskObserver:self forKeyPath:@"position" task:^(id obj, NSDictionary *change) {
        if (!weakSelf.changingPosition && weakSelf.paused) {
            [weakSelf seekToTime:weakSelf.playingEpisode.position];
        }
    }];

    self.state = InitializedState;
    
    SEND_UPDATE
}

- (NSString *)matchingSkipNameForChapter:(ICMetadataChapter *)chapterObj withNames:(NSArray *)skipNames {
    if (!chapterObj.title || skipNames.count == 0) {
        return nil;
    }
    NSString *lowerTitle = chapterObj.title.lowercaseString;
    for (NSString *skipName in skipNames) {
        if (skipName.length > 0 && [lowerTitle containsString:skipName.lowercaseString]) {
            return skipName;
        }
    }
    return nil;
}

- (void)nextTimeAfterSkipChapter:(CDEpisode *)episode {
    if (self.isAutoSkipping) return;
    if (!self.autoSkipMarkers || self.autoSkipMarkers.count == 0) return;
    if (self.lastAutoSkipDate && [[NSDate date] timeIntervalSinceDate:self.lastAutoSkipDate] < 1.0) return;

    NSTimeInterval currentTime = [self time];

    for (NSInteger i = 0; i < (NSInteger)self.autoSkipMarkers.count; i++) {
        NSDictionary *marker = self.autoSkipMarkers[i];
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];

        if (currentTime >= skipStart) {
            // Manual seek protection: don't re-skip if user deliberately seeked here
            if (i == self.suppressedSkipMarker) continue;

            if (resumeTime < 0) {
                // All remaining chapters are skip → finish episode
                [self _finishEpisodeDueToSkip:episode];
                return;
            }

            if (currentTime < resumeTime) {
                // We're in the skip zone → jump to resume point
                self.isAutoSkipping = YES;
                self.lastAutoSkipDate = [NSDate date];
                [self seekToTime:resumeTime tolerance:NO];
                self.isAutoSkipping = NO;
                return;
            }
            // currentTime >= resumeTime → already past this marker, check next
        }
    }
}

- (void)_finishEpisodeDueToSkip:(CDEpisode *)episode {
    self.isAutoSkipping = YES;
    AVPlayerItem *item = self.player.currentItem;
    CMTime duration = item.asset.duration;
    NSInteger dur = (duration.timescale != 0) ? duration.value / duration.timescale : 0;
    [self.player pause];
    [self close];
    _changingPosition = YES;
    if (!episode.consumed) {
        [USER_DEFAULTS setInteger:[USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"] + 1 forKey:@"TotalEpisodesPlayedCount"];
    }
    episode.consumed = YES;
    episode.position = 0;
    [DMANAGER setEpisode:episode position:(double)dur];
    _changingPosition = NO;
    [DMANAGER save];
    // Remove consumed episode from Up Next playlist
    [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
    self.isAutoSkipping = NO;
}


- (void) playerItemDidPlayToEndTimeNotification:(NSNotification*)notification
{
    CDEpisode* episode = self.playingEpisode;
    AudioSession* session = [AudioSession sharedAudioSession];

    // only mark episode as played if we actually finished playing this episode
    // could end prematurely if streaming and internet not available
    if (episode && [self time] > [self duration] - 10)
    {
        _changingPosition = YES;
        if (!episode.consumed) {
            [USER_DEFAULTS setInteger:[USER_DEFAULTS integerForKey:@"TotalEpisodesPlayedCount"] + 1 forKey:@"TotalEpisodesPlayedCount"];
        }
        episode.consumed = YES;
        episode.position = 0;
        _changingPosition = NO;

        [self _removeTemporarySavePosition];
        [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerEpisodeDidFinishNotification object:self];

        // Remove consumed episode from Up Next playlist
        [session eraseEpisodesFromUpNext:@[episode]];

        if ([episode.feed boolForKey:AutoDeleteAfterFinishedPlaying] && !episode.starred) {
            session.autoStopDisabled = YES;
            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:YES];
            session.autoStopDisabled = NO;
        }

        CDEpisode* nextEpisode = [session nextPlayableEpisode];
        if (nextEpisode) {
            self.inTransitionToNextTrack = YES;
            [session playEpisode:nextEpisode queueUpCurrent:NO at:0 autostart:YES];
        }
        else {
            [self closeAndSaveCurrentPosition:NO];
        }

        
#if TARGET_OS_IPHONE==0
        [[ICSharingManager sharedManager] triggerEvent:ICSharingServiceEpisodeDidEndPlaying object:episode];
#endif
    }

    else
    {
        [self closeAndSaveCurrentPosition:NO];
    }
}

- (void) _temporarySavePosition
{
    if (!self.paused)
    {
        CDEpisode* episode = self.playingEpisode;
        NSString* key = self.playingEpisode.objectHash;
        
        NSMutableDictionary* playbackPositions = [[USER_DEFAULTS objectForKey:kDefaultTemporaryPlaybackPositions] mutableCopy];
        if (!playbackPositions) {
            playbackPositions = [[NSMutableDictionary alloc] init];
        }
        
        // update position on consumable
        AVPlayerItem* item = self.player.currentItem;
        if (item && episode && key) {
            CMTime current = [item currentTime];
            NSInteger cur = current.value/current.timescale;
            
            [playbackPositions setObject:@(cur) forKey:key];
            [USER_DEFAULTS setObject:playbackPositions forKey:kDefaultTemporaryPlaybackPositions];
        }
    }
}

- (void) _removeTemporarySavePosition
{
    NSString* key = self.playingEpisode.objectHash;
    
    NSMutableDictionary* playbackPositions = [[USER_DEFAULTS objectForKey:kDefaultTemporaryPlaybackPositions] mutableCopy];
    [playbackPositions removeObjectForKey:key];
    [USER_DEFAULTS setObject:playbackPositions forKey:kDefaultTemporaryPlaybackPositions];
}

- (void) _saveCurrentPlaybackPosition
{
    CDEpisode* episode = self.playingEpisode;
    
    // update position on consumable
    AVPlayerItem* item = self.player.currentItem;
    if (item && episode) {
        CMTime current = [item currentTime];
        NSInteger cur = current.value/current.timescale;        

        _changingPosition = YES;
        [DMANAGER setEpisode:episode position:(double)cur];
        _changingPosition = NO;
        [DMANAGER save];//DevD to do
        
        [self _removeTemporarySavePosition];
    }
}

- (void) restart
{
	CDEpisode* episode = self.playingEpisode;
	
	self.changingEpisode = YES;
    [self openWithEpisode:episode at:0 autostart:YES];
}

- (void) close
{
    [self closeAndSaveCurrentPosition:YES];
}

- (void) closeAndSaveCurrentPosition:(BOOL)saveCurrentPosition
{
	// stop the skipping thing in case the user holds down the buttons until the end
    self.ready = NO;

    // Reset chapter skip protection
    self.isAutoSkipping = NO;
    self.lastAutoSkipDate = nil;
    self.autoSkipMarkers = nil;
    self.suppressedSkipMarker = -1;

	[self.controlTimer invalidate];
	self.controlTimer = nil;
	
	[self.mediaAsset cancelLoading];
	self.mediaAsset = nil;
	
    if (!self.changingEpisode) {
        [self _endNextItemHandover];
    }
	
	if (self.player)
	{
        if (saveCurrentPosition) {
            [self _saveCurrentPlaybackPosition];
        }
        
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem];
        
        
        if (self.player.rate > 0) {
			[self.player pause];
		}
        
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"status"];
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"playbackBufferFull"];
        [self.player.currentItem removeTaskObserver:self forKeyPath:@"loadedTimeRanges"];
        [self.player removeTaskObserver:self forKeyPath:@"rate"];

		if (self.playbackObserver) { 
			[self.player removeTimeObserver:self.playbackObserver]; 
			self.playbackObserver = nil;
		}
        
        if (self.positionObserver) {
            [self.player removeTimeObserver:self.positionObserver];
            self.positionObserver = nil;
        }
        
        [self.playingEpisode removeTaskObserver:self forKeyPath:@"position"];
		
		[self.playerView removeFromSuperview];
		self.playerView = nil;
		
		//_state = IdleState;
		self.ready = NO;
        
		self.chapters = nil;
        if (_chapterTimesIdx) {
            free(_chapterTimesIdx);
            _chapterTimesIdx = NULL;
        }
        
        self.artworks = nil;
        if (_artworkTimesIdx) {
            free(_artworkTimesIdx);
            _artworkTimesIdx = nil;
        }
		
		self.player = nil;
        [self _setupRemotePlaybackCenterWithEpisode:nil];
	}
    
    if (!self.changingEpisode && self.playingEpisode) {
        self.playingEpisode = nil;
        [[AudioSession sharedAudioSession] clear];
        [[NSNotificationCenter defaultCenter] postNotificationName:PlaybackManagerDidEndNotification object:self];
    }
}

+ (NSSet*) keyPathsForValuesAffectingVolume {
    return [NSSet setWithObject:@"ready"];
}

- (float) volume
{
    return [USER_DEFAULTS floatForKey:kDefaultPlaybackVolume];
}

- (void) setVolume:(float)volume
{
    if (_volume != volume) {
        _volume = volume;

        self.player.volume = volume;
        [USER_DEFAULTS setFloat:volume forKey:kDefaultPlaybackVolume];
    }
}

+ (NSSet*) keyPathsForValuesAffectingWaitingForLoad {
    return [NSSet setWithObject:@"state"];
}


- (BOOL) isWaitingForLoad {
    return (self.state == ShouldRunState);
}

+ (NSSet*) keyPathsForValuesAffectingPaused {
    return [NSSet setWithObjects:@"state", @"player.rate", nil];
}

- (BOOL) isPaused
{
    if (self.state == ShouldRunState) {
        return NO;
    }
    
	return (self.player.rate == 0 && self.state != InitializedState);
}

- (BOOL) isPodcastPlaying
{
    float rate = self.player.rate;
    if (rate > 0)
    {
        return YES;
    }
    else
    {
        return NO;
    }
}

- (void) play
{
	// rewind 30 seconds if we paused more than 10 mins
	if (self.lastPauseDate)
	{
		if ([USER_DEFAULTS boolForKey:PlayerReplayAfterPause] && [[NSDate date] timeIntervalSinceDate:self.lastPauseDate] > 600)
		{
			CMTime current = [self.player.currentItem currentTime];
			NSInteger cur = current.value/current.timescale;
			NSTimeInterval next = MAX(cur-30, 0);
			[self seekToTime:next];
		}
		self.lastPauseDate = nil;
	}
	
	float targetRate = _playbackRate > 0 ? _playbackRate : [self rateFromSpeedControl:self.speedControl];
	self.player.rate = targetRate;

    self.playStartDate = [NSDate date];
	SEND_UPDATE
}

- (void) pause
{
    if (!self.paused)
    {
        [self.player pause];
        self.lastPauseDate = [NSDate date];

        // Track cumulative listening time
        if (self.playStartDate) {
            NSTimeInterval delta = [self.lastPauseDate timeIntervalSinceDate:self.playStartDate];
            if (delta > 0) {
                double total = [USER_DEFAULTS doubleForKey:@"TotalListeningTime"];
                [USER_DEFAULTS setDouble:total + delta forKey:@"TotalListeningTime"];
            }
            self.playStartDate = nil;
        }

        // prevent starting auto-playback when playthrough available
        self.state = RunningState;

        [self _saveCurrentPlaybackPosition];
        SEND_UPDATE
    }
}

- (void) playPause
{
    if (self.paused) {
        [self play];
        [self updateNowPlayingInfo];
    } else {
        [self pause];
    }
}

- (void) seekToTime:(NSTimeInterval)time
{
	[self seekToTime:time tolerance:YES];
}

// If time falls inside a skip zone, return one full skip-back duration before the zone start.
- (NSTimeInterval)_adjustTimeBeforeSkipZone:(NSTimeInterval)time {
    if (!self.autoSkipMarkers) return time;
    for (NSDictionary *marker in self.autoSkipMarkers) {
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];
        if (resumeTime > 0 && time >= skipStart && time < resumeTime) {
            NSInteger skipPeriod = [self.playingEpisode.feed integerForKey:PlayerSkipBackPeriod];
            return MAX(skipStart - skipPeriod, 0);
        }
    }
    return time;
}

// If time falls inside a skip zone, return the resume point after the zone (for forward seek).
- (NSTimeInterval)_adjustTimeAfterSkipZone:(NSTimeInterval)time {
    if (!self.autoSkipMarkers) return time;
    for (NSDictionary *marker in self.autoSkipMarkers) {
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];
        if (resumeTime > 0 && time >= skipStart && time < resumeTime) {
            return resumeTime;
        }
    }
    return time;
}

- (void)_suppressAutoSkipMarkerAtTime:(NSTimeInterval)time {
    if (!self.autoSkipMarkers) return;
    self.suppressedSkipMarker = -1;
    for (NSInteger i = 0; i < (NSInteger)self.autoSkipMarkers.count; i++) {
        NSDictionary *marker = self.autoSkipMarkers[i];
        NSTimeInterval skipStart = [marker[@"start"] doubleValue];
        NSTimeInterval resumeTime = [marker[@"resume"] doubleValue];
        if (resumeTime > 0 && time >= skipStart && time < resumeTime) {
            self.suppressedSkipMarker = i;
            break;
        }
    }
}

- (void) seekToTime:(NSTimeInterval)time tolerance:(BOOL)tolerance
{
	CMTime current = CMTimeMake((int64_t)(time*1000), 1000);
    void (^finishSeekUpdate)(BOOL) = ^(BOOL finished) {
        if (!finished) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self _findAndSetCurrentChapter:-1];
            [self _findAndSetCurrentArtwork];
            [self coalescedPerformSelector:@selector(_setNowPlayingInfoOfEpisode:) object:self.playingEpisode afterDelay:1.0];
            SEND_UPDATE

            if (self.paused && !self.seeking) {
                [self _saveCurrentPlaybackPosition];
            }
        });
    };

    // Suppress auto-skip marker is handled by callers that represent deliberate position
    // choices (setPosition:, seekToChapter:) — NOT here, so skip buttons still trigger auto-skip
    if (!tolerance) {
        [self.player seekToTime:current
                toleranceBefore:CMTimeMake(0, 1000)
                 toleranceAfter:CMTimeMake(1000, 1000)
              completionHandler:finishSeekUpdate];
    } else {
        [self.player seekToTime:current completionHandler:finishSeekUpdate];
    }
}

- (void) seekToChapter:(ICMetadataChapter*)chapter
{
    // fix chapter display for 5 seconds due to seeking fuzzyness
    self.seekingChapter = chapter;
    
    [self perform:^(id sender) {
        self.seekingChapter = nil;
        [self _findAndSetCurrentChapter:-1];
    } afterDelay:5.0];
    
    NSTimeInterval time = CMTimeGetSeconds(chapter.start);
    [self _suppressAutoSkipMarkerAtTime:time];
    [self seekToTime:time tolerance:NO];
}

- (NSTimeInterval) _scrubbTime
{
	NSTimeInterval t = [[NSDate date] timeIntervalSinceDate:self.controlStartDate];
	if (t < 1) {
		return 1.0f;
	}
	else if (t < 2) {
		return 2.0f;
	}
	else if (t < 3) {
		return 5.0f;
	}
	else if (t < 4) {
		return 10.0f;
	}
	else if (t < 5) {
		return 15.0f;
	}
	else if (t < 6) {
		return 30.0f;
	}
	else if (t < 7) {
		return 60.0f;
	}
	else if (t < 8) {
		return 120.0f;
	}
	
	return 240.0f;
}

- (void) _scrubb:(NSTimeInterval)time
{
	NSInteger cur = self.time;
	NSInteger dur = self.duration;
	
	NSTimeInterval t = MIN(MAX(cur+time,0),dur);
	[self seekToTime:t];
}


- (void) _backwardScrubb:(NSTimer*)timer
{
	NSTimeInterval scrubTime = [self _scrubbTime];
	[self _scrubb:-scrubTime];
}

- (void) _forwardScrubb:(NSTimer*)timer
{
	NSTimeInterval scrubTime = [self _scrubbTime];
	[self _scrubb:scrubTime];
}


- (void) beginSeekingBackward
{
    self.seeking = YES;
	[self.controlTimer invalidate];
	self.controlTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_backwardScrubb:) userInfo:nil repeats:YES];
	self.controlStartDate = [NSDate date];
}

- (void) beginSeekingForward
{
    self.seeking = YES;
	[self.controlTimer invalidate];
	self.controlTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_forwardScrubb:) userInfo:nil repeats:YES];
	self.controlStartDate = [NSDate date];
}

- (void) endSeeking
{
	[self.controlTimer invalidate];
	self.controlTimer = nil;
	self.controlStartDate = nil;
    self.seeking = NO;
    
    if (self.paused) {
        [self _saveCurrentPlaybackPosition];
    }
}

- (void) seekForward
{
    CDFeed* feed = self.playingEpisode.feed;
    
	NSInteger skipPeriod = [feed integerForKey:PlayerSkipForwardPeriod];
	
	NSInteger cur = self.time;
	NSInteger dur = self.duration;
	
	NSInteger next = MIN(dur-1,cur + skipPeriod);
	if (next < dur) {
		[self seekToTime:[self _adjustTimeAfterSkipZone:next]];
	}
}

- (void) seekBackward
{
    CDFeed* feed = self.playingEpisode.feed;

	NSInteger skipPeriod = [feed integerForKey:PlayerSkipBackPeriod];
	NSTimeInterval cur = self.time;
	NSInteger next = MAX(cur - skipPeriod,0);
    if (cur > 2) {
        [self seekToTime:[self _adjustTimeBeforeSkipZone:next]];
    }
}


- (void) rewind30Seconds
{
	NSTimeInterval cur = self.time;
	NSInteger next = MAX(cur - 30, 0);
	[self seekToTime:[self _adjustTimeBeforeSkipZone:next]];
}

- (BOOL) hasPlaylist
{
    return ([[AudioSession sharedAudioSession].playlist count] > 1);
}

- (void) nextTrack
{
    CDEpisode* episode = self.playingEpisode;
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    NSInteger index = [playlist indexOfObject:episode];

    if ([playlist count] < 1 || index == NSNotFound) {
        return;
    }

    CDEpisode* nextEpisode = nil;

    // if not last item, play next item
    if (index < [playlist count]-1) {
        nextEpisode = [playlist objectAtIndex:index+1];
    }
    // if last item, play the first item
    else {
        nextEpisode = [playlist objectAtIndex:0];
    }

    if (nextEpisode) {
        [[AudioSession sharedAudioSession] playEpisode:nextEpisode];
    }
}

- (void) previousTrack
{
    CDEpisode* episode = self.playingEpisode;
    NSArray* playlist = [AudioSession sharedAudioSession].playlist;
    NSInteger index = [playlist indexOfObject:episode];

    if ([playlist count] == 0 || index == NSNotFound) {
        return;
    }

    CDEpisode* previousEpisode = nil;

    // if not first item, play previous item
    if (index > 0) {
        previousEpisode = [playlist objectAtIndex:index-1];
    }
    // if first item, play last item
    else {
        previousEpisode = [playlist lastObject];
    }

    if (previousEpisode) {
        [[AudioSession sharedAudioSession] playEpisode:previousEpisode];
    }
}

- (void) nextChapter
{
    if (self.currentChapter < [self.chapters count]-1)
    {
        ICMetadataChapter* nextChapter = [self.chapters objectAtIndex:self.currentChapter+1];
        NSTimeInterval time = (NSTimeInterval)CMTimeGetSeconds(nextChapter.start);
        
        [self seekToTime:time tolerance:NO];
    }
}

- (void) previousChapter
{
    if (self.currentChapter > 0)
    {
        ICMetadataChapter* previousChapter = [self.chapters objectAtIndex:self.currentChapter-1];
        NSTimeInterval time = (NSTimeInterval)CMTimeGetSeconds(previousChapter.start);

        [self seekToTime:time tolerance:NO];
    }
}

- (float)rateFromSpeedControl:(PlaybackSpeedControl)control
{
    switch (control) {
        case PlaybackSpeedControlMinusHalfSpeed:    return 0.5f;
        case PlaybackSpeedControlThreeQuarterSpeed: return 0.75f;
        case PlaybackSpeedControlNormalSpeed:        return 1.0f;
        case PlaybackSpeedControlFaster11:           return 1.1f;
        case PlaybackSpeedControlFaster12:           return 1.2f;
        case PlaybackSpeedControlFaster125:          return 1.25f;
        case PlaybackSpeedControlFaster13:           return 1.3f;
        case PlaybackSpeedControlPlusHalfSpeed:      return 1.5f;
        case PlaybackSpeedControlDoubleSpeed:        return 2.0f;
        case PlaybackSpeedControlTripleSpeed:        return 3.0f;
        default:                                     return 1.0f;
    }
}

- (void)setPlaybackRate:(float)rate
{
    rate = MAX(0.5f, MIN(3.0f, rate));
    _playbackRate = rate;
    if (self.player.rate > 0) {
        self.player.rate = rate;
    }
}

- (void) setSpeedControl:(PlaybackSpeedControl)_speed
{
	if (_speedControl != _speed) {
		_speedControl = _speed;
		_playbackRate = [self rateFromSpeedControl:_speed];

        [USER_DEFAULTS setInteger:_speed forKey:DefaultPlaybackSpeed];

		if (self.player.rate > 0) {
            self.player.rate = _playbackRate;
        }

		SEND_UPDATE
	}
}

- (void) updateForSpeedControlSettingsChanged
{
    CDFeed* feed = self.playingEpisode.feed;
    _speedControl = [feed integerForKey:DefaultPlaybackSpeed];
    _playbackRate = [self rateFromSpeedControl:_speedControl];

    if (self.player.rate > 0) {
        self.player.rate = _playbackRate;
    }
}

+ (NSSet*) keyPathsForValuesAffectingPosition
{
    return [NSSet setWithObjects:@"time", @"duration", @"ready", nil];
}

- (double) position
{
    if (self.seekingPositionChangeDate && [self.seekingPositionChangeDate timeIntervalSinceNow] > -1) {
        return self.seekingPosition;
    }
    
    return (self.duration > 0) ? self.time / self.duration : 0;
}

- (void) setPosition:(double)position
{
	NSTimeInterval time = [self duration]*position;
	[self _suppressAutoSkipMarkerAtTime:time];
	[self seekToTime:time];
    
    self.seekingPosition = position;
    self.seekingPositionChangeDate = [NSDate date];
}

+ (NSSet*) keyPathsForValuesAffectingPlayablePosition
{
    return [NSSet setWithObjects:@"playableDuration", @"duration", nil];
}

- (double) playablePosition
{
    return (self.duration > 0) ? self.playableDuration / self.duration : 0;
}

- (NSTimeInterval) time
{
	AVPlayerItem* item = self.player.currentItem;
	CMTime current = [item currentTime];
	NSTimeInterval time = (current.timescale > 0) ? (NSTimeInterval)current.value/(NSTimeInterval)current.timescale : 0;
    return MIN(time, self.duration);
}

- (NSTimeInterval) duration
{
	AVPlayerItem* item = self.player.currentItem;
    AVAsset* asset = item.asset;
    
    AVKeyValueStatus status = [asset statusOfValueForKey:@"duration" error:nil];
    if (status == AVKeyValueStatusLoaded) {
        CMTime duration = item.asset.duration;
        NSTimeInterval dur = (duration.timescale > 0) ? (NSTimeInterval)duration.value/(NSTimeInterval)duration.timescale : 0;
        return floorf(dur);
    }
    
    return 0;
}

- (NSTimeInterval) playableDuration
{
	if (!self.player.currentItem) {
		return 0.0f;
	}
	
	AVPlayerItem* item = self.player.currentItem;
	CMTimeRange loadRange = [[item.loadedTimeRanges lastObject] CMTimeRangeValue];
	NSTimeInterval dur =  (NSTimeInterval)((double)loadRange.start.value / (double)loadRange.start.timescale + (double)loadRange.duration.value / (double)loadRange.duration.timescale);
    return floorf(dur);
}

- (void) stopAirPlayVideo
{
#if TARGET_OS_IPHONE
	if ([self.player respondsToSelector:@selector(allowsAirPlayVideo)]) {
		self.player.allowsExternalPlayback = NO;
	}
#endif
}

- (BOOL) isAirPlayVideoActive
{
#if TARGET_OS_IPHONE
	if ([self.player respondsToSelector:@selector(isAirPlayVideoActive)]) {
		return [self.player isExternalPlaybackActive];
	}
#endif
    return NO;
}

#pragma mark -

- (void) _findAndSetCurrentChapter:(NSTimeInterval)time
{
    if (self.seekingChapter) {
        NSUInteger idx = [self.chapters indexOfObject:self.seekingChapter];
        if (idx != NSNotFound) {
            self.currentChapter = idx;
            return;
        }
    }
    
	if (!_chapterTimesIdx) {
		return;
	}
	
    if (time < 0) {
        time = self.time;
    }
    
    //DebugLog(@"time %f",time);
	
	NSInteger i;
	NSInteger c = -1;
	
	for(i=0; i<[self.chapters count]; i++)
	{
		if (time >= _chapterTimesIdx[i]) {
			c = i;
		} else {
			break;
		}
	}
	
    if (self.currentChapter != c) {
        self.currentChapter = c;
    }
}

- (void) _findAndSetCurrentArtwork
{
	if (!_artworkTimesIdx) {
		return;
	}
	
	NSTimeInterval time = self.time;
	
	NSInteger i;
	NSInteger c = -1;
	
	for(i=0; i<[self.artworks count]; i++)
	{
		if (time >= _artworkTimesIdx[i]) {
			c = i;
		} else {
			break;
		}
	}
	
    if (self.currentArtwork != c) {
        self.currentArtwork = c;
    }
}

#pragma mark -
#pragma mark Chapter Support

- (void) _startLoadingChapters
{

    ICMetadataParser* parser = [[ICMetadataParser alloc] initWithAsset:self.mediaAsset];
    [parser loadAsynchronouslyWithCompletionHandler:^(BOOL success, NSError *error) {
        
        NSArray* chapters = parser.metadataAsset.chapters;
        
        // create chapter index for fast chapter search
        _chapterTimesIdx = (float*)malloc(sizeof(float)*[chapters count]);
        [chapters enumerateObjectsUsingBlock:^(ICMetadataChapter* chapter, NSUInteger idx, BOOL *stop) {
            _chapterTimesIdx[idx] = (float)CMTimeGetSeconds(chapter.start);
        }];
        
        self.chapters = chapters;
        [self _findAndSetCurrentChapter:-1];
        [self _computeAutoSkipMarkers];


        NSArray* images = parser.metadataAsset.images;

        _artworkTimesIdx = (float*)malloc(sizeof(float)*[images count]);
        [images enumerateObjectsUsingBlock:^(ICMetadataImage* image, NSUInteger idx, BOOL *stop) {
            _artworkTimesIdx[idx] = (float)CMTimeGetSeconds(image.start);
        }];
        
        self.artworks = images;
        [self _findAndSetCurrentArtwork];
        
        [self _setNowPlayingInfoOfEpisode:self.playingEpisode];
        [self _sendUpdateNotification];
    }];
}

- (void)_computeAutoSkipMarkers {
    CDEpisode *episode = self.playingEpisode;
    if (!episode || !self.chapters || self.chapters.count == 0) {
        self.autoSkipMarkers = nil;
        return;
    }

    // Get skip keywords
    NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", episode.feed.uid];
    NSString *chaptersName = [episode.feed stringForKey:key];
    if (!chaptersName || chaptersName.length == 0) {
        self.autoSkipMarkers = nil;
        return;
    }
    NSArray *skipNames = [chaptersName componentsSeparatedByString:@".  "];
    if (skipNames.count == 0) {
        self.autoSkipMarkers = nil;
        return;
    }

    NSMutableArray *markers = [NSMutableArray array];
    NSInteger chapterCount = self.chapters.count;
    NSInteger i = 0;

    while (i < chapterCount) {
        ICMetadataChapter *chapter = self.chapters[i];
        NSString *skipName = [self matchingSkipNameForChapter:chapter withNames:skipNames];

        if (!skipName) {
            // Check if next chapter is a skip chapter with negative startOffset → early skip from this chapter
            if (i + 1 < chapterCount) {
                ICMetadataChapter *nextChapter = self.chapters[i + 1];
                NSString *nextSkipName = [self matchingSkipNameForChapter:nextChapter withNames:skipNames];
                if (nextSkipName) {
                    NSString *startKey = [NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", episode.feed.uid, nextSkipName];
                    double startOffset = [episode.feed doubleForKey:startKey];
                    if (startOffset < 0) {
                        // Negative startOffset: skip starts before the skip chapter boundary
                        // Don't advance i here — the next iteration will handle the skip chapter group
                        // Just note: the group starting at i+1 will use this negative offset
                    }
                }
            }
            i++;
            continue;
        }

        // Found a skip chapter — start of a skip group
        NSString *firstSkipName = skipName;
        NSInteger groupStart = i;
        NSString *lastSkipName = skipName;
        NSInteger groupEnd = i; // inclusive

        // Find consecutive skip chapters
        NSInteger j = i + 1;
        while (j < chapterCount) {
            ICMetadataChapter *nextChap = self.chapters[j];
            NSString *nextName = [self matchingSkipNameForChapter:nextChap withNames:skipNames];
            if (!nextName) break;
            lastSkipName = nextName;
            groupEnd = j;
            j++;
        }

        // Calculate skipStart: first skip chapter start + startOffset
        ICMetadataChapter *firstSkipChapter = self.chapters[groupStart];
        NSTimeInterval firstSkipChapterStart = CMTimeGetSeconds(firstSkipChapter.start);

        NSString *startKey = [NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", episode.feed.uid, firstSkipName];
        double startOffset = [episode.feed doubleForKey:startKey];

        NSTimeInterval skipStart;
        if (startOffset < 0) {
            // Negative: skip starts before the skip chapter (in the previous chapter)
            skipStart = firstSkipChapterStart + startOffset;
        } else {
            // Positive or zero: skip starts within/at the skip chapter
            skipStart = firstSkipChapterStart + startOffset;
        }
        skipStart = MAX(0, skipStart);

        // Calculate resumeTime
        NSTimeInterval resumeTime;
        if (j >= chapterCount) {
            // All remaining chapters are skip → finish episode
            resumeTime = -1;
        } else {
            // Resume at end of last skip chapter (= start of next non-skip chapter)
            ICMetadataChapter *lastSkipChapter = self.chapters[groupEnd];
            NSTimeInterval lastSkipChapterEnd = CMTimeGetSeconds(lastSkipChapter.end);

            NSString *endKey = [NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", episode.feed.uid, lastSkipName];
            double endOffset = [episode.feed doubleForKey:endKey];

            resumeTime = lastSkipChapterEnd + endOffset;

            // Clamp: resume must not go before start of last skip chapter
            NSTimeInterval lastSkipChapterStart = CMTimeGetSeconds(lastSkipChapter.start);
            resumeTime = MAX(resumeTime, lastSkipChapterStart);

            // Clamp: resume must be after skipStart
            resumeTime = MAX(resumeTime, skipStart + 1.0);
        }

        [markers addObject:@{@"start": @(skipStart), @"resume": @(resumeTime)}];

        // Advance past the skip group
        i = j;
    }

    self.autoSkipMarkers = (markers.count > 0) ? [markers copy] : nil;
    self.suppressedSkipMarker = -1;
}


#pragma mark - Audio Output


#if !TARGET_OS_IPHONE

- (void) setAudioEndpoint:(ICAudioEndpoint *)audioEndpoint
{
    if (_audioEndpoint != audioEndpoint) {
        _audioEndpoint = audioEndpoint;

#if ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR == 1
        if ([NSBundle systemVersion] >= VM_SYSTEM_VERSION_OS_X_10_9 && [AVPlayer implementsSelector:@selector(audioOutputDeviceUniqueID)]) {
            [PlaybackManager setDataSourceOfAudioDeviceForEndpoint:audioEndpoint];
            self.player.audioOutputDeviceUniqueID = audioEndpoint.UID;
            return;
        }
#endif

        [PlaybackManager setAudioEndpointToCurrentSystemOutput:audioEndpoint];
    }
}

- (void) _handleChangeOfCurrentSystemAudioOutputDevice
{
#if ENABLE_10_9_AUDIO_DEVICE_BEHAVIOR == 1
    if ([NSBundle systemVersion] >= VM_SYSTEM_VERSION_OS_X_10_9 && [AVPlayer implementsSelector:@selector(audioOutputDeviceUniqueID)]) {
        return;
    }
#endif
    [self _setAudioEndpointToCurrentSystemAudioDevice];
}

- (void) _setAudioEndpointToCurrentSystemAudioDevice
{
    for (ICAudioEndpoint* endpoint in [PlaybackManager audioOutputEndpoints]) {
        if ([PlaybackManager audioEndpointIsCurrentSystemOutput:endpoint]) {
            [self willChangeValueForKey:@"audioEndpoint"];
            _audioEndpoint = endpoint;
            [self didChangeValueForKey:@"audioEndpoint"];
        }
    }
}

#endif
@end
