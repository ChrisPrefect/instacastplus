#!/usr/bin/env python3
"""Exercise timer entry points, sensor resets, expiry observers and widget export."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
script=root/'Tools/sleep_timer_playback_resume_regression_test.py'
ns={'__file__':str(script)}
exec(script.read_text().split('with tempfile.TemporaryDirectory')[0],ns)
application=(root/'Classes/Application.m').read_text()
exporter=(root/'Classes/WidgetDataExporter.m').read_text()
snapshot_chunk=exporter[exporter.index('        // Sleep timer\n'):exporter.index('        // Next/prev episode availability')].replace('[self _iso8601String:as.stopDate]', 'as.stopDate.description')
sensor='''
// Feed one deterministic sample into the production CoreMotion callback.
NSString* ApplicationDidDetectMotionNotification=@"motion";
typedef struct { double x,y,z; } CMAcceleration;
@interface CMAccelerometerData:NSObject
@property CMAcceleration acceleration;
@end
@implementation CMAccelerometerData @end
@interface CMMotionManager:NSObject
@property double accelerometerUpdateInterval;
@end
@implementation CMMotionManager
- (BOOL)isAccelerometerAvailable {return YES;}
- (void)startAccelerometerUpdatesToQueue:(NSOperationQueue*)queue withHandler:(void(^)(CMAccelerometerData*,NSError*))handler {
    CMAccelerometerData* data=[CMAccelerometerData new];data.acceleration=(CMAcceleration){1,0,0};handler(data,nil);
}
@end
@interface SensorProbe:NSObject { NSTimer* myidleTimer; double lastAccelX,lastAccelY,lastAccelZ; }
@property CMMotionManager* motionManager;
- (void)resetIdleTimer;
- (void)idleTimerExceeded;
- (void)deviceMotionDetection;
- (void)trigger:(NSString*)kind;
@end
@implementation SensorProbe
- (void)idleTimerExceeded {}
- (void)trigger:(NSString*)kind {
    if([kind isEqual:@"motion"]) {
        [self deviceMotionDetection];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    } else if([kind isEqual:@"volume"]) {
        [self observeValueForKeyPath:@"outputVolume" ofObject:nil change:nil context:nil];
    } else [self resetIdleTimer];
}
'''+ '\n'.join(ns['method'](application, signature) for signature in [
    '-(void)resetIdleTimer', '- (void)_resetSleepTimerForActivity:',
    '-(void)deviceMotionDetection', '-(void) observeValueForKeyPath:',
])+'\n@end\n'
main=r'''
@interface RemainingObserver:NSObject
@property double remaining;
@end
@implementation RemainingObserver
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)obj change:(NSDictionary*)change context:(void*)context {self.remaining=[obj timerRemainingTime];}
@end

#define CHECK(c) do {if(!(c)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c);status=1;}}while(0)
int main(int argc,const char** argv){@autoreleasepool{
 int status=0;
 NSString* mode=@(argv[1]);
 NSString* suite=[@"external-timer-proof." stringByAppendingString:NSUUID.UUID.UUIDString];
 defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];App=[AppStub new];
 AudioSession* s=[AudioSession sharedAudioSession];s.episode=[Episode new];s.episode.objectHash=@"target";
 PlaybackManager* p=[PlaybackManager playbackManager];p.player=[PlayerStub new];p.player.currentItem=[ItemStub new];p.player.rate=1;p.state=RunningState;p.playingEpisode=s.episode;
 if([mode isEqual:@"carplay"]) {
   s.carPlay=YES;[defaults setBool:YES forKey:DisableSleepTimerInCarPlay];
   s.timerValue=5; CHECK(!s.stopDate && !s.playbackTimer);
   [s setTimerWithDuration:1200];
   printf("CarPlay connected, disable enabled: external timer active=%d remaining=%.1f\n",s.playbackTimer.valid,s.timerRemainingTime);
   CHECK(!s.stopDate && !s.playbackTimer);
   [p pause];[s setTimerWithDuration:1200];[p play];CHECK(s.timerRemainingTime==0);
   [defaults setBool:NO forKey:DisableSleepTimerInCarPlay];[s setTimerWithDuration:1200];
   CHECK(s.playbackTimer.valid && s.timerRemainingTime>1199);
 } else if([mode hasPrefix:@"sensor-"] || [mode hasPrefix:@"cancel-"] || [mode hasPrefix:@"disabled-"]) {
   NSString* kind=[mode componentsSeparatedByString:@"-"].lastObject;
   NSString* key=[kind isEqual:@"touch"] ? ScreenTouchIntelligentSleep : ([kind isEqual:@"motion"] ? DeviceMovementIntelligentSleep : VolumeChangeIntelligentSleep);
   BOOL cancelled=[mode hasPrefix:@"cancel-"];
   BOOL disabled=[mode hasPrefix:@"disabled-"];
   [defaults setBool:YES forKey:IntelligentSleepTimerAlwaysActive];[defaults setBool:!disabled forKey:key];[defaults setInteger:3 forKey:DefaultIntelligentSleepTimer];
   [s setTimerWithDuration:1200];
   s.stopDate=[NSDate dateWithTimeIntervalSinceNow:120];
   if(cancelled) s.timerValue=0;
   [[SensorProbe new] trigger:kind];
   if(cancelled) CHECK(!s.playbackTimer && !s.stopDate && s.timerRemainingTime==0);
   else if(disabled) CHECK(s.timerRemainingTime>119 && s.timerRemainingTime<=120);
   else {
     CHECK(s.timerRemainingTime>1199 && s.timerValue==1);
     CHECK([s.lastSleepTimerResetReason isEqual:kind]);
   }
 } else if([mode isEqual:@"selection"]) {
   [s setTimerWithDuration:600];[p pause];
   [defaults setDouble:120 forKey:UncompletedSleepTimeInterval];
   s.timerValue=5;
   CHECK(s.timerRemainingTime==300);
 } else if([mode isEqual:@"expiry"]) {
   [defaults setBool:YES forKey:ScreenTimerAlwaysActive];
   [defaults setBool:YES forKey:IntelligentSleepTimerAlwaysActive];
   [defaults setBool:YES forKey:ScreenTouchIntelligentSleep];
   [defaults setInteger:3 forKey:DefaultIntelligentSleepTimer];s.timerValue=3;
   RemainingObserver* observer=[RemainingObserver new];
   [s addObserver:observer forKeyPath:@"timerRemainingTime" options:0 context:nil];
   s.stopDate=[NSDate dateWithTimeIntervalSinceNow:-1];[s stopPlaybackTimer:s.playbackTimer];
   CHECK(p.paused && s.timerRemainingTime==0 && !s.playbackTimer.valid);
   CHECK(observer.remaining==s.timerRemainingTime);
   [s removeObserver:observer forKeyPath:@"timerRemainingTime"];
 } else if([mode isEqual:@"widget"]) {
   [s setTimerWithDuration:1200];[p pause];
   AudioSession* as=s;NSMutableDictionary* snapshot=[NSMutableDictionary new];
   SNAPSHOT_CHUNK
   printf("Paused armed timer: remaining=%.1f exported-timer-fields=%lu\n",s.timerRemainingTime,(unsigned long)snapshot.count);
   CHECK(snapshot[@"sleepTimerRemaining"]!=nil);
   CHECK(snapshot[@"sleepTimerStopDate"]==nil);
 } else if([mode hasPrefix:@"ui"]) {
   [defaults setBool:NO forKey:ScreenTimerAlwaysActive];[defaults setBool:NO forKey:IntelligentSleepTimerAlwaysActive];[defaults setInteger:0 forKey:DefaultIntelligentSleepTimer];
   if([mode isEqual:@"ui-smart"]) {
     [defaults setBool:YES forKey:IntelligentSleepTimerAlwaysActive];[defaults setBool:YES forKey:ScreenTouchIntelligentSleep];[defaults setInteger:3 forKey:DefaultIntelligentSleepTimer];
   }
   NSTimeInterval expected=[mode isEqual:@"ui-preset"] ? 300 : 1200;
   if([mode isEqual:@"ui-preset"]) s.timerValue=5;
   else [s setTimerWithDuration:1200];
   [p pause];
   printf("External duration=1200; paused: remaining=%.1f\n",s.timerRemainingTime);
   [[PlaybackControlsViewController new] togglePlay:nil];
   printf("UI resume: active=%d remaining=%.1f playing=%d\n",s.playbackTimer.valid,s.timerRemainingTime,p.isPodcastPlaying);
   CHECK(s.playbackTimer.valid && s.timerRemainingTime>expected-1 && s.timerRemainingTime<=expected);
 }
 [s.playbackTimer invalidate];[defaults removePersistentDomainForName:suite];return status;
}}
'''
main=main.replace('SNAPSHOT_CHUNK',snapshot_chunk)
with tempfile.TemporaryDirectory(prefix='instacast-external-proof-') as d:
 p=Path(d);f=p/'probe.m'
 f.write_text('#import <Foundation/Foundation.h>\n'+ns['declarations']+'\n'+ns['preamble']+'\n'+'\n'.join(ns['audio_methods'])+'\n@end\n'+ns['player_implementation']+ns['controls_probe']+sensor+main)
 subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation',str(f),'-o',str(p/'probe')],check=True)
 failures=[]
 for mode in ['carplay','sensor-touch','sensor-motion','sensor-volume',
              'cancel-touch','cancel-motion','cancel-volume',
              'disabled-touch','disabled-motion','disabled-volume',
              'ui','ui-smart','ui-preset','widget','expiry','selection']:
  result=subprocess.run([str(p/'probe'),mode],capture_output=True,text=True)
  print(('PASS' if result.returncode==0 else 'FAIL')+': '+mode)
  if result.returncode: print(result.stdout,result.stderr)
  if result.returncode: failures.append(mode)
 assert not failures, f'Failed timer scenarios: {failures}'
