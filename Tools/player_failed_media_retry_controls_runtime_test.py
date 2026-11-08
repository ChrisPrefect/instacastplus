#!/usr/bin/env python3
"""Run the production transport-control update across pending/failed/ready media."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlaybackControlsViewController.m").read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
method = extract("- (void) updateControlsUI") + "\n" + extract("- (void) togglePlay:")
program = r'''
#import <Foundation/Foundation.h>
@interface NSString (Localize) @property(readonly) NSString *ls; @end
@implementation NSString (Localize) - (NSString*)ls { return self; } @end
static id ICPlayerTransportImage(NSString *name) { return name; }
static NSInteger UIControlStateNormal=0;
static NSString *PlayerSkipBackPeriod=@"skipBack";
static NSInteger ICHapticFeedbackMedium=1;
static void PlayHapticFeedback(NSInteger type) {}
@interface PlaybackManager:NSObject
@property BOOL ready,failed,paused,movingVideo;
@property id playingEpisode;
@property NSInteger playCalls,pauseCalls;
+ (instancetype)playbackManager;
- (BOOL)forwardSkipJumpsToNextChapter;
- (void)play; - (void)pause;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager { static id p;if(!p)p=[self new];return p; }
- (BOOL)forwardSkipJumpsToNextChapter { return YES; }
- (void)play { self.playCalls++; } - (void)pause { self.pauseCalls++; }
@end
@interface AudioSession:NSObject @property NSInteger retryCalls; + (instancetype)sharedAudioSession; - (void)togglePlay; @end
@implementation AudioSession
+ (instancetype)sharedAudioSession { static id p;if(!p)p=[self new];return p; }
- (void)togglePlay { self.retryCalls++; }
@end
@interface Control:NSObject
@property BOOL enabled,prioritizesVideoDevices;
@property NSString *accessibilityLabel;
@property id image;
- (void)setImage:(id)image forState:(NSInteger)state;
@end
@implementation Control
- (void)setImage:(id)image forState:(NSInteger)state { self.image=image; }
@end
@interface Controls:NSObject
@property Control *routeButton,*playButton,*backButton,*forwardButton,*timeSlider;
@property BOOL forwardChapterSkipActive;
@end
@implementation Controls
- (instancetype)init { if((self=[super init])) { self.routeButton=[Control new];self.playButton=[Control new];self.backButton=[Control new];self.forwardButton=[Control new];self.timeSlider=[Control new]; } return self; }
- (void)_updateSkipButtonImages {}
- (NSInteger)_configuredSkipSecondsForKey:(NSString*)key { return 30; }
METHOD
@end
int main() { @autoreleasepool {
 Controls *ui=[Controls new];PlaybackManager *p=[PlaybackManager playbackManager];int failures=0;
 #define CHECK(label,condition) do { BOOL ok=(condition);printf("%s: %s\n",label,ok?"PASS":"FAIL");failures+=!ok; } while(0)
 p.paused=YES;p.playingEpisode=[NSObject new];[ui updateControlsUI];
 CHECK("pending media does not permit duplicate play",!ui.playButton.enabled && !ui.backButton.enabled && !ui.forwardButton.enabled && !ui.timeSlider.enabled);
 p.failed=YES;[ui updateControlsUI];
 CHECK("failed selected media allows explicit Play retry",ui.playButton.enabled && [ui.playButton.image isEqual:@"Player Play"] && [ui.playButton.accessibilityLabel isEqual:@"Play"]);
 [ui togglePlay:nil];
 CHECK("failed Play uses existing episode reopen action",[AudioSession sharedAudioSession].retryCalls==1 && p.playCalls==0);
 CHECK("failed media cannot seek or skip",!ui.backButton.enabled && !ui.forwardButton.enabled && !ui.timeSlider.enabled && !ui.forwardChapterSkipActive);
 p.playingEpisode=nil;[ui updateControlsUI];
 CHECK("failure without selected episode cannot retry",!ui.playButton.enabled);
 p.failed=NO;p.ready=YES;p.paused=NO;p.playingEpisode=[NSObject new];[ui updateControlsUI];
 CHECK("ready transport remains enabled",ui.playButton.enabled && ui.backButton.enabled && ui.forwardButton.enabled && ui.timeSlider.enabled && ui.forwardChapterSkipActive && [ui.playButton.image isEqual:@"Player Pause"]);
 [ui togglePlay:nil];
 CHECK("ready Pause retains direct transport action",p.pauseCalls==1 && [AudioSession sharedAudioSession].retryCalls==1);
 return failures?1:0;
} }
'''.replace("METHOD", method)
with tempfile.TemporaryDirectory(prefix="instacast-retry-controls-") as directory:
    tmp = Path(directory)
    (tmp / "main.m").write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(tmp / "main.m"), "-o", str(tmp / "test")], check=True)
    subprocess.run([str(tmp / "test")], check=True)
