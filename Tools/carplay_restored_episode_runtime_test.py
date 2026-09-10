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
source = r'''
#import <Foundation/Foundation.h>
enum { IdleState, InitializedState, ShouldRunState, RunningState };
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
@property (readonly, getter=isPaused) BOOL paused;
+ (instancetype)playbackManager;
- (void)play;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager {
    static PlaybackManager* instance;
    if (!instance) instance = [self new];
    return instance;
}
PAUSED_METHOD
- (void)play { self.playCalls++; self.player.rate = 1; }
@end
@interface AudioSession : NSObject
@property (strong) CDEpisode* episode;
@property NSInteger openCalls;
@property NSTimeInterval openedAt;
@property BOOL autostart;
@property BOOL queueUpCurrent;
+ (instancetype)sharedAudioSession;
- (void)playEpisode:(CDEpisode*)episode queueUpCurrent:(BOOL)queue at:(NSTimeInterval)time autostart:(BOOL)autostart;
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
@end
@interface InstacastSceneDelegate : NSObject
@property NSInteger presentations;
- (void)carPlayUpdateNowPlayingTemplateConfiguration;
- (void)carPlayShowNowPlayingTemplate;
@end
@implementation InstacastSceneDelegate
- (void)carPlayUpdateNowPlayingTemplateConfiguration {}
- (void)carPlayShowNowPlayingTemplate { self.presentations++; }
SELECTION_METHOD
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
        @"empty session", @"restored selection with another loaded episode"];
    for (NSInteger i = 0; i < names.count; i++) {
        audio.episode = i == 5 ? nil : (i == 4 ? other : selected);
        audio.openCalls = 0; pman.playCalls = 0; scene.presentations = 0;
        pman.playingEpisode = (i == 0 || i == 5) ? nil : ((i == 4 || i == 6) ? other : selected);
        pman.player = pman.playingEpisode ? [ProbePlayer new] : nil;
        pman.player.rate = i == 2 ? 1 : 0;
        pman.state = i == 3 ? InitializedState : (pman.player ? RunningState : IdleState);
        BOOL needsOpen = (i == 0 || i >= 4);
        [scene carPlayPlayEpisode:selected at:6001];
        BOOL passed = audio.openCalls == (needsOpen ? 1 : 0)
            && pman.playCalls == (i == 1 ? 1 : 0) && scene.presentations == 1;
        if (needsOpen) passed &= audio.episode == selected && audio.openedAt == 6001
            && audio.autostart && !audio.queueUpCurrent;
        printf("%s: %s (open=%ld, resume=%ld)\n", passed ? "PASS" : "FAIL",
            [names[i] UTF8String], (long)audio.openCalls, (long)pman.playCalls);
        failures += !passed;
    }
    return failures ? 1 : 0;
} }
'''
source = source.replace("PAUSED_METHOD", method(playback, "- (BOOL) isPaused\n"))
source = source.replace("SELECTION_METHOD", method(scene, "- (void)carPlayPlayEpisode:"))
with tempfile.TemporaryDirectory(prefix="instacast-carplay-restore-") as temp:
    path = Path(temp) / "probe.m"
    path.write_text(source)
    binary = Path(temp) / "probe"
    subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(path), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
