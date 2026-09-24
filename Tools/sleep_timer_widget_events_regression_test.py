#!/usr/bin/env python3
"""Run timer/playback notifications through the production widget event handlers."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
script = root / 'Tools/sleep_timer_playback_resume_regression_test.py'
ns = {'__file__': str(script)}
exec(script.read_text().split('with tempfile.TemporaryDirectory')[0], ns)
source = (root / 'Classes/WidgetDataExporter.m').read_text().split('@implementation WidgetDataExporter', 1)[1]
method = ns['method']
observing = method(source, '- (void)startObserving')
registrations = [line.strip() for line in observing.splitlines()
                 if '[nc addObserver:self' in line and
                 ('PlaybackManagerDidUpdateNotification' in line or 'AudioSessionSleepTimer' in line)]
signatures = ['- (void)_playbackDidUpdate:', '- (void)_sleepTimerExpired:',
              '- (void)_scheduleDebouncedNowPlayingExport', '- (void)_debouncedNowPlayingExport']
if '- (void)_sleepTimerChanged:' in source:
    signatures.append('- (void)_sleepTimerChanged:')
handlers = '\n'.join(method(source, signature) for signature in signatures)
fixture = r'''
static NSUInteger reloads;
static const NSTimeInterval kNowPlayingExportThrottleInterval = 0.75;
@interface WidgetKitHelper:NSObject
+ (void)reloadNowPlayingTimeline;
+ (void)reloadNowPlayingTimelineForStateChange;
@end
@implementation WidgetKitHelper
+ (void)reloadNowPlayingTimeline {reloads++;}
+ (void)reloadNowPlayingTimelineForStateChange {reloads++;}
@end
@interface WidgetDataExporter:NSObject
@property (copy) dispatch_block_t pendingNowPlayingExportBlock;
@property NSNumber* lastObservedPlaybackPaused;
@property double exportedRemaining;
@property BOOL exportedPaused;
@property NSUInteger exports;
@end
@implementation WidgetDataExporter
- (void)startObserving {
    NSNotificationCenter* nc=NSNotificationCenter.defaultCenter;
    REGISTRATIONS
}
- (void)exportNowPlayingSnapshot {
    self.exports++;
    self.exportedRemaining=[AudioSession sharedAudioSession].timerRemainingTime;
    self.exportedPaused=[PlaybackManager playbackManager].paused;
}
- (void)_trackListeningTime {}
- (void)_refreshStatsDuringPlaybackIfNeeded {}
HANDLERS
@end
#define CHECK(c) do {if(!(c)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c);status=1;}}while(0)
int main(int argc,const char** argv){@autoreleasepool {
 int status=0;NSString* mode=@(argv[1]);
 NSString* suite=[@"sleep-widget-events." stringByAppendingString:NSUUID.UUID.UUIDString];
 defaults=[[NSUserDefaults alloc] initWithSuiteName:suite];App=[AppStub new];
 AudioSession* s=[AudioSession sharedAudioSession];s.episode=[Episode new];s.episode.objectHash=@"test";
 PlaybackManager* p=[PlaybackManager playbackManager];p.player=[PlayerStub new];p.player.currentItem=[ItemStub new];p.state=RunningState;p.playingEpisode=s.episode;
 p.player.rate=([mode isEqual:@"pause"] || [mode isEqual:@"ticks"] || [mode isEqual:@"sensors"]) ? 1 : 0;
 if(![mode isEqual:@"set-paused"]) [s setTimerWithDuration:1200];
 WidgetDataExporter* exporter=[WidgetDataExporter new];[exporter startObserving];
 [p _sendUpdateNotification];
 [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.85]];
 [exporter exportNowPlayingSnapshot];reloads=0;exporter.exports=0;
 if([mode isEqual:@"set-paused"]) [s setTimerWithDuration:1200];
 else if([mode isEqual:@"cancel-paused"]) s.timerValue=0;
 else if([mode isEqual:@"pause"]) [p pause];
 else if([mode isEqual:@"resume"]) [p play];
 else {
     for(int i=0;i<20;i++) {
         if([mode isEqual:@"sensors"]) [s resetSleepTimerForActivity:@"motion"];
         else [s stopPlaybackTimer:s.playbackTimer];
         [p _sendUpdateNotification];
     }
 }
 [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
 if([mode isEqual:@"ticks"] || [mode isEqual:@"sensors"]) CHECK(reloads==0);
 else {
     CHECK(exporter.exports>0 && reloads>0);
     CHECK(exporter.exportedPaused==p.paused);
     if([mode isEqual:@"cancel-paused"]) CHECK(exporter.exportedRemaining==0);
     else CHECK(exporter.exportedRemaining>1198);
 }
 [[NSNotificationCenter defaultCenter] removeObserver:exporter];
 [s.playbackTimer invalidate];[defaults removePersistentDomainForName:suite];return status;
}}
'''.replace('REGISTRATIONS', '\n'.join(registrations)).replace('HANDLERS', handlers)

with tempfile.TemporaryDirectory(prefix='instacast-widget-events-') as directory:
    path = Path(directory)
    file = path / 'probe.m'
    file.write_text('#import <Foundation/Foundation.h>\n' + ns['declarations'] + ns['preamble'] +
                    '\n'.join(ns['audio_methods']) + '\n@end\n' + ns['player_implementation'] + fixture)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    str(file), '-o', str(path / 'probe')], check=True)
    failures = []
    for mode in ['set-paused', 'cancel-paused', 'pause', 'resume', 'ticks', 'sensors']:
        result = subprocess.run([str(path / 'probe'), mode], capture_output=True, text=True)
        print(('PASS' if result.returncode == 0 else 'FAIL') + ': ' + mode)
        if result.returncode:
            print(result.stdout + result.stderr)
            failures.append(mode)
    assert not failures, f'Widget event failures: {failures}'
