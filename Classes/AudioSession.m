//
//  AudioSession.m
//  Instacast
//
//  Created by Martin Hering on 19.07.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <AudioToolbox/AudioToolbox.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MPNowPlayingInfoCenter.h>
#if !TARGET_OS_MACCATALYST
#import <CarPlay/CarPlay.h>
#endif

#import "AudioSession.h"
#import "AudioSession+UpNextPlaylist.h"

#import "ICMetadata.h"
#import "CDFeed+Helper.h"
#import "InstacastPlus-Swift.h"
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
recordsPlaybackIntent:(BOOL)recordsPlaybackIntent
preservingPlaybackSource:(BOOL)preservingPlaybackSource;

@property (nonatomic, strong) NSTimer* playbackTimer;
@property (nonatomic) NSTimeInterval sleepTimerDuration;
@property (nonatomic) NSTimeInterval pausedSleepTimerRemainingTime;
@property (nonatomic, copy) NSString* sleepTimerDiagnosticReason;
@property (nonatomic, copy) NSString* lastSleepTimerDiagnosticReason;
@property (nonatomic, strong) NSDate* lastSleepTimerDiagnosticDate;
@property (nonatomic) PlaybackStopTimeValue lastLoggedSleepTimerValue;
@property (nonatomic, strong) NSDate* lastSleepTimerTick;
@property (nonatomic, strong) NSDate* lastSleepTimerResetDate;
@property (nonatomic, copy) NSString* lastSleepTimerResetReason;
@property (nonatomic) NSUInteger sleepTimerTouchResetCount;
@property (nonatomic) NSUInteger sleepTimerMotionResetCount;
@property (nonatomic) NSUInteger sleepTimerVolumeResetCount;
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
        if (![session setCategory:AVAudioSessionCategoryPlayback
                             mode:AVAudioSessionModeDefault
               routeSharingPolicy:AVAudioSessionRouteSharingPolicyLongFormAudio
                          options:0
                            error:&categoryError]) {
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
    if (session.routeSharingPolicy == AVAudioSessionRouteSharingPolicyIndependent) {
        return;
    }
    
    NSError* categoryError = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
           routeSharingPolicy:AVAudioSessionRouteSharingPolicyLongFormAudio
                      options:0
                        error:&categoryError]) {
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
    [self _logSleepTimerEvent:@"entered-background" metadata:@{}];
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

    // Which rule picked the follow-up episode. Logged below — the three sources (Up Next,
    // continuation of the list playback was started from, per-feed continuous play) are
    // indistinguishable in the diagnostics otherwise.
    NSString* source = @"none";

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

    if (anEpisode) {
        source = @"upnext";
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
                    source = @"source-list";
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
                                source = @"feed";
                                break;
                            }
                        }
                    } else if (!newerToOlder && currentIdx > 0) {
                        // Next newer episode
                        for (NSInteger i = (NSInteger)currentIdx - 1; i >= 0; i--) {
                            CDEpisode* candidate = episodes[i];
                            if (!candidate.consumed && [candidate preferedMedium]) {
                                anEpisode = candidate;
                                source = @"feed";
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

    CDEpisode* nextEpisode = (canStartEpisode && [anEpisode preferedMedium]) ? anEpisode : nil;

    [[ICDiagnosticLogger shared] logEvent:@"playback-continuation"
                                  message:@"Folgeepisode bestimmt"
                                 metadata:@{
                                     @"source": source,
                                     @"currentEpisodeHash": self.episode.objectHash ?: @"",
                                     @"nextEpisodeHash": nextEpisode.objectHash ?: @"",
                                     @"candidateHash": anEpisode.objectHash ?: @"",
                                     @"upNextCount": @(currentPlaylist.count),
                                     @"sourceListUID": self.sourceEpisodeListUID ?: @"",
                                     @"canStartEpisode": @(canStartEpisode),
                                 }];

	return nextEpisode;
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

// A list screen arms its list before presenting the player, but only _playEpisode: consumes
// that arm. Tapping play on the episode that is already loaded (in "Recently played" that is
// the normal case — its top row IS the last played episode) merely resumes the player, so the
// arm used to survive and was applied to the next episode started from a completely different
// screen, which then kept continuing that stale list.
- (void) applyPendingPlaybackSourceToCurrentEpisode
{
    if (self.pendingSourceEpisodeListUID == nil) {
        return;
    }

    [self _resolvePlaybackSourceListForEpisode:self.episode
                     preservingPlaybackSource:YES];
    [self _savePlaybackStateInUserDefaults];
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
// arm from a list screen wins. Only an explicitly identified continuation or resume may
// otherwise inherit the current source; a manual start clears it even if the episode
// also matches that list.
- (void) _resolvePlaybackSourceListForEpisode:(CDEpisode*)anEpisode
                    preservingPlaybackSource:(BOOL)preservingPlaybackSource
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
    if (!preservingPlaybackSource) {
        self.sourceEpisodeListUID = nil;
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
    [self playEpisode:anEpisode
       queueUpCurrent:queueUpCurrent
                   at:time
            autostart:autostart
preservingPlaybackSource:NO];
}

- (void) playEpisode:(CDEpisode*)anEpisode
       queueUpCurrent:(BOOL)queueUpCurrent
                   at:(NSTimeInterval)time
            autostart:(BOOL)autostart
preservingPlaybackSource:(BOOL)preservingPlaybackSource
{
    [self _playEpisode:anEpisode
        queueUpCurrent:queueUpCurrent
                    at:time
             autostart:autostart
 recordsPlaybackIntent:YES
preservingPlaybackSource:preservingPlaybackSource];
}

- (void) restorePlaybackEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent at:(NSTimeInterval)time autostart:(BOOL)autostart
{
    [self _playEpisode:anEpisode
        queueUpCurrent:queueUpCurrent
                    at:time
             autostart:autostart
 recordsPlaybackIntent:NO
preservingPlaybackSource:YES];
}

- (void) _playEpisode:(CDEpisode*)anEpisode
       queueUpCurrent:(BOOL)queueUpCurrent
                   at:(NSTimeInterval)time
            autostart:(BOOL)autostart
recordsPlaybackIntent:(BOOL)recordsPlaybackIntent
preservingPlaybackSource:(BOOL)preservingPlaybackSource
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

    [self _resolvePlaybackSourceListForEpisode:anEpisode
                     preservingPlaybackSource:preservingPlaybackSource];
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
            [self playEpisode:self.episode queueUpCurrent:NO at:0 autostart:YES preservingPlaybackSource:YES];
        }
        
        else {
            [pman play];
            [self updateNowPlayingInfo];
        }
    } else {
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

- (NSDictionary*)sleepTimerDiagnosticsMetadata
{
    return @{
        @"episodeHash": self.episode.objectHash ?: @"",
        @"timerValue": @(self.timerValue),
        @"timerValid": @(self.playbackTimer.valid),
        @"stopDate": @(self.stopDate.timeIntervalSince1970),
        @"remainingSeconds": @(self.stopDate ? self.stopDate.timeIntervalSinceNow : 0),
        @"pausedRemainingSeconds": @(self.pausedSleepTimerRemainingTime),
        @"lastTimerTick": @(self.lastSleepTimerTick.timeIntervalSince1970),
        @"lastResetDate": @(self.lastSleepTimerResetDate.timeIntervalSince1970),
        @"lastResetReason": self.lastSleepTimerResetReason ?: @"",
        @"touchResetCount": @(self.sleepTimerTouchResetCount),
        @"motionResetCount": @(self.sleepTimerMotionResetCount),
        @"volumeResetCount": @(self.sleepTimerVolumeResetCount),
        @"alwaysActive": @([USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive]),
        @"intelligentActive": @([USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive]),
        @"touchEnabled": @([USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep]),
        @"motionEnabled": @([USER_DEFAULTS boolForKey:DeviceMovementIntelligentSleep]),
        @"volumeEnabled": @([USER_DEFAULTS boolForKey:VolumeChangeIntelligentSleep]),
        @"motionThreshold": @([USER_DEFAULTS doubleForKey:DeviceMovementSensitivity]),
        @"disableInCarPlay": @([USER_DEFAULTS boolForKey:DisableSleepTimerInCarPlay]),
        @"carPlayConnected": @([self _isCarPlaySceneConnected]),
        @"defaultMinutes": @([USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer]),
        @"lastSelectedMinutes": @([USER_DEFAULTS integerForKey:LastSelectedSleepTimer]),
        @"uncompletedSeconds": [USER_DEFAULTS objectForKey:UncompletedSleepTimeInterval] ?: @"absent",
        @"applicationState": @(App.applicationState),
        @"playbackPaused": @([PlaybackManager playbackManager].paused),
        @"playbackTime": @([PlaybackManager playbackManager].time),
    };
}

- (void)_logSleepTimerEvent:(NSString*)reason metadata:(NSDictionary*)extraMetadata
{
    NSDate* now = [NSDate date];
    BOOL sensorReset = [reason isEqualToString:@"touch"] || [reason isEqualToString:@"motion"] || [reason isEqualToString:@"volume"];
    if (sensorReset) {
        if ([reason isEqualToString:@"touch"]) self.sleepTimerTouchResetCount++;
        if ([reason isEqualToString:@"motion"]) self.sleepTimerMotionResetCount++;
        if ([reason isEqualToString:@"volume"]) self.sleepTimerVolumeResetCount++;
        self.lastSleepTimerResetDate = now;
        self.lastSleepTimerResetReason = reason;
        // Count every reset; summarize repeated sensor events without flooding overnight logs.
        if ([self.lastSleepTimerDiagnosticReason isEqualToString:reason] &&
            self.lastLoggedSleepTimerValue == self.timerValue &&
            self.lastSleepTimerDiagnosticDate && [now timeIntervalSinceDate:self.lastSleepTimerDiagnosticDate] < 30.0) {
            return;
        }
    }
    self.lastSleepTimerDiagnosticDate = now;
    self.lastSleepTimerDiagnosticReason = reason;
    self.lastLoggedSleepTimerValue = self.timerValue;
    NSMutableDictionary* metadata = [[self sleepTimerDiagnosticsMetadata] mutableCopy];
    [metadata addEntriesFromDictionary:extraMetadata];
    metadata[@"eventDate"] = @(now.timeIntervalSince1970);
    // Raw addresses allow offline symbolication with this build's dSYM; no symbol lookup on main.
    void* addresses[8];
    int count = backtrace(addresses, 8);
    Dl_info info;
    if (count > 0 && dladdr(addresses[0], &info)) {
        metadata[@"imageLoadAddress"] = [NSString stringWithFormat:@"%p", info.dli_fbase];
    }
    for (int index = 0; index < count; index++) {
        metadata[[NSString stringWithFormat:@"caller.%02d", index]] = [NSString stringWithFormat:@"%p", addresses[index]];
    }
    [[ICDiagnosticLogger shared] logEvent:@"sleep-timer" message:reason metadata:metadata];
}

- (void)setTimerValue:(PlaybackStopTimeValue)timerValue diagnosticReason:(NSString*)reason
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTimerValue:timerValue diagnosticReason:reason];
        });
        return;
    }
    self.sleepTimerDiagnosticReason = reason;
    self.timerValue = timerValue;
    self.sleepTimerDiagnosticReason = nil;
}

- (void)startSleepTimerIfNeeded
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startSleepTimerIfNeeded];
        });
        return;
    }

    // Preserve a running countdown across buffering, chapter changes and repeated Play.
    if (![PlaybackManager playbackManager].isPodcastPlaying || self.stopDate ||
        [self _shouldDisableSleepTimerForCarPlay]) {
        return;
    }

    if (self.pausedSleepTimerRemainingTime > 0) {
        [self _scheduleSleepTimerWithDuration:self.pausedSleepTimerRemainingTime];
        [self _logSleepTimerEvent:@"playback-resume" metadata:@{}];
        [self willChangeValueForKey:@"timerRemainingTime"];
        [self didChangeValueForKey:@"timerRemainingTime"];
        [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionSleepTimerDidChangeNotification object:self];
        return;
    }

    if (![USER_DEFAULTS boolForKey:ScreenTimerAlwaysActive]) {
        return;
    }

    NSInteger timer = [USER_DEFAULTS integerForKey:DefaultIntelligentSleepTimer];
    if (timer == PlaybackStopTimeNoValue) {
        NSInteger lastTimer = [USER_DEFAULTS integerForKey:LastSelectedSleepTimer];
        timer = lastTimer > 0 ? lastTimer : PlaybackStopTime5min;
    }
    [self setTimerValue:timer diagnosticReason:@"playback-start"];
}

- (void)resetSleepTimerForActivity:(NSString*)reason
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self resetSleepTimerForActivity:reason];
        });
        return;
    }

    // Activity extends the current selection; it must not enable a cancelled timer.
    if (!self.stopDate || ![PlaybackManager playbackManager].isPodcastPlaying ||
        [self _shouldDisableSleepTimerForCarPlay]) {
        return;
    }
    [self.playbackTimer invalidate];
    self.playbackTimer = nil;
    [self _scheduleSleepTimerWithDuration:self.sleepTimerDuration];
    [self _logSleepTimerEvent:reason metadata:@{}];
    [self willChangeValueForKey:@"timerRemainingTime"];
    [self didChangeValueForKey:@"timerRemainingTime"];
}

- (NSTimeInterval) timerRemainingTime
{
    return self.stopDate ? self.stopDate.timeIntervalSinceNow : self.pausedSleepTimerRemainingTime;
}

- (void)pauseSleepTimer
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL hadRunningTimer = (self.stopDate != nil);
            [self pauseSleepTimer];
            // Reconcile an overtaking Play only if this Pause stopped a timer.
            // A newer cancellation has already removed its deadline.
            if (hadRunningTimer) {
                [self startSleepTimerIfNeeded];
            }
        });
        return;
    }

    if (!self.stopDate) {
        return;
    }

    NSTimeInterval remaining = MAX(0, self.stopDate.timeIntervalSinceNow);
    if ([USER_DEFAULTS boolForKey:IntelligentSleepTimerAlwaysActive] &&
        [USER_DEFAULTS boolForKey:ScreenTouchIntelligentSleep]) {
        remaining = self.sleepTimerDuration;
    }
    self.pausedSleepTimerRemainingTime = remaining;
    [self.playbackTimer invalidate];
    self.playbackTimer = nil;
    self.stopDate = nil;
    [self _logSleepTimerEvent:@"playback-pause" metadata:@{}];
    [self willChangeValueForKey:@"timerRemainingTime"];
    [self didChangeValueForKey:@"timerRemainingTime"];
    [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionSleepTimerDidChangeNotification object:self];
}

- (void)_scheduleSleepTimerWithDuration:(NSTimeInterval)seconds
{
    if ([PlaybackManager playbackManager].paused) {
        self.pausedSleepTimerRemainingTime = seconds;
        self.stopDate = nil;
        return;
    }

    self.pausedSleepTimerRemainingTime = 0;
    self.stopDate = [NSDate dateWithTimeIntervalSinceNow:seconds];
    self.playbackTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(stopPlaybackTimer:) userInfo:nil repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.playbackTimer forMode:NSRunLoopCommonModes];
}

- (void) setTimerValue:(PlaybackStopTimeValue)timerValue
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.timerValue = timerValue;
        });
        return;
    }

    PlaybackStopTimeValue requestedValue = timerValue;
    NSTimeInterval previousStopDate = self.stopDate.timeIntervalSince1970;
    if ([self _shouldDisableSleepTimerForCarPlay]) {
        timerValue = PlaybackStopTimeNoValue;
    }

    if (_timerValue != timerValue) {
        _timerValue = timerValue;
    }
    
    [self.playbackTimer invalidate];
    self.playbackTimer = nil;
    self.sleepTimerDuration = MAX(0, timerValue * 60);
    self.pausedSleepTimerRemainingTime = 0;
    [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
    
    if (timerValue > 0)
    {
        [self _scheduleSleepTimerWithDuration:self.sleepTimerDuration];
    }
    else
    {
        self.stopDate = nil;
    }
    
    [self _logSleepTimerEvent:self.sleepTimerDiagnosticReason ?: @"timer-value"
                    metadata:@{@"requestedMinutes": @(requestedValue), @"previousStopDate": @(previousStopDate)}];
    [self willChangeValueForKey:@"timerRemainingTime"];
    [self didChangeValueForKey:@"timerRemainingTime"];
    [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionSleepTimerDidChangeNotification object:self];
}

- (void)setTimerWithDuration:(NSTimeInterval)seconds
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setTimerWithDuration:seconds];
        });
        return;
    }

    NSTimeInterval requestedSeconds = seconds;
    if ([self _shouldDisableSleepTimerForCarPlay]) {
        seconds = 0;
    }

    [self.playbackTimer invalidate];
    self.playbackTimer = nil;
    self.sleepTimerDuration = MAX(0, seconds);
    self.pausedSleepTimerRemainingTime = 0;
    [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];

    if (seconds > 0) {
        _timerValue = 1; // mark as active (non-zero)
        [self _scheduleSleepTimerWithDuration:seconds];
    } else {
        _timerValue = PlaybackStopTimeNoValue;
        self.stopDate = nil;
    }

    [self _logSleepTimerEvent:@"timer-duration" metadata:@{@"requestedSeconds": @(requestedSeconds)}];
    [self willChangeValueForKey:@"timerRemainingTime"];
    [self didChangeValueForKey:@"timerRemainingTime"];
    [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionSleepTimerDidChangeNotification object:self];
}

- (void)stopPlaybackTimer:(NSTimer*)timer
{
    self.lastSleepTimerTick = [NSDate date];
    [self willChangeValueForKey:@"timerRemainingTime"];
    [self didChangeValueForKey:@"timerRemainingTime"];

    NSDate* now = [NSDate date];
    if (self.stopDate && [self.stopDate earlierDate:now] == self.stopDate)
    {
        [self _logSleepTimerEvent:@"expired" metadata:@{}];
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
            [[ICSharePlayCoordinator sharedCoordinator] leaveSessionForLocalPlayback];
            [[PlaybackManager playbackManager] pause];
            // Track fell asleep count
            NSInteger fellAsleepCount = [USER_DEFAULTS integerForKey:@"SleepTimerFellAsleepCount"];
            [USER_DEFAULTS setInteger:fellAsleepCount + 1 forKey:@"SleepTimerFellAsleepCount"];
            self.playerWasPlayingBeforeWentToBackground = NO;
            [PlaybackManager playbackManager].hasBeenPlayingWhenInterrupted = NO;
            [self.playbackTimer invalidate];
            self.playbackTimer = nil;
            self.stopDate = nil;
            self.pausedSleepTimerRemainingTime = 0;
            [USER_DEFAULTS removeObjectForKey:UncompletedSleepTimeInterval];
            [self willChangeValueForKey:@"timerRemainingTime"];
            [self didChangeValueForKey:@"timerRemainingTime"];
            [self _logSleepTimerEvent:@"pause-completed" metadata:@{}];
            [[NSNotificationCenter defaultCenter] postNotificationName:AudioSessionSleepTimerDidExpireNotification object:self];
        }
    }
}

@end
