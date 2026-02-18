//
//  AudioSession.m
//  Instacast
//
//  Created by Martin Hering on 19.07.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MPNowPlayingInfoCenter.h>
#if !TARGET_OS_MACCATALYST
#import <CarPlay/CarPlay.h>
#endif

#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"

#import "ICMetadata.h"
#import "CDFeed+Helper.h"
#import <MediaPlayer/MediaPlayer.h>

static NSString* kPlaybackStateEpisode = @"PlaybackEpisode";
static NSString* kPlaybackStatePlaylist = @"PlaybackPlaylist";

NSString* AudioSessionAudioRouteDidChangeNotification = @"AudioSessionAudioRouteDidChangeNotification";
NSString* AudioSessionDidRestorePlaybackNotification = @"AudioSessionDidRestorePlaybackNotification";

@interface AudioSession () <AVAudioSessionDelegate>
@property (nonatomic, readwrite, strong) CDEpisode* episode;

- (void) _savePlaybackStateInUserDefaults;
- (void) _restorePlaybackStateFromUserDefaults;

@property (nonatomic, strong) NSTimer* playbackTimer;
@property (nonatomic, strong) NSDate* stopDate;
@property BOOL playerWasPlayingBeforeWentToBackground;
@property BOOL continuousPlaybackTemporarilyDisabled;
@property BOOL autoStopDisabled;

// Silent audio playback to keep app alive when paused in background
@property (nonatomic, strong) AVPlayer* silentPlayer;
@property (nonatomic, strong) id silentPlayerLoopObserver;
@end


@implementation AudioSession


#pragma mark -

+ (AudioSession*) sharedAudioSession
{
	static AudioSession* gSharedAudioSession = nil;
	
	if (!gSharedAudioSession) {
		gSharedAudioSession = [self alloc];
		gSharedAudioSession = [gSharedAudioSession init];
	}
	return gSharedAudioSession;
}

- (id) init
{
	if ((self = [super init]))
	{
        AVAudioSession* session = [AVAudioSession sharedInstance];

        NSError* categoryError = nil;
        if (![session setCategory:AVAudioSessionCategoryPlayback withOptions:0 error:&categoryError]) {
            ErrLog(@"error setting audio category: %@", categoryError);
        }

        //dispatch_async(dispatch_get_main_queue(), ^{
            [self _restorePlaybackStateFromUserDefaults];
        //});

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillResignActiveNotification:)
                                                     name:UIApplicationWillResignActiveNotification
                                                   object:App];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackgroundNotification:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:App];

        [self _observeAudioSessionForChanges];
        [self _observePlaybackForStoringChapters];
        [self _observeEpisodeCacheBeingDeleted];
	}

	return self;
}

- (void) resetSession
{
    AVAudioSession* session = [AVAudioSession sharedInstance];
    
    NSError* categoryError = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback withOptions:0 error:&categoryError]) {
        ErrLog(@"error setting audio category: %@", categoryError);
    }
}

- (void) _updateAudioSessionCategory
{
    AVAudioSession* session = [AVAudioSession sharedInstance];
    if (![PlaybackManager playbackManager].playingEpisode) {
        [self perform:^(id sender) {
            NSError* error;
            [session setActive:NO error:&error];
            if (error) {
                ErrLog(@"error deactivating audio session %@", error);
            }
        } afterDelay:1.0];

    }
    else
    {
        NSError* error;
        [session setActive:YES error:&error];

        if (error) {
            ErrLog(@"error (activating audio session %@", error);
        }
    }
    
    
}

- (BOOL)_isCarPlaySceneConnected
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

- (BOOL)_shouldDisableSleepTimerForCarPlay
{
    return [USER_DEFAULTS boolForKey:DisableSleepTimerInCarPlay] && [self _isCarPlaySceneConnected];
}

// XXX Hack to keep video playing in background
- (void)applicationWillResignActiveNotification:(UIApplication *)application
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    self.playerWasPlayingBeforeWentToBackground = (!pman.paused);
}

-(void)resumePlayback
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    if (self.playerWasPlayingBeforeWentToBackground && pman.paused) {
        [pman play];
        [self updateNowPlayingInfo];
    }
}
- (void)applicationDidEnterBackgroundNotification:(UIApplication *)application
{
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(resumePlayback) userInfo:nil repeats:NO];
}


- (void) _observeEpisodeCacheBeingDeleted
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(_handleEpisodeCacheCleared:)
                                                 name:CacheManagerDidClearCacheNotification
                                               object:nil];
}

- (void) _handleEpisodeCacheCleared:(NSNotification*)note
{
    if (!self.autoStopDisabled && [self.episode isEqual:note.userInfo[@"episode"]]) {
        [self stop];
    }
}

- (void) _observeAudioSessionForChanges
{
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    
    // AVAudioSessionInterruptionNotification
    [nc addObserver:self selector:@selector(audioSessionInterruptionNotification:) name:AVAudioSessionInterruptionNotification object:nil];
    [nc addObserver:self selector:@selector(audioSessionRouteChangeNotification:) name:AVAudioSessionRouteChangeNotification object:nil];
}

- (void) audioSessionInterruptionNotification:(NSNotification*)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        PlaybackManager* pman = [PlaybackManager playbackManager];
        
        NSDictionary* userInfo = [notification userInfo];
        NSInteger interruptionType = [userInfo[AVAudioSessionInterruptionTypeKey] integerValue];
        NSInteger option = [userInfo[AVAudioSessionInterruptionOptionKey] integerValue];
        
        DebugLog(@"userInfo: %@", userInfo);
        
        BOOL wasPlaying = pman.hasBeenPlayingWhenInterrupted;
        
        if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
            pman.hasBeenPlayingWhenInterrupted = !pman.paused;
            [pman pause];
        }
        else if (interruptionType == AVAudioSessionInterruptionTypeEnded && wasPlaying) {
            if (option == AVAudioSessionInterruptionOptionShouldResume) {
                [pman play];
                [self updateNowPlayingInfo];
            }
        }
    });
}

- (void)updateNowPlayingInfo {
    /*MPNowPlayingInfoCenter *nowPlayingInfoCenter = [MPNowPlayingInfoCenter defaultCenter];
    NSDictionary *nowPlayingInfo = @{
        MPMediaItemPropertyTitle: self.episode.title,
        MPMediaItemPropertyArtist: self.episode.author,
        MPMediaItemPropertyPlaybackDuration: @(self.episode.duration), // total duration in seconds
        MPNowPlayingInfoPropertyElapsedPlaybackTime: @(self.episode.position) // current time in seconds
    };
    nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo;*/
}

- (void) audioSessionRouteChangeNotification:(NSNotification*)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        PlaybackManager* pman = [PlaybackManager playbackManager];
        
        NSDictionary* userInfo = [notification userInfo];
        DebugLog(@"userInfo: %@", userInfo);
        
        [self willChangeValueForKey:@"airPlayActive"];
        [self didChangeValueForKey:@"airPlayActive"];
        
        [self willChangeValueForKey:@"headphonesAttached"];
        [self didChangeValueForKey:@"headphonesAttached"];
        
        
        AVAudioSessionRouteChangeReason reason = [userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
        
        if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
            [pman pause];
            [pman setHasBeenPlayingWhenInterrupted:NO];
        }
        
        else if (reason == AVAudioSessionRouteChangeReasonCategoryChange) {
            [self resetSession];
        }
        
        [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionAudioRouteDidChangeNotification object:self];
    });
}


- (void) _observePlaybackForStoringChapters
{
    [[PlaybackManager playbackManager] addTaskObserver:self forKeyPath:@"chapters" task:^(id obj, NSDictionary *change) {
        PlaybackManager* pman = [PlaybackManager playbackManager];
        
        NSSet* storedChapters = [pman.playingEpisode chapters];
        
        if (pman.chapters > 0 && [storedChapters count] == 0)
        {
            [pman.chapters enumerateObjectsUsingBlock:^(ICMetadataChapter* chapter, NSUInteger idx, BOOL *stop) {
                
                CDChapter* ch = [NSEntityDescription insertNewObjectForEntityForName:@"Chapter" inManagedObjectContext:DMANAGER.objectContext];
                ch.index = (int32_t)idx;
                ch.title = chapter.title;
                ch.timecode = (double)CMTimeGetSeconds(chapter.start);
                ch.duration = [chapter durationWithTrackDuration:pman.duration];
                ch.linkURL = chapter.link;
                [pman.playingEpisode addChaptersObject:ch];
                
            }];
            
            [DMANAGER save];
        }
    }];
    
    [[PlaybackManager playbackManager] addTaskObserver:self forKeyPath:@"playingEpisode" task:^(id obj, NSDictionary *change) {
        [self _updateAudioSessionCategory];
    }];
}

#pragma mark -


- (CDEpisode*) nextPlayableEpisode
{
    if (self.continuousPlaybackTemporarilyDisabled) {
        return nil;
    }

	BOOL canStartEpisode = YES;

    // Find the next episode after the current one in the playlist
    CDEpisode* anEpisode = nil;
    NSArray* currentPlaylist = [self playlist];

    if (self.episode && [currentPlaylist count] > 0) {
        NSUInteger currentIndex = [currentPlaylist indexOfObject:self.episode];
        if (currentIndex != NSNotFound && currentIndex + 1 < [currentPlaylist count]) {
            // Return the next episode after current
            anEpisode = currentPlaylist[currentIndex + 1];
        } else if (currentIndex == NSNotFound) {
            // Current episode not in playlist, return first
            anEpisode = [currentPlaylist firstObject];
        }
        // If current is the last one, anEpisode stays nil (end of playlist)
    } else {
        anEpisode = [currentPlaylist firstObject];
    }

    // If no episode from Up Next, check per-feed continuous play setting
    if (!anEpisode && self.episode) {
        CDFeed* feed = self.episode.feed;
        NSInteger continuousMode = [feed integerForKey:ContinuousPlayFromFeed];

        if (continuousMode != ContinuousPlaybackOff) {
            BOOL newerToOlder = (continuousMode == ContinuousPlaybackOn);
            NSArray* episodes = [feed sortedEpisodes];

            if (episodes.count > 0) {
                NSUInteger currentIdx = [episodes indexOfObject:self.episode];
                if (currentIdx != NSNotFound) {
                    // sortedEpisodes returns newest first by default
                    // ContinuousPlaybackOn (newer-to-older) = go forward in the array (older episodes)
                    // ContinuousPlaybackReverse (older-to-newer) = go backward in the array (newer episodes)
                    if (newerToOlder && currentIdx + 1 < episodes.count) {
                        // Next older episode
                        for (NSUInteger i = currentIdx + 1; i < episodes.count; i++) {
                            CDEpisode* candidate = episodes[i];
                            if (!candidate.consumed && [candidate preferedMedium]) {
                                anEpisode = candidate;
                                break;
                            }
                        }
                    } else if (!newerToOlder && currentIdx > 0) {
                        // Next newer episode
                        for (NSInteger i = (NSInteger)currentIdx - 1; i >= 0; i--) {
                            CDEpisode* candidate = episodes[i];
                            if (!candidate.consumed && [candidate preferedMedium]) {
                                anEpisode = candidate;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }

    BOOL warn3G = (App.networkAccessTechnology < kICNetworkAccessTechnlogyWIFI && ![USER_DEFAULTS boolForKey:EnableStreamingOver3G]);
    BOOL episodeIsCached = [[CacheManager sharedCacheManager] episodeIsCached:anEpisode];

    if (!episodeIsCached && warn3G) {
        canStartEpisode = NO;
    }

	return (canStartEpisode && [anEpisode preferedMedium]) ? anEpisode : nil;
}

- (void) playEpisode:(CDEpisode*)anEpisode
{
    [self playEpisode:anEpisode queueUpCurrent:NO];
}

- (void) playEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent
{
    [self playEpisode:anEpisode queueUpCurrent:queueUpCurrent at:0 autostart:YES];
}

- (void) playEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent at:(NSTimeInterval)time autostart:(BOOL)autostart
{
    if (!anEpisode) {
        return;
    }
    
    [self resetSession];
    
    CDEpisode* currentEpisode = self.episode;

    self.episode = anEpisode;
    // Don't automatically remove from Up Next - user wants manual control
    // [self eraseEpisodesFromUpNext:@[anEpisode]];

    if (currentEpisode && queueUpCurrent) {
        [self prependToUpNext:@[currentEpisode]];
    }

	[self _savePlaybackStateInUserDefaults];
    [[PlaybackManager playbackManager] openWithEpisode:anEpisode at:MAX(0, time) autostart:autostart];
    
    self.continuousPlaybackTemporarilyDisabled = NO;
}

- (void) clear
{
    [self stopSilentPlayback];

    if (self.episode) {
        self.episode = nil;
        [self _savePlaybackStateInUserDefaults];

        DebugLog(@"endReceivingRemoteControlEvents");

        [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
    }
}

- (void) stop
{
    [[PlaybackManager playbackManager] close];
    [self clear];
}

- (void) togglePlay
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    //devd to do-toolar
    if (pman.paused)
    {
        if (!pman.ready && self.episode) {
            [self playEpisode:self.episode];
        }
        
        else {
            [pman play];
            [self updateNowPlayingInfo];
        }
        NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
        [AudioSession sharedAudioSession].timerValue = sleepTimer;
        BOOL isAlwaysTimerActive = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];
        if (isAlwaysTimerActive)
        {
            if ([USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer] == PlaybackStopTimeNoValue)
            {
                NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                if (lastSleepTimer > 0)
                {
                    [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                }
                else
                {
                    [AudioSession sharedAudioSession].timerValue = PlaybackStopTime5min;
                }
            }
        }
    } else {
        BOOL isTouchActive = [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep];
        BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
        
        BOOL isAlwaysTimerActive = [USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive];

        if (((!isTouchActive) || (!isIntelligentTimerActive)) && ([USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer] != PlaybackStopTimeNoValue))
        {
            NSTimeInterval tRem = [AudioSession sharedAudioSession].timerRemainingTime;
            if (tRem > 0)
            {
                [USER_DEFAULTS setInteger:round(tRem) forKey:UncompletedSleepTimeInterval];
                [USER_DEFAULTS synchronize];
            }
        }
        else if (isAlwaysTimerActive)
        {
            NSTimeInterval tRem = [AudioSession sharedAudioSession].timerRemainingTime;
            if (tRem > 0)
            {
                [USER_DEFAULTS setInteger:round(tRem) forKey:UncompletedSleepTimeInterval];
                [USER_DEFAULTS synchronize];
            }
        }
        [pman pause];
    }
}

- (void) disableContinuousPlaybackForCurrentEpisode
{
    self.continuousPlaybackTemporarilyDisabled = YES;
}

- (void) setEpisode:(CDEpisode *)episode
{
    __weak AudioSession* weakSelf = self;
    
    if (_episode != episode)
    {
        [_episode removeTaskObserver:self forKeyPath:@"archived"];
        [_episode.feed removeTaskObserver:self forKeyPath:@"subscribed"];
        
        _episode = episode;
        
        [episode addTaskObserver:self forKeyPath:@"archived" task:^(id obj, NSDictionary *change) {
            if (weakSelf.episode.archived) {
                [weakSelf stop];
            }
        }];
        
        [episode.feed addTaskObserver:self forKeyPath:@"subscribed" task:^(id obj, NSDictionary *change) {
            if (!weakSelf.episode.feed.subscribed) {
               // [weakSelf stop];
            }
        }];
    }
}

#pragma mark -

- (void) _savePlaybackStateInUserDefaults
{
	if (self.episode && self.episode.objectHash) {
		[USER_DEFAULTS setObject:self.episode.objectHash forKey:kPlaybackStateEpisode];
	} else {
		[USER_DEFAULTS removeObjectForKey:kPlaybackStateEpisode];
	}
	
	if (self.playlist) {
		NSMutableArray* hashes = [[NSMutableArray alloc] initWithCapacity:[self.playlist count]];
		
		for(CDEpisode* anEpisode in self.playlist) {
			if (anEpisode.guid) {
				[hashes addObject:anEpisode.objectHash];
			}
		}
		
		[USER_DEFAULTS setObject:hashes forKey:kPlaybackStatePlaylist];
		
	} else {
		[USER_DEFAULTS removeObjectForKey:kPlaybackStatePlaylist];
	}
	
	[USER_DEFAULTS synchronize];
}

- (void) _restorePlaybackStateFromUserDefaults
{
	NSString* episodeHash = [USER_DEFAULTS objectForKey:kPlaybackStateEpisode];
	NSArray* playlistHashes = [USER_DEFAULTS objectForKey:kPlaybackStatePlaylist];

	[self restorePlaybackStateWithEpisodeHash:episodeHash playlistHashes:playlistHashes time:-1];
}

- (BOOL) canRestorePlaybackState
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    return (pman.paused);
}

- (void) restorePlaybackStateWithEpisodeHash:(NSString*)episodeHash playlistHashes:(NSArray*)playlistHashes time:(NSTimeInterval)time
{
    if (![self canRestorePlaybackState]) {
        return;
    }

    if (episodeHash)
    {
        PlaybackManager* pman = [PlaybackManager playbackManager];
		CDEpisode* anEpisode = [DMANAGER episodeWithObjectHash:episodeHash];
        
		if (anEpisode && !anEpisode.archived)
        {
            if ([self.episode isEqual:anEpisode]) {
                NSTimeInterval t = (time >= 0) ? time : anEpisode.position;
                [pman seekToTime:t];
            }

			self.episode = anEpisode;
		}
	}
	
	if (playlistHashes)
	{
		NSMutableArray* aPlaylist = [[NSMutableArray alloc] initWithCapacity:[playlistHashes count]];
		
		for (NSString* hash in playlistHashes) {
			CDEpisode* anEpisode = [DMANAGER episodeWithObjectHash:hash];
			if (anEpisode) {
				[aPlaylist addObject:anEpisode];
			}
		}
		
		if ([aPlaylist count] > 0) {
            [self appendToUpNext:aPlaylist];
		}
	}
    
    [self _savePlaybackStateInUserDefaults];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionDidRestorePlaybackNotification object:self];
}

#pragma mark -

- (BOOL) isAirPlayActive
{
    AVAudioSession* session = [AVAudioSession sharedInstance];
    AVAudioSessionRouteDescription* currentRoute = session.currentRoute;
    NSArray* outputs = currentRoute.outputs;
    
    for(AVAudioSessionPortDescription* portDescription in outputs) {
        NSString* portType = portDescription.portType;
        NSString* portTypeAirPlay = AVAudioSessionPortAirPlay;
        NSString* portTypeBluetooth = AVAudioSessionPortBluetoothA2DP;
        
        if ([portType isEqualToString:portTypeAirPlay] || [portType isEqualToString:portTypeBluetooth]) {
            return YES;
        }
        
    }
    return NO;
}

- (BOOL) headphonesAttached
{
    AVAudioSession* session = [AVAudioSession sharedInstance];
    AVAudioSessionRouteDescription* currentRoute = session.currentRoute;
    NSArray* outputs = currentRoute.outputs;
    
    for(AVAudioSessionPortDescription* portDescription in outputs) {
        NSString* portType = portDescription.portType;
        if ([portType isEqualToString:AVAudioSessionPortHeadphones]) {
            return YES;
        }
        
    }
    return NO;
}

#pragma mark -
#pragma mark Playback Timer

- (NSTimeInterval) timerRemainingTime
{
    if (self.stopDate) {
        if ([PlaybackManager playbackManager].isPodcastPlaying)
        {
            NSTimeInterval remaining = [self.stopDate timeIntervalSinceDate:[NSDate date]];
            return remaining;
        }
        else
        {
            if ([USER_DEFAULTS objectForKey:UncompletedSleepTimeInterval] != nil)
            {
                NSTimeInterval sleepTimer = [USER_DEFAULTS integerForKey:UncompletedSleepTimeInterval];
                return (sleepTimer) - 1;
            }
            else
            {
                NSInteger sleepTimer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
                NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                if (sleepTimer > 0)
                {
                    return (sleepTimer*60) - 1;
                }
                else if (lastSleepTimer > 0)
                {
                    return (lastSleepTimer*60) - 1;
                }
            }
        }
    }
    
    return 0;
}

- (void) setTimerValue:(PlaybackStopTimeValue)timerValue
{
    if ([self _shouldDisableSleepTimerForCarPlay]) {
        timerValue = PlaybackStopTimeNoValue;
    }

    if (_timerValue != timerValue) {
        _timerValue = timerValue;
    }
    
    [self.playbackTimer invalidate];
    self.playbackTimer = nil;
    
    if (timerValue > 0)
    {
        //Devd to do
        if ([USER_DEFAULTS objectForKey:UncompletedSleepTimeInterval] != nil)
        {
            BOOL isTouchActive = [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep];
            BOOL isIntelligentTimerActive = [USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive];
            if ((isIntelligentTimerActive) && (isTouchActive))
            {
                self.stopDate = [NSDate dateWithTimeIntervalSinceNow:timerValue*60];
            }
            else
            {
                NSTimeInterval sleepTimer = [USER_DEFAULTS integerForKey:UncompletedSleepTimeInterval];
                self.stopDate = [NSDate dateWithTimeIntervalSinceNow:sleepTimer];
            }
        }
        else
        {
            self.stopDate = [NSDate dateWithTimeIntervalSinceNow:timerValue*60];
        }
        self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:1  target:self selector:@selector(stopPlaybackTimer:) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self.playbackTimer forMode:NSRunLoopCommonModes];
    }
    else
    {
        self.stopDate = nil;
    }
    
    [self willChangeValueForKey:@"timerRemainingTime"];
    [self didChangeValueForKey:@"timerRemainingTime"];
}

- (void)stopPlaybackTimer:(NSTimer*)timer
{
    [self willChangeValueForKey:@"timerRemainingTime"];
    [self didChangeValueForKey:@"timerRemainingTime"];

    NSDate* now = [NSDate date];
    if (self.stopDate && [self.stopDate earlierDate:now] == self.stopDate)
    {
        [self.playbackTimer invalidate];
        self.playbackTimer = nil;
        if (self.timerValue != PlaybackStopTimeNoValue)
        {
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [USER_DEFAULTS synchronize];
            if (![USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive])
            {
                self.timerValue = PlaybackStopTimeNoValue;
            }
            else
            {
                self.timerValue = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
                if ([USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer] == PlaybackStopTimeNoValue)
                {
                    NSInteger lastSleepTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
                    if (lastSleepTimer > 0)
                    {
                        [AudioSession sharedAudioSession].timerValue = lastSleepTimer;
                    }
                    else
                    {
                        [AudioSession sharedAudioSession].timerValue = PlaybackStopTime5min;
                    }
                }
            }
            [[PlaybackManager playbackManager] pause];
            // Track fell asleep count
            NSInteger fellAsleepCount = [USER_DEFAULTS integerForKey:@"SleepTimerFellAsleepCount"];
            [USER_DEFAULTS setInteger:fellAsleepCount + 1 forKey:@"SleepTimerFellAsleepCount"];
            [self stopSilentPlayback]; // Sleep timer stop should not keep app alive
            self.playerWasPlayingBeforeWentToBackground = NO;
            [PlaybackManager playbackManager].hasBeenPlayingWhenInterrupted = NO;
            self.stopDate = nil;
            [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionSleepTimerDidExpireNotification object:self];
        }
    }
}

#pragma mark -
#pragma mark Silent Audio Playback (Background Keep-Alive)

- (void)startSilentPlayback
{
    if (self.silentPlayer) {
        return; // Already running
    }

    NSURL* url = [[NSBundle mainBundle] URLForResource:@"Silence" withExtension:@"caf"];
    if (!url) {
        ErrLog(@"Silence.caf not found in bundle");
        return;
    }

    AVPlayerItem* item = [AVPlayerItem playerItemWithURL:url];
    self.silentPlayer = [AVPlayer playerWithPlayerItem:item];
    self.silentPlayer.volume = 0.0; // Inaudible

    // Loop when finished
    __weak typeof(self) weakSelf = self;
    self.silentPlayerLoopObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
        object:item
        queue:nil
        usingBlock:^(NSNotification* note) {
            [weakSelf.silentPlayer seekToTime:kCMTimeZero completionHandler:nil];
            [weakSelf.silentPlayer play];
        }];

    [self.silentPlayer play];
    DebugLog(@"Started silent playback for background keep-alive");
}

- (void)stopSilentPlayback
{
    if (self.silentPlayerLoopObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.silentPlayerLoopObserver];
        self.silentPlayerLoopObserver = nil;
    }

    if (self.silentPlayer) {
        [self.silentPlayer pause];
        self.silentPlayer = nil;
        DebugLog(@"Stopped silent playback");
    }
}

@end
