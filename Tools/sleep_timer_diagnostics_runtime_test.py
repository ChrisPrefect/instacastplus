#!/usr/bin/env python3
"""Run the production timer setters/expiry with Foundation timers and a recorder."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'Classes/AudioSession.m').read_text()
def method(signature):
    start=source.index(signature); brace=source.index('{',start); depth=0
    for end in range(brace,len(source)):
        depth+=(source[end]=='{')-(source[end]=='}')
        if not depth:return source[start:end+1]
methods=[method(s) for s in ['- (NSDictionary*)sleepTimerDiagnosticsMetadata','- (void)_logSleepTimerEvent:', '- (void)setTimerValue:(PlaybackStopTimeValue)timerValue diagnosticReason:', '- (void) setTimerValue:', '- (void)setTimerWithDuration:', '- (void)_scheduleSleepTimerWithDuration:', '- (void)stopPlaybackTimer:']]
constants=['ScreenTimerAlwaysActive','IntelligentSleepTimerAlwaysActive','ScreenTouchIntelligentSleep','DeviceMovementIntelligentSleep','VolumeChangeIntelligentSleep','DeviceMovementSensitivity','DisableSleepTimerInCarPlay','DefaultIntelligentSleepTimer','LastSelectedSleepTimer','UncompletedSleepTimeInterval','AudioSessionSleepTimerDidExpireNotification','AudioSessionSleepTimerDidChangeNotification']
preamble=r'''
#import <Foundation/Foundation.h>
#import <execinfo.h>
#import <dlfcn.h>
typedef NSInteger PlaybackStopTimeValue;
enum { PlaybackStopTimeNoValue=0, PlaybackStopTime5min=5 };
static NSUserDefaults* defaults;
#define USER_DEFAULTS defaults
@interface Episode:NSObject
@property NSString* objectHash;
@end
@implementation Episode @end
@interface PlaybackManager:NSObject
@property BOOL paused;
@property double time;
@property BOOL hasBeenPlayingWhenInterrupted;
@property NSInteger pauseCount;
+ (instancetype)playbackManager;
- (void)pause;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager { static id p; if(!p)p=[self new]; return p; }
- (void)pause { self.paused=YES; self.pauseCount++; }
@end
@interface ICSharePlayCoordinator:NSObject
+ (instancetype)sharedCoordinator;
- (void)leaveSessionForLocalPlayback;
@end
@implementation ICSharePlayCoordinator
+ (instancetype)sharedCoordinator { static id p; if(!p)p=[self new]; return p; }
- (void)leaveSessionForLocalPlayback {}
@end
@interface AppStub:NSObject
@property NSInteger applicationState;
@end
@implementation AppStub @end
static AppStub* App;
@interface ICDiagnosticLogger:NSObject
@property NSMutableArray* events;
+ (instancetype)shared;
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata;
@end
@implementation ICDiagnosticLogger
+ (instancetype)shared { static ICDiagnosticLogger* p; if(!p){p=[self new];p.events=[NSMutableArray new];}return p; }
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata {
    [self.events addObject:@{@"message":message,@"metadata":[metadata copy]}];
}
@end
@interface AudioSession:NSObject
@property Episode* episode;
@property NSTimer* playbackTimer;
@property NSTimeInterval sleepTimerDuration;
@property NSTimeInterval pausedSleepTimerRemainingTime;
@property NSDate* stopDate;
@property (nonatomic) PlaybackStopTimeValue timerValue;
@property BOOL playerWasPlayingBeforeWentToBackground;
@property BOOL carPlay;
@property NSString* sleepTimerDiagnosticReason;
@property NSString* lastSleepTimerDiagnosticReason;
@property NSDate* lastSleepTimerDiagnosticDate;
@property PlaybackStopTimeValue lastLoggedSleepTimerValue;
@property NSDate* lastSleepTimerTick;
@property NSDate* lastSleepTimerResetDate;
@property NSString* lastSleepTimerResetReason;
@property NSUInteger sleepTimerTouchResetCount;
@property NSUInteger sleepTimerMotionResetCount;
@property NSUInteger sleepTimerVolumeResetCount;
+ (instancetype)sharedAudioSession;
- (void)stopPlaybackTimer:(NSTimer*)timer;
- (void)setTimerWithDuration:(NSTimeInterval)seconds;
@end
@implementation AudioSession
+ (instancetype)sharedAudioSession {static id s;if(!s)s=[self new];return s;}
- (BOOL)_isCarPlaySceneConnected {return self.carPlay;}
- (BOOL)_shouldDisableSleepTimerForCarPlay {return self.carPlay && [USER_DEFAULTS boolForKey:DisableSleepTimerInCarPlay];}
'''
main=r'''
@end
#define CHECK(c) do {if(!(c)){fprintf(stderr,"Failed line %d: %s\n",__LINE__,#c);return 1;}}while(0)
int main(){@autoreleasepool{
 NSString* suite=[@"sleep-diag-test." stringByAppendingString:NSUUID.UUID.UUIDString];
 defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];App=[AppStub new];
 AudioSession* s=[AudioSession sharedAudioSession];s.episode=[Episode new];s.episode.objectHash=@"target";
 NSMutableArray* events=[ICDiagnosticLogger shared].events;
 s.timerValue=5;
 CHECK(s.playbackTimer.valid && s.stopDate.timeIntervalSinceNow>299);
 CHECK([events.lastObject[@"metadata"][@"requestedMinutes"] integerValue]==5);
 CHECK(events.lastObject[@"metadata"][@"imageLoadAddress"]!=nil);
 for(int i=0;i<100;i++)[s setTimerValue:5 diagnosticReason:@"motion"];
 CHECK(s.sleepTimerMotionResetCount==100 && events.count==2);
 CHECK([s.sleepTimerDiagnosticsMetadata[@"motionResetCount"] integerValue]==100);
 CHECK([s.sleepTimerDiagnosticsMetadata[@"lastResetReason"] isEqual:@"motion"]);
 [s setTimerValue:5 diagnosticReason:@"touch"];
 [s setTimerValue:5 diagnosticReason:@"volume"];
 CHECK(s.sleepTimerTouchResetCount==1 && s.sleepTimerVolumeResetCount==1 && events.count==4);
 [s setTimerValue:10 diagnosticReason:@"volume"];
 CHECK(events.count==5 && s.stopDate.timeIntervalSinceNow>599);
 s.carPlay=YES;[defaults setBool:YES forKey:DisableSleepTimerInCarPlay];s.timerValue=5;
 CHECK(!s.playbackTimer && !s.stopDate && s.timerValue==0);
 CHECK([events.lastObject[@"metadata"][@"requestedMinutes"] integerValue]==5);
 CHECK([events.lastObject[@"metadata"][@"carPlayConnected"] boolValue]);
 s.carPlay=NO;
 [defaults setInteger:17 forKey:UncompletedSleepTimeInterval];s.timerValue=5;
 CHECK(s.stopDate.timeIntervalSinceNow>299 && ![defaults objectForKey:UncompletedSleepTimeInterval]);
 [s setTimerWithDuration:120];CHECK(s.stopDate.timeIntervalSinceNow>119);
 CHECK([events.lastObject[@"metadata"][@"requestedSeconds"] integerValue]==120);
 s.stopDate=[NSDate dateWithTimeIntervalSinceNow:-1];
 [s stopPlaybackTimer:s.playbackTimer];
 CHECK([PlaybackManager playbackManager].pauseCount==1 && !s.stopDate && !s.playbackTimer);
 CHECK([events.lastObject[@"message"] isEqual:@"pause-completed"]);
 CHECK([events.lastObject[@"metadata"][@"playbackPaused"] boolValue]);
 CHECK([events.lastObject[@"metadata"][@"lastTimerTick"] doubleValue]>0);
 BOOL sawExpired=NO;for(NSDictionary* e in events)if([e[@"message"] isEqual:@"expired"])sawExpired=YES;
 CHECK(sawExpired);
 [defaults setBool:YES forKey:ScreenTimerAlwaysActive];[defaults setInteger:5 forKey:DefaultIntelligentSleepTimer];
 [PlaybackManager playbackManager].paused=NO;
 s.timerValue=5;s.stopDate=[NSDate dateWithTimeIntervalSinceNow:-1];[s stopPlaybackTimer:s.playbackTimer];
 CHECK([PlaybackManager playbackManager].pauseCount==2 && s.timerValue==5 && !s.stopDate);
 CHECK(![events.lastObject[@"metadata"][@"timerValid"] boolValue]);
 [s.playbackTimer invalidate];[defaults removePersistentDomainForName:suite];
 puts("Production timer diagnostics runtime checks passed");
}return 0;}
'''
with tempfile.TemporaryDirectory(prefix='instacast-sleep-diag-') as d:
    p=Path(d);file=p/'probe.m'
    declarations='\n'.join(f'NSString* {c}=@"{c}";' for c in constants)
    file.write_text('#import <Foundation/Foundation.h>\n'+declarations+'\n'+preamble+'\n'+'\n'.join(methods)+main)
    subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation',str(file),'-o',str(p/'probe')],check=True)
    subprocess.run([str(p/'probe')],check=True)
