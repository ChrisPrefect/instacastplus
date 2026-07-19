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

@interface PlaybackManager (ICChapterPersistence)
@property (nonatomic, readonly, strong) NSArray* embeddedChaptersForPersistence;
@end

static NSString* kPlaybackStateEpisode = @"PlaybackEpisode";
static NSString* kPlaybackStatePlaylist = @"PlaybackPlaylist";
static NSString* kPlaybackStateSourceList = @"PlaybackSourceList";
static NSString* kPlaybackIntentRevision = @"PlaybackIntentRevision";

NSString* AudioSessionAudioRouteDidChangeNotification = @"AudioSessionAudioRouteDidChangeNotification";
NSString* AudioSessionDidRestorePlaybackNotification = @"AudioSessionDidRestorePlaybackNotification";

@interface AudioSession ()
@property (nonatomic, readwrite, strong) CDEpisode* episode;

- (void) _savePlaybackStateInUserDefaults;
- (void) _restorePlaybackStateFromUserDefaults;
- (void)_recordPlaybackIntent;
- (void) _playEpisode:(CDEpisode*)anEpisode
       queueUpCurrent:(BOOL)queueUpCurrent
                   at:(NSTimeInterval)time
            autostart:(BOOL)autostart
recordsPlaybackIntent:(BOOL)recordsPlaybackIntent;

@property (nonatomic, strong) NSTimer* playbackTimer;
@property (nonatomic, strong) NSDate* stopDate;
@property BOOL playerWasPlayingBeforeWentToBackground;
@property BOOL continuousPlaybackTemporarilyDisabled;
@property BOOL autoStopDisabled;

@property (nonatomic, copy, readwrite) NSString* sourceEpisodeListUID;
// Armed by a list screen right before it initiates playback; consumed by the next
// playEpisode: (which may run later, e.g. behind the cellular-streaming alert).
@property (nonatomic, copy) NSString* pendingSourceEpisodeListUID;

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

+ (uint64_t)playbackIntentRevision
{
    id storedRevision = [USER_DEFAULTS objectForKey:kPlaybackIntentRevision];
    return [storedRevision isKindOfClass:[NSNumber class]] ? [storedRevision unsignedLongLongValue] : 0;
}

- (void)_recordPlaybackIntent
{
    uint64_t nextRevision = [AudioSession playbackIntentRevision] + 1;
    [USER_DEFAULTS setObject:@(nextRevision) forKey:kPlaybackIntentRevision];
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
    
    self.playerWasPlayingBeforeWentToBackground = (pman.movingVideo && !pman.paused);
}

-(void)resumePlayback
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    BOOL shouldResumePlayback = self.playerWasPlayingBeforeWentToBackground;
    self.playerWasPlayingBeforeWentToBackground = NO;
    
    if (shouldResumePlayback && pman.movingVideo && pman.paused) {
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
                                                 name:CacheManagerWillCommitCacheFileDeletionNotification
                                               object:nil];
}

- (void) _handleEpisodeCacheCleared:(NSNotification*)note
{
    NSArray<NSString*>* episodeHashes = [note.userInfo[@"episodeHashes"] isKindOfClass:[NSArray class]] ? note.userInfo[@"episodeHashes"] : @[];
    BOOL clearsAll = [note.userInfo[@"all"] boolValue];
    BOOL clearsCurrentEpisode = [self.episode isEqual:note.userInfo[@"episode"]] ||
        (self.episode.objectHash.length > 0 && [episodeHashes containsObject:self.episode.objectHash]);
    if (!self.autoStopDisabled && (clearsAll || clearsCurrentEpisode)) {
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

        BOOL shouldResumeAfterInterruption = pman.hasBeenPlayingWhenInterrupted;

        if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
            BOOL playingBeforeInterrupt = !pman.paused;
            pman.hasBeenPlayingWhenInterrupted = playingBeforeInterrupt;
            DebugLog(@"AVAudioSession interruption BEGAN: playingBefore=%d paused=%d",
                     playingBeforeInterrupt, pman.paused);
            [pman pause];
        }
        else if (interruptionType == AVAudioSessionInterruptionTypeEnded) {
            pman.hasBeenPlayingWhenInterrupted = NO;
            if (shouldResumeAfterInterruption) {
                DebugLog(@"AVAudioSession interruption ENDED: wasPlaying=%d option=%ld paused=%d",
                         shouldResumeAfterInterruption, (long)option, pman.paused);
            }
            if (shouldResumeAfterInterruption && option == AVAudioSessionInterruptionOptionShouldResume) {
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
        NSArray* publisherChapters = pman.embeddedChaptersForPersistence;
        DebugLog(@"Chapter persistence source: episode=%@ playback=%lu publisher=%lu stored=%lu",
                 pman.playingEpisode.objectHash,
                 (unsigned long)pman.chapters.count,
                 (unsigned long)publisherChapters.count,
                 (unsigned long)storedChapters.count);
        
        if (pman.chapters.count > 0 && publisherChapters.count > 0 && [storedChapters count] == 0)
        {
            [publisherChapters enumerateObjectsUsingBlock:^(ICMetadataChapter* chapter, NSUInteger idx, BOOL *stop) {
                
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

    // If no episode from Up Next, continue the episode list the playback was started
    // from when its "Continuous Playback" flag is on. Replaces the old behavior of
    // erasing the queue and pre-filling it with the next 10 list episodes
    // (User-Entscheid 08.07.: end-of-episode check instead of queue manipulation).
    if (!anEpisode && self.episode && self.sourceEpisodeListUID.length > 0) {
        CDEpisodeList* sourceList = [self _episodeListWithUID:self.sourceEpisodeListUID];

        if (sourceList.continuousPlayback) {
            NSArray* episodes = [sourceList sortedEpisodes];
            NSUInteger currentIdx = [episodes indexOfObject:self.episode];
            // The finished episode is already consumed here and may have dropped out of
            // a dynamic list (e.g. "Unplayed") — then continue with the first playable one.
            NSUInteger startIdx = (currentIdx != NSNotFound) ? currentIdx + 1 : 0;
            for (NSUInteger i = startIdx; i < episodes.count; i++) {
                CDEpisode* candidate = episodes[i];
                if (![candidate isEqual:self.episode] && !candidate.consumed && [candidate preferedMedium]) {
                    anEpisode = candidate;
                    break;
                }
            }
        }
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

- (void) notePlaybackSourceEpisodeList:(CDEpisodeList*)list
{
    // nil list (e.g. a manual playlist screen) arms an explicit "no source" — the next
    // playEpisode: clears any previous source instead of falling back to it.
    self.pendingSourceEpisodeListUID = list.uid ?: @"";
}

- (CDEpisodeList*) _episodeListWithUID:(NSString*)listUID
{
    if (listUID.length == 0) {
        return nil;
    }
    for (CDList* list in DMANAGER.lists) {
        if ([list isKindOfClass:[CDEpisodeList class]] && [list.uid isEqualToString:listUID]) {
            return (CDEpisodeList*)list;
        }
    }
    return nil;
}

// Resolve the playback source list for the episode that is about to start. An explicit
// arm from a list screen wins. Otherwise the current source survives only while the new
// episode still belongs to that list — the list's own continuation and manual playback
// of other list members keep it, playing something outside the list ends it. (Without
// this, one play from e.g. "Unplayed" — continuousPlayback on by default — would make
// EVERY later single-episode playback continue with that list forever.)
- (void) _resolvePlaybackSourceListForEpisode:(CDEpisode*)anEpisode
{
    if (self.pendingSourceEpisodeListUID != nil) {
        NSString* pendingUID = self.pendingSourceEpisodeListUID;
        self.pendingSourceEpisodeListUID = nil;
        // The armed list only sticks when the started episode actually belongs to it —
        // a stale arm (cancelled cellular alert, playback then started elsewhere) or an
        // explicit "no source" arm ends the previous continuation instead.
        CDEpisodeList* pendingList = [self _episodeListWithUID:pendingUID];
        self.sourceEpisodeListUID = [pendingList evaluatesEpisodeNow:anEpisode] ? pendingUID : nil;
        return;
    }
    if (self.sourceEpisodeListUID.length > 0) {
        CDEpisodeList* sourceList = [self _episodeListWithUID:self.sourceEpisodeListUID];
        if (!sourceList || ![sourceList evaluatesEpisodeNow:anEpisode]) {
            self.sourceEpisodeListUID = nil;
        }
    }
}

- (void) playEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent at:(NSTimeInterval)time autostart:(BOOL)autostart
{
    [self _playEpisode:anEpisode
        queueUpCurrent:queueUpCurrent
                    at:time
             autostart:autostart
 recordsPlaybackIntent:YES];
}

- (void) restorePlaybackEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent at:(NSTimeInterval)time autostart:(BOOL)autostart
{
    [self _playEpisode:anEpisode
        queueUpCurrent:queueUpCurrent
                    at:time
             autostart:autostart
 recordsPlaybackIntent:NO];
}

- (void) _playEpisode:(CDEpisode*)anEpisode
       queueUpCurrent:(BOOL)queueUpCurrent
                   at:(NSTimeInterval)time
            autostart:(BOOL)autostart
recordsPlaybackIntent:(BOOL)recordsPlaybackIntent
{
    if (!anEpisode) {
        return;
    }

    if (recordsPlaybackIntent) {
        [self _recordPlaybackIntent];
    }

    CacheManager* cacheManager = [CacheManager sharedCacheManager];
    BOOL episodeIsCached = [cacheManager episodeIsCached:anEpisode];
    NSURL* playbackURL = episodeIsCached
        ? [cacheManager URLForCachedEpisode:anEpisode]
        : anEpisode.preferedMedium.fileURL;
    if (playbackURL.absoluteString.length == 0 || (!playbackURL.isFileURL && playbackURL.scheme.length == 0)) {
        [App showBackgroundErrorWithTitle:@"Media not loaded.".ls message:@"No media to play.".ls];
        return;
    }

    [self resetSession];

    CDEpisode* currentEpisode = self.episode;

    [self _resolvePlaybackSourceListForEpisode:anEpisode];
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
    if (self.episode) {
        [self _recordPlaybackIntent];
        self.episode = nil;
        [self _savePlaybackStateInUserDefaults];

        [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
    }
}

- (void) stop
{
    uint64_t revisionBeforeStop = [AudioSession playbackIntentRevision];
    [[PlaybackManager playbackManager] close];
    [self clear];
    if ([AudioSession playbackIntentRevision] == revisionBeforeStop) {
        [self _recordPlaybackIntent];
    }
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
            }
        }
        else if (isAlwaysTimerActive)
        {
            NSTimeInterval tRem = [AudioSession sharedAudioSession].timerRemainingTime;
            if (tRem > 0)
            {
                [USER_DEFAULTS setInteger:round(tRem) forKey:UncompletedSleepTimeInterval];
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

	if (self.sourceEpisodeListUID.length > 0) {
		[USER_DEFAULTS setObject:self.sourceEpisodeListUID forKey:kPlaybackStateSourceList];
	} else {
		[USER_DEFAULTS removeObjectForKey:kPlaybackStateSourceList];
	}
}

- (void) _restorePlaybackStateFromUserDefaults
{
	NSString* episodeHash = [USER_DEFAULTS objectForKey:kPlaybackStateEpisode];
	NSArray* playlistHashes = [USER_DEFAULTS objectForKey:kPlaybackStatePlaylist];
	self.sourceEpisodeListUID = [USER_DEFAULTS stringForKey:kPlaybackStateSourceList];

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

- (void)setTimerWithDuration:(NSTimeInterval)seconds
{
    [self.playbackTimer invalidate];
    self.playbackTimer = nil;

    if (seconds > 0) {
        _timerValue = 1; // mark as active (non-zero)
        self.stopDate = [NSDate dateWithTimeIntervalSinceNow:seconds];
        self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(stopPlaybackTimer:) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:self.playbackTimer forMode:NSRunLoopCommonModes];
    } else {
        _timerValue = PlaybackStopTimeNoValue;
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
            self.playerWasPlayingBeforeWentToBackground = NO;
            [PlaybackManager playbackManager].hasBeenPlayingWhenInterrupted = NO;
            self.stopDate = nil;
            [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionSleepTimerDidExpireNotification object:self];
        }
    }
}

@end
