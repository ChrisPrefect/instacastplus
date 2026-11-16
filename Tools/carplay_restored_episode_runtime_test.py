#!/usr/bin/env python3
"""Execute the CarPlay selection method with restored, loaded and loading episodes.

Foundation doubles replace CarPlay/AVPlayer; the selection and paused-state
methods are extracted unchanged from production. No simulator is required.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(signature)


scene = (ROOT / "Classes/InstacastSceneDelegate.m").read_text()
playback = (ROOT / "Classes/PlaybackManager.m").read_text()
audio_session = (ROOT / "Classes/AudioSession.m").read_text()
widget = (ROOT / "Classes/WidgetDataExporter.m").read_text()
source = r'''
#import <Foundation/Foundation.h>
// PLAYBACK_LIFECYCLE
@interface CDEpisode : NSObject
@end
@implementation CDEpisode
@end
@interface ProbePlayer : NSObject
@property float rate;
@end
@implementation ProbePlayer
@end
@interface PlaybackManager : NSObject
@property (strong) CDEpisode* playingEpisode;
@property (strong) ProbePlayer* player;
@property NSInteger state;
@property NSInteger playCalls;
@property NSInteger pauseCalls;
@property BOOL ready;
@property BOOL failed;
@property (readonly, getter=isPaused) BOOL paused;
+ (instancetype)playbackManager;
- (void)play;
- (void)pause;
- (void)playPause;
- (void)updateNowPlayingInfo;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager {
    static PlaybackManager* instance;
    if (!instance) instance = [self new];
    return instance;
}
PAUSED_METHOD
- (void)play { self.playCalls++; self.player.rate = 1; }
- (void)pause { self.pauseCalls++; self.player.rate = 0; }
- (void)updateNowPlayingInfo {}
PLAY_PAUSE_METHOD
@end
@interface AudioSession : NSObject
@property (strong) CDEpisode* episode;
@property NSInteger openCalls;
@property NSTimeInterval openedAt;
@property BOOL autostart;
@property BOOL queueUpCurrent;
@property BOOL preservingPlaybackSource;
+ (instancetype)sharedAudioSession;
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(NSTimeInterval)time autostart:(BOOL)autostart;
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(NSTimeInterval)time autostart:(BOOL)autostart preservingPlaybackSource:(BOOL)preserve;
- (void)togglePlay;
- (void)updateNowPlayingInfo;
@end
@implementation AudioSession
+ (instancetype)sharedAudioSession {
    static AudioSession* instance;
    if (!instance) instance = [self new];
    return instance;
}
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(NSTimeInterval)time autostart:(BOOL)autostart {
    self.episode = episode; self.openCalls++; self.openedAt = time;
    self.autostart = autostart; self.queueUpCurrent = queue;
}
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(NSTimeInterval)time autostart:(BOOL)autostart preservingPlaybackSource:(BOOL)preserve {
    self.preservingPlaybackSource=preserve;
    [self playEpisode:episode queueUpCurrent:queue at:time autostart:autostart];
}
- (void)updateNowPlayingInfo {}
TOGGLE_METHOD
@end
@interface DataManager : NSObject
- (CDEpisode*)episodeWithObjectHash:(NSString*)hash;
@end
@implementation DataManager
- (CDEpisode*)episodeWithObjectHash:(NSString*)hash {return nil;}
@end
#define DMANAGER [DataManager new]
@interface WidgetDataExporter : NSObject
@property NSDictionary *lastPlayedEpisodeDict;
+ (instancetype)sharedExporter;
- (void)performPlayPause;
@end
@implementation WidgetDataExporter
+ (instancetype)sharedExporter {return [self new];}
- (void)performPlayPause {
    PlaybackManager *pm=[PlaybackManager playbackManager];
    AudioSession *as=[AudioSession sharedAudioSession];
    BOOL exportImmediately=NO;
    NSString *action=@"playpause";
    WIDGET_ACTION
}
@end
@interface InstacastSceneDelegate : NSObject
@property NSInteger presentations;
- (void)carPlayUpdateNowPlayingTemplateConfiguration;
- (void)carPlayShowNowPlayingTemplate;
- (void)performDeepLinkPlayPause;
@end
@implementation InstacastSceneDelegate
- (void)carPlayUpdateNowPlayingTemplateConfiguration {}
- (void)carPlayShowNowPlayingTemplate { self.presentations++; }
SELECTION_METHOD
- (void)performDeepLinkPlayPause {
    BOOL handledPlayerAction=NO;
    NSString *action=@"playpause";
    DEEP_LINK_ACTION
}
@end
int main() { @autoreleasepool {
    PlaybackManager* pman = [PlaybackManager playbackManager];
    AudioSession* audio = [AudioSession sharedAudioSession];
    InstacastSceneDelegate* scene = [InstacastSceneDelegate new];
    CDEpisode* selected = [CDEpisode new];
    CDEpisode* other = [CDEpisode new];
    int failures = 0;
    // Restore selects AudioSession.episode without opening a PlaybackManager item.
    NSArray* names = @[@"restored selection without player", @"loaded paused episode",
        @"loaded playing episode", @"episode still loading", @"different episode",
        @"empty session", @"restored selection with another loaded episode",
        @"retained failed episode"];
    for (NSInteger i = 0; i < names.count; i++) {
        audio.episode = i == 5 ? nil : (i == 4 ? other : selected);
        audio.openCalls = 0; pman.playCalls = 0; scene.presentations = 0;
        pman.playingEpisode = (i == 0 || i == 5) ? nil : ((i == 4 || i == 6) ? other : selected);
        pman.player = pman.playingEpisode ? [ProbePlayer new] : nil;
        pman.failed = i == 7;
        pman.ready = i != 3 && pman.player != nil && !pman.failed;
        if (pman.failed) pman.player=nil;
        pman.player.rate = i == 2 ? 1 : 0;
        pman.state = i == 3 ? InitializedState : (pman.failed ? FailedState :
            (pman.player ? (i == 2 ? RunningState : PausedState) : IdleState));
        BOOL needsOpen = (i == 0 || i >= 4);
        [scene carPlayPlayEpisode:selected at:6001];
        BOOL passed = audio.openCalls == (needsOpen ? 1 : 0)
            && pman.playCalls == (i == 1 ? 1 : 0) && scene.presentations == 1;
        if (needsOpen) passed &= audio.episode == selected && audio.openedAt == (i == 7 ? 0 : 6001)
            && audio.autostart && !audio.queueUpCurrent;
        if (i == 7) passed &= audio.preservingPlaybackSource;
        printf("%s: %s (open=%ld, resume=%ld)\n", passed ? "PASS" : "FAIL",
            [names[i] UTF8String], (long)audio.openCalls, (long)pman.playCalls);
        failures += !passed;
    }
    for (NSString *entry in @[@"widget",@"deep-link"]) {
        for (NSInteger state=0;state<4;state++) {
            // failed, ready paused, ready playing, and still loading
            audio.episode=selected;audio.openCalls=0;audio.preservingPlaybackSource=NO;
            pman.playingEpisode=selected;pman.failed=state==0;pman.ready=state==1 || state==2;
            pman.player=state==0 ? nil : [ProbePlayer new];pman.player.rate=state==2 ? 1 : 0;
            pman.state=state==0 ? FailedState : (state==3 ? InitializedState : (state==1 ? PausedState : RunningState));
            pman.playCalls=0;pman.pauseCalls=0;
            if ([entry isEqual:@"widget"]) [[WidgetDataExporter new] performPlayPause];
            else [scene performDeepLinkPlayPause];
            BOOL passed=audio.openCalls==(state==0 ? 1 : 0)
                && pman.playCalls==(state==1 ? 1 : 0)
                && pman.pauseCalls==(state>=2 ? 1 : 0);
            if(state==0) passed &= audio.episode==selected && audio.autostart
                && audio.preservingPlaybackSource && !audio.queueUpCurrent;
            printf("%s: %s state=%ld (open=%ld, resume=%ld, pause=%ld)\n",passed?"PASS":"FAIL",entry.UTF8String,(long)state,(long)audio.openCalls,(long)pman.playCalls,(long)pman.pauseCalls);
            failures += !passed;
        }
    }
    return failures ? 1 : 0;
} }
'''
source = source.replace("PAUSED_METHOD", method(playback, "- (BOOL) isPaused\n"))
start = playback.index('typedef NS_ENUM(NSInteger, ICPlaybackState)')
source = source.replace('// PLAYBACK_LIFECYCLE', playback[start:playback.index('\n#if TARGET_OS_IPHONE', start)])
source = source.replace("PLAY_PAUSE_METHOD", method(playback, "- (void) playPause\n"))
source = source.replace("TOGGLE_METHOD", method(audio_session, "- (void) togglePlay\n"))
source = source.replace("SELECTION_METHOD", method(scene, "- (void)carPlayPlayEpisode:"))
source = source.replace("WIDGET_ACTION", method(method(widget, "          episodeIdentifier:(NSString *)episodeIdentifier\n           chapterStartTime:(NSNumber *)chapterStartTime {"), 'if ([action isEqualToString:@"playpause"])'))
source = source.replace("DEEP_LINK_ACTION", method(method(scene, "- (void)_handleWidgetDeepLink:(NSURL *)url {"), 'if ([action isEqualToString:@"playpause"])'))
with tempfile.TemporaryDirectory(prefix="instacast-carplay-restore-") as temp:
    path = Path(temp) / "probe.m"
    path.write_text(source)
    binary = Path(temp) / "probe"
    subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
