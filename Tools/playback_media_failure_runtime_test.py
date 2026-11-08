#!/usr/bin/env python3
"""Run production failed-item cleanup, close and explicit-retry behavior."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Classes/PlaybackManager.m').read_text()
session_source = (ROOT / 'Classes/AudioSession.m').read_text()

def block(text, start):
    brace = text.index('{', start)
    depth = 0
    for end in range(brace, len(text)):
        depth += (text[end] == '{') - (text[end] == '}')
        if not depth:
            return text[start:end + 1]
    raise AssertionError(start)

def method(signature):
    return block(source, source.index(signature))

failure_start = source.index('else if (weakSelf.player.currentItem.status == AVPlayerItemStatusFailed)')
failure_body = block(source, failure_start).split('{', 1)[1].rsplit('}', 1)[0]
methods = [method(s) for s in ['- (void) close\n', '- (void) closeAndSaveCurrentPosition:', '- (BOOL) isPaused',
    '- (BOOL)_transitionPlaybackWithEvent:(ICPlaybackEvent)event\n', '- (BOOL)isReady\n', '- (BOOL)failed ']]
for signature in ['- (void)_releasePlaybackResourcesAndSaveCurrentPosition:', '- (void)_failPlaybackWithError:']:
    if signature in source:
        methods.append(method(signature))
toggle = block(session_source, session_source.index('- (void) togglePlay'))
fixture = r'''
#import <Foundation/Foundation.h>
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
#define ErrLog(...)
#define SEND_UPDATE [self _sendUpdateNotification];
static NSUserDefaults *testDefaults;
#define USER_DEFAULTS testDefaults
NSString *AutoDownloadWhileStreaming=@"AutoDownloadWhileStreaming";
NSString *AVPlayerItemDidPlayToEndTimeNotification=@"AVPlayerItemDidPlayToEndTimeNotification";
NSString *PlaybackManagerDidEndNotification=@"PlaybackManagerDidEndNotification";
// PLAYBACK_LIFECYCLE
enum {AVPlayerItemStatusUnknown,AVPlayerItemStatusReadyToPlay,AVPlayerItemStatusFailed};
@interface Resource : NSObject
@property int removedObservers;
@property int invalidations;
@property int cancellations;
@property int removals;
- (void)removeTaskObserver:(id)observer forKeyPath:(NSString*)path;
- (void)invalidate;
- (void)cancelLoading;
- (void)removeFromSuperview;
@end
@implementation Resource
- (void)removeTaskObserver:(id)observer forKeyPath:(NSString*)path { self.removedObservers++; }
- (void)invalidate { self.invalidations++; }
- (void)cancelLoading { self.cancellations++; }
- (void)removeFromSuperview { self.removals++; }
@end
@interface CDEpisode : Resource
@property double position;
@property NSString *objectHash;
@end
@implementation CDEpisode @end
@interface ICDiagnosticLogger : NSObject
+ (instancetype)shared;
- (void)logEvent:(NSString*)event message:(NSString*)message metadata:(NSDictionary*)metadata;
@end
@implementation ICDiagnosticLogger
+ (instancetype)shared { static id logger; if (!logger) logger=[self new]; return logger; }
- (void)logEvent:(NSString*)event message:(NSString*)message metadata:(NSDictionary*)metadata {}
@end
@interface AVPlayerItem : Resource
@property int status;
@property NSError *error;
@end
@implementation AVPlayerItem @end
@interface AVPlayer : Resource
@property float rate;
@property AVPlayerItem *currentItem;
@property int removedTimeObservers;
@property int pauses;
- (void)pause;
- (void)removeTimeObserver:(id)observer;
@end
@implementation AVPlayer
- (void)pause { self.rate=0;self.pauses++; }
- (void)removeTimeObserver:(id)observer { self.removedTimeObservers++; }
@end
@interface ICStreamingCacheLoader : Resource
@property BOOL cacheTerminal;
@property NSString *leaseToken;
@property NSError *terminalError;
@property int stops;
@property int detaches;
@property int discards;
- (void)stop;
- (void)detachFromPlaybackAndContinueCaching;
- (void)cancelAndDiscardPartialCache;
@end
@implementation ICStreamingCacheLoader
- (void)stop {self.stops++;}
- (void)detachFromPlaybackAndContinueCaching {self.detaches++;}
- (void)cancelAndDiscardPartialCache {self.discards++;}
@end
@interface CacheManager : NSObject
+ (instancetype)sharedCacheManager;
- (void)finishStreamingCacheForEpisode:(CDEpisode*)episode leaseToken:(NSString*)token;
@end
@implementation CacheManager
+ (instancetype)sharedCacheManager {return [self new];}
- (void)finishStreamingCacheForEpisode:(CDEpisode*)episode leaseToken:(NSString*)token {}
@end
@interface ChapterGenerator : NSObject
+ (instancetype)shared;
- (void)cancelGeneratedAudioVerification;
@end
static int verificationCancellations;
@implementation ChapterGenerator
+ (instancetype)shared {return [self new];}
- (void)cancelGeneratedAudioVerification {verificationCancellations++;}
@end
@interface PlaybackManager : NSObject {void *_chapterTimesIdx;void *_artworkTimesIdx;}
@property CDEpisode *playingEpisode;
@property (readonly,getter=isReady) BOOL ready;
@property (readonly) BOOL failed;
@property NSError *playbackError;
@property BOOL changingEpisode;
@property int state;
@property (readonly,getter=isPaused) BOOL paused;
@property AVPlayer *player;
@property Resource *mediaAsset;
@property Resource *playerView;
@property Resource *controlTimer;
@property Resource *playbackUserActivity;
@property ICStreamingCacheLoader *streamCacheLoader;
@property BOOL streamingCacheActive;
@property double streamingCacheProgress;
@property BOOL streamingCacheComplete;
@property BOOL isAutoSkipping;
@property id lastAutoSkipDate;
@property id autoSkipMarkers;
@property id autoSkipConfiguration;
@property NSUInteger chapterLoadGeneration;
@property BOOL generatedAudioVerificationCompleted;
@property id audioVerificationSourceURL;
@property BOOL chaptersUseGeneratedAnalysis;
@property BOOL generatedChapterAudioVerified;
@property BOOL automaticChapterSkippingAudioUnverified;
@property BOOL generatedChapterTimelineUnverified;
@property BOOL transcriptAudioVerified;
@property id verifiedTranscriptSnapshot;
@property id pendingGeneratedChapters;
@property id originalChapterTimeline;
@property int suppressedSkipMarker;
@property id audioSnapshotAsset;
@property id audioSnapshotAnchor;
@property id audioContentGenerationAnchor;
@property id verifiedAnalysisSnapshot;
@property id playbackObserver;
@property id temporaryPositionObserver;
@property id savedPositionObserver;
@property id embeddedChaptersForPersistence;
@property id chapters;
@property id artworks;
@property int saves;
@property int updates;
@property int handoverEnds;
@property int remoteClears;
@property int directPlays;
+ (instancetype)playbackManager;
- (void)close;
- (void)closeAndSaveCurrentPosition:(BOOL)save;
- (void)_saveCurrentPlaybackPosition;
- (void)_endNextItemHandover;
- (void)_setupRemotePlaybackCenterWithEpisode:(CDEpisode*)episode;
- (void)_sendUpdateNotification;
- (void)simulateFailure;
- (void)play;
- (void)pause;
@end
static PlaybackManager *currentManager;
@interface AudioSession : NSObject
@property CDEpisode *episode;
@property int clears;
@property int reopens;
@property int pausedSleepTimers;
@property BOOL reopenedAutostart;
@property CDEpisode *reopenedEpisode;
+ (instancetype)sharedAudioSession;
- (void)clear;
- (void)pauseSleepTimer;
- (void)togglePlay;
- (void)updateNowPlayingInfo;
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(double)time autostart:(BOOL)autostart preservingPlaybackSource:(BOOL)preserve;
@end
static AudioSession *session;
@implementation AudioSession
+ (instancetype)sharedAudioSession {return session;}
- (void)clear {self.clears++;self.episode=nil;}
- (void)pauseSleepTimer {self.pausedSleepTimers++;}
- (void)updateNowPlayingInfo {}
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(double)time autostart:(BOOL)autostart preservingPlaybackSource:(BOOL)preserve {self.reopens++;self.reopenedEpisode=episode;self.reopenedAutostart=autostart;}
// TOGGLE
@end
@implementation PlaybackManager
+ (instancetype)playbackManager {return currentManager;}
- (void)_saveCurrentPlaybackPosition {self.saves++;}
- (void)_endNextItemHandover {self.handoverEnds++;}
- (void)_setupRemotePlaybackCenterWithEpisode:(CDEpisode*)episode {if(!episode)self.remoteClears++;}
- (void)_sendUpdateNotification {self.updates++;}
- (void)play {self.directPlays++;}
- (void)pause {self.player.rate=0;}
- (void)simulateFailure {__weak PlaybackManager *weakSelf=self;
// FAILURE
}
// METHODS
@end
static int failures;
static void check(BOOL ok,NSString *why) {if(!ok){fprintf(stderr,"FAIL: %s\n",why.UTF8String);failures++;}}
static PlaybackManager *makePlayer(BOOL ready) {
PlaybackManager *p=[PlaybackManager new];currentManager=p;session=[AudioSession new];p.playingEpisode=[CDEpisode new];p.playingEpisode.position=42;session.episode=p.playingEpisode;p.state=ready?RunningState:InitializedState;
 p.player=[AVPlayer new];p.player.rate=ready?1:0;p.player.currentItem=[AVPlayerItem new];p.player.currentItem.status=AVPlayerItemStatusFailed;p.player.currentItem.error=[NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11800 userInfo:@{NSLocalizedDescriptionKey:@"AV wrapper"}];
 p.mediaAsset=[Resource new];p.playerView=[Resource new];p.controlTimer=[Resource new];p.playbackUserActivity=[Resource new];p.streamCacheLoader=[ICStreamingCacheLoader new];p.streamCacheLoader.cacheTerminal=YES;p.streamCacheLoader.terminalError=[NSError errorWithDomain:@"ICStreamingCacheErrorDomain" code:503 userInfo:@{NSLocalizedDescriptionKey:@"Publisher HTTP 503"}];
 p.playbackObserver=[NSObject new];p.temporaryPositionObserver=[NSObject new];p.savedPositionObserver=[NSObject new];p.transcriptAudioVerified=YES;p.autoSkipMarkers=@[@1];return p;
}
int main(void) {@autoreleasepool {
 testDefaults=[[NSUserDefaults alloc] initWithSuiteName:[@"MediaFailure." stringByAppendingString:NSUUID.UUID.UUIDString]];
 __block int ended=0;id observer=[[NSNotificationCenter defaultCenter] addObserverForName:PlaybackManagerDidEndNotification object:nil queue:nil usingBlock:^(NSNotification*n){ended++;}];
 for(NSNumber *loaded in @[@NO,@YES]) {
  PlaybackManager *p=makePlayer(loaded.boolValue);CDEpisode *episode=p.playingEpisode;AVPlayer *player=p.player;AVPlayerItem *item=player.currentItem;Resource *asset=p.mediaAsset,*view=p.playerView,*timer=p.controlTimer,*activity=p.playbackUserActivity;ICStreamingCacheLoader *loader=p.streamCacheLoader;NSError *error=loader.terminalError;int endedBefore=ended,verificationsBefore=verificationCancellations;
  [p simulateFailure];
  check(p.playingEpisode==episode && session.episode==episode && session.clears==0,@"Media failure must preserve selected episode and AudioSession for reading");
  check(p.failed && !p.ready && p.paused,@"Media failure must expose a paused failed state, not loading");
  check(p.playbackError==error,@"Media failure must expose the concrete HTTP error, not discard it behind AVFoundation");
  check(p.updates==1 && ended==endedBefore,@"Media failure must update visible state without sending DidEnd");
  check(!p.player && !p.mediaAsset && !p.playerView && !p.controlTimer && !p.streamCacheLoader,@"Failed media must release all active resources");
  check(item.removedObservers==4 && player.removedObservers==1 && player.removedTimeObservers==3 && episode.removedObservers==1,@"Media failure must detach KVO and all time observers exactly once");
  check(asset.cancellations==1 && view.removals==1 && timer.invalidations==1 && activity.invalidations==1 && p.handoverEnds==1,@"Media failure must cancel asset, view, timer and background activity");
  check(loader.stops==1 && loader.detaches==0 && loader.discards==0,@"Terminal failed stream must stop without creating another download");
  check(verificationCancellations==verificationsBefore+1 && !p.transcriptAudioVerified && !p.autoSkipMarkers,@"Failure cleanup must invalidate generated timing proof");
  check(p.saves==loaded.boolValue,@"An unready failed stream must not overwrite saved position with invalid media time");
  check(session.reopens==0 && p.directPlays==0,@"Media failure must never retry automatically");
  [session togglePlay];check(session.reopens==1 && session.reopenedEpisode==episode && session.reopenedAutostart,@"Explicit Play must reopen the retained episode through AudioSession");
  [p close];check(!p.playingEpisode && !session.episode && session.clears==1 && ended==endedBefore+1,@"Intentional close after failure must clear identity and send DidEnd");
  check(!p.failed && !p.playbackError,@"Intentional close must clear the obsolete failure state");
 }
 PlaybackManager *p=makePlayer(YES);int endedBefore=ended;[p close];check(p.saves==1 && !p.player && !p.playingEpisode && !session.episode && ended==endedBefore+1,@"Normal close keeps position-save, resource cleanup and DidEnd behavior");[p close];check(ended==endedBefore+1 && session.clears==1,@"Repeated close must not duplicate DidEnd");
 [[NSNotificationCenter defaultCenter] removeObserver:observer];
 if(failures)return 1;puts("Playback failed-media cleanup, retained reading and explicit retry passed");return 0;
}}
'''
fixture=fixture.replace('// METHODS','\n'.join(methods)).replace('// FAILURE',failure_body).replace('// TOGGLE',toggle)
start = source.index('typedef NS_ENUM(NSInteger, ICPlaybackState)')
fixture = fixture.replace('// PLAYBACK_LIFECYCLE', source[start:source.index('\n#if TARGET_OS_IPHONE', start)])
with tempfile.TemporaryDirectory(prefix='playback-media-failure-') as temp:
    path=Path(temp)/'main.m';binary=Path(temp)/'run';path.write_text(fixture)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-Wno-nullability-completeness','-framework','Foundation',str(path),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
