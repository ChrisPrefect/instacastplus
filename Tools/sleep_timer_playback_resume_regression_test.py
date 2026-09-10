#!/usr/bin/env python3
"""Exercise production playback resume and sleep timer expiry with Foundation timers."""
import ast
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
# Reuse the existing diagnostics recorder and AudioSession test declarations.
harness = ast.parse((root / 'Tools/sleep_timer_diagnostics_runtime_test.py').read_text())
values = {}
for node in harness.body:
    if isinstance(node, ast.Assign) and isinstance(node.targets[0], ast.Name):
        try:
            values[node.targets[0].id] = ast.literal_eval(node.value)
        except (ValueError, TypeError):
            pass

def method(source, signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if not depth:
            return source[start:end + 1]
    raise ValueError(signature)

audio = (root / 'Classes/AudioSession.m').read_text()
player = (root / 'Classes/PlaybackManager.m').read_text()
audio_methods = [method(audio, s) for s in [
    '- (NSDictionary*)sleepTimerDiagnosticsMetadata', '- (void)_logSleepTimerEvent:',
    '- (void)setTimerValue:(PlaybackStopTimeValue)timerValue diagnosticReason:',
    '- (void) setTimerValue:', '- (void)setTimerWithDuration:', '- (void)stopPlaybackTimer:',
    '- (void)startSleepTimerIfNeeded',
]]
player_methods = [method(player, s) for s in [
    '- (void) play\n', '- (void) pause\n', '- (void) playPause\n',
    '- (MPRemoteCommandHandlerStatus) _playEvent:', '- (BOOL) isPaused\n',
    '- (BOOL) isPodcastPlaying\n', '- (void) _sendUpdateNotification\n',
]]
player_stub = r'''
// AVFoundation/CoreMedia, cache and persistence are minimal local substitutes.
// Keep the iPhone branch compiled; streamCacheLoader=nil selects loaded playback.
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
typedef struct { int64_t value; int32_t timescale; } CMTime;
typedef NSInteger MPRemoteCommandHandlerStatus;
enum { MPRemoteCommandHandlerStatusSuccess=0, RunningState=1, ShouldRunState=2, InitializedState=3 };
@interface MPRemoteCommandEvent:NSObject @end
@implementation MPRemoteCommandEvent @end
@interface ItemStub:NSObject
- (CMTime)currentTime;
@end
@implementation ItemStub
- (CMTime)currentTime { return (CMTime){600,1}; }
@end
@interface PlayerStub:NSObject
@property float rate;
@property ItemStub* currentItem;
- (void)pause;
@end
@implementation PlayerStub
- (void)pause { self.rate=0; }
@end
@interface CacheManager:NSObject
+ (instancetype)sharedCacheManager;
- (BOOL)episodeIsCached:(id)episode;
@end
@implementation CacheManager
+ (instancetype)sharedCacheManager { static id c; if(!c)c=[self new]; return c; }
- (BOOL)episodeIsCached:(id)episode { return NO; }
@end
NSString* PlayerReplayAfterPause=@"PlayerReplayAfterPause";
NSString* PlaybackManagerDidUpdateNotification=@"MPPlaybackManagerDidUpdateNotification";
#define SEND_UPDATE [self _sendUpdateNotification];
@interface PlaybackManager:NSObject
@property (readonly,getter=isPaused) BOOL paused;
@property (readonly,getter=isPodcastPlaying) BOOL podcastPlaying;
@property double time;
@property BOOL hasBeenPlayingWhenInterrupted;
@property NSInteger state;
@property PlayerStub* player;
@property NSDate* seekingPositionChangeDate;
@property NSDate* lastPauseDate;
@property NSDate* playStartDate;
@property float playbackRate;
@property NSInteger speedControl;
@property id streamCacheLoader;
@property Episode* playingEpisode;
@property double duration;
@property double seekingPosition;
+ (instancetype)playbackManager;
- (void)pause;
- (void)play;
- (void)playPause;
- (MPRemoteCommandHandlerStatus)_playEvent:(MPRemoteCommandEvent*)event;
- (void)updateNowPlayingInfo;
- (void)_sendUpdateNotification;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager { static id p; if(!p)p=[self new]; return p; }
- (float)rateFromSpeedControl:(NSInteger)speed {return 1;}
- (void)seekToTime:(NSTimeInterval)time {self.time=time;}
- (void)openWithEpisode:(Episode*)episode at:(NSTimeInterval)time autostart:(BOOL)start {abort();}
- (void)_saveCurrentPlaybackPosition {}
- (void)updateNowPlayingInfo {}
PLAYER_METHODS
@end
'''.replace('PLAYER_METHODS', '\n'.join(player_methods))
preamble = values['preamble'].replace('- (void)stopPlaybackTimer:(NSTimer*)timer;', '- (void)startSleepTimerIfNeeded;\n- (void)stopPlaybackTimer:(NSTimer*)timer;')
start = preamble.index('@interface PlaybackManager:')
end = preamble.index('@interface ICSharePlayCoordinator:')
player_implementation = player_stub[player_stub.index('@implementation PlaybackManager'):]
player_declarations = player_stub[:player_stub.index('@implementation PlaybackManager')]
preamble = preamble[:start] + player_declarations + preamble[end:]
main = r'''
#define CHECK(c) do {if(!(c)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c);return 1;}}while(0)
int main(int argc, const char** argv){@autoreleasepool{
 NSString* mode=argc>1 ? @(argv[1]) : @"play";
 NSInteger minutes=argc>2 ? [@(argv[2]) integerValue] : 3;
 NSString* suite=[@"sleep-resume-test." stringByAppendingString:NSUUID.UUID.UUIDString];
 defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];App=[AppStub new];
 [defaults setBool:YES forKey:ScreenTimerAlwaysActive];
 [defaults setBool:YES forKey:IntelligentSleepTimerAlwaysActive];
 [defaults setBool:YES forKey:DeviceMovementIntelligentSleep];
 [defaults setBool:NO forKey:ScreenTouchIntelligentSleep];
 [defaults setInteger:minutes forKey:DefaultIntelligentSleepTimer];
 AudioSession* s=[AudioSession sharedAudioSession];s.episode=[Episode new];s.episode.objectHash=@"target";
 PlaybackManager* p=[PlaybackManager playbackManager];
 p.player=[PlayerStub new];p.player.currentItem=[ItemStub new];p.player.rate=1;p.state=RunningState;p.playingEpisode=s.episode;
 s.timerValue=minutes;
 CHECK(s.playbackTimer.valid && s.stopDate.timeIntervalSinceNow>minutes*60-1 && p.podcastPlaying);
 // Reach the production expiry deterministically, including the 20-minute TestFlight case.
 s.stopDate=[NSDate dateWithTimeIntervalSinceNow:-1];
 [s stopPlaybackTimer:s.playbackTimer];
 CHECK(p.paused && s.timerValue==minutes && s.playbackTimer.valid && s.stopDate==nil);
 if([mode hasPrefix:@"async-"]) {
     dispatch_semaphore_t done=dispatch_semaphore_create(0);
     dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
         [p _playEvent:nil];
         dispatch_semaphore_signal(done);
     });
     CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
     CHECK(p.podcastPlaying && !s.stopDate);
     if([mode isEqual:@"async-paused"]) [p pause];
     if([mode isEqual:@"async-disabled"]) [defaults setBool:NO forKey:ScreenTimerAlwaysActive];
     if([mode isEqual:@"async-carplay"]) {
         [defaults setBool:YES forKey:DisableSleepTimerInCarPlay];s.carPlay=YES;
     }
     [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
     if([mode isEqual:@"async-resume"]) {
         CHECK(p.podcastPlaying && s.stopDate.timeIntervalSinceNow>minutes*60-1 && s.playbackTimer.valid);
         s.stopDate=[NSDate dateWithTimeIntervalSinceNow:-1];
         [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
         CHECK(p.paused && !s.stopDate);
     } else {
         CHECK(!s.stopDate);
         CHECK(p.podcastPlaying != [mode isEqual:@"async-paused"]);
     }
     [s.playbackTimer invalidate];[defaults removePersistentDomainForName:suite];
     printf("PASS: %s rechecks playback and settings on main\n",mode.UTF8String);
     return 0;
 }
 if([mode isEqual:@"policy"]) {
     [defaults setBool:NO forKey:ScreenTimerAlwaysActive];
     [p play];
     CHECK(p.podcastPlaying && !s.stopDate);
     [p pause];
     [defaults setBool:YES forKey:ScreenTimerAlwaysActive];
     [defaults setBool:YES forKey:DisableSleepTimerInCarPlay];
     s.carPlay=YES;
     [p play];
     CHECK(p.podcastPlaying && !s.stopDate);
     [p pause];s.carPlay=NO;
     [defaults setInteger:0 forKey:DefaultIntelligentSleepTimer];
     [defaults setInteger:3 forKey:LastSelectedSleepTimer];
     [p play];
     CHECK(s.stopDate.timeIntervalSinceNow>179);
     NSDate* deadline=s.stopDate;
     [p play];
     CHECK(s.stopDate==deadline);
     [s setTimerWithDuration:91];deadline=s.stopDate;
     [p play];
     CHECK(s.stopDate==deadline && s.stopDate.timeIntervalSinceNow>90);
     [p pause];[p play];
     CHECK(s.stopDate==deadline);
     p.player=nil;s.timerValue=0;
     [p play];
     CHECK(!s.stopDate && !s.playbackTimer);
     [defaults removePersistentDomainForName:suite];
     puts("PASS: disabled, CarPlay, saved duration, existing deadlines and unloaded playback");
     return 0;
 }
 if([mode isEqual:@"playPause"]) [p playPause];
 else if([mode isEqual:@"remote"]) [p _playEvent:nil];
 else [p play];
 CHECK(p.podcastPlaying && !p.paused);
 CHECK(s.stopDate.timeIntervalSinceNow>minutes*60-1);
 CHECK([[ICDiagnosticLogger shared].events.lastObject[@"message"] isEqual:@"playback-start"]);
 NSDate* deadline=s.stopDate;
 [p play];
 CHECK(s.stopDate==deadline);
 if([mode isEqual:@"motion"]) {
     s.stopDate=[NSDate dateWithTimeIntervalSinceNow:12];
     [s setTimerValue:minutes diagnosticReason:@"motion"];
     CHECK(s.stopDate.timeIntervalSinceNow>minutes*60-1 && s.sleepTimerMotionResetCount==1);
 }
 if([mode isEqual:@"setter"]) {
     // The normal UI Play buttons still explicitly apply the selected duration.
     s.timerValue=minutes;
 }
 NSDate* lastTickBeforeRunLoop=s.lastSleepTimerTick;
 [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
 BOOL tickFired=[s.lastSleepTimerTick compare:lastTickBeforeRunLoop]==NSOrderedDescending;
 CHECK(tickFired && p.podcastPlaying);
 CHECK(s.playbackTimer.valid && s.stopDate.timeIntervalSinceNow>0);
 s.stopDate=[NSDate dateWithTimeIntervalSinceNow:-1];
 [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.2]];
 CHECK(p.paused && !s.stopDate);
 CHECK([[ICDiagnosticLogger shared].events.lastObject[@"message"] isEqual:@"pause-completed"]);
 [s.playbackTimer invalidate];[defaults removePersistentDomainForName:suite];
 printf("PASS: %s resumes with a %ld-minute countdown and pauses when the timer fires\n",mode.UTF8String,(long)minutes);
}return 0;}
'''
declarations = '\n'.join(f'NSString* {c}=@"{c}";' for c in values['constants'])
with tempfile.TemporaryDirectory(prefix='instacast-sleep-resume-') as directory:
    probe_dir = Path(directory)
    file = probe_dir / 'probe.m'
    file.write_text('#import <Foundation/Foundation.h>\n' + declarations + '\n' + preamble + '\n' + '\n'.join(audio_methods) + '\n@end\n' + player_implementation + main)
    binary = probe_dir / 'probe'
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation',str(file),'-o',str(binary)],check=True)
    for mode in ['play', 'playPause', 'remote', 'motion', 'setter', 'policy',
                 'async-resume', 'async-paused', 'async-disabled', 'async-carplay']:
        subprocess.run([str(binary), mode], check=True)
    subprocess.run([str(binary), 'remote', '20'], check=True)
print('Sleep timer playback resume regression checks passed')
