#!/usr/bin/env python3
"""Exercise the production full-player state machine before/after media failure."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlayerController.m").read_text()
def extract(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
method = extract("- (void) _stateMachine") + "\n" + extract("- (void) playbackManagerDidUpdateNotification:")
enum = source[source.index("enum {"):source.index("} PlaybackViewControllerState;") + len("} PlaybackViewControllerState;")]
program = r'''
#import <Foundation/Foundation.h>
ENUM
@interface NSString (Localize) @property(readonly) NSString *ls; @end
@implementation NSString (Localize) - (NSString*)ls { return self; } @end
@interface UIImage:NSObject @end
@implementation UIImage @end
@interface CDFeed:NSObject @property NSURL *imageURL; @end
@implementation CDFeed @end
@interface CDEpisode:NSObject @property NSURL *imageURL; @property CDFeed *feed; @end
@implementation CDEpisode @end
@interface PlaybackManager:NSObject
@property BOOL ready,failed; @property NSInteger currentArtwork;
@property CDEpisode *playingEpisode; @property NSError *playbackError;
+ (instancetype)playbackManager;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager { static id p; if(!p)p=[self new]; return p; }
@end
@interface AudioSession:NSObject @property CDEpisode *episode; + (instancetype)sharedAudioSession; @end
@implementation AudioSession
+ (instancetype)sharedAudioSession { static id p;if(!p)p=[self new];return p; }
@end
@interface CacheManager:NSObject + (instancetype)sharedCacheManager; - (BOOL)episodeIsCached:(id)episode; @end
@implementation CacheManager
+ (instancetype)sharedCacheManager { static id p;if(!p)p=[self new];return p; }
- (BOOL)episodeIsCached:(id)episode { return NO; }
@end
@interface ImageCacheManager:NSObject
+ (instancetype)sharedImageCacheManager;
- (void)imageForURL:(NSURL*)url size:(NSInteger)size grayscale:(BOOL)gray sender:(id)sender completion:(void(^)(UIImage*))block;
@end
@implementation ImageCacheManager
+ (instancetype)sharedImageCacheManager { static id p;if(!p)p=[self new];return p; }
- (void)imageForURL:(NSURL*)url size:(NSInteger)size grayscale:(BOOL)gray sender:(id)sender completion:(void(^)(UIImage*))block {}
@end
@interface VDModalInfo:NSObject @property BOOL shown,closed; + (instancetype)modalInfoWithProgressLabel:(NSString*)label; - (void)show; - (void)close; @end
@implementation VDModalInfo
+ (instancetype)modalInfoWithProgressLabel:(NSString*)label { return [self new]; }
- (void)show { self.shown=YES; }
- (void)close { self.closed=YES; }
@end
@interface Info:NSObject @property BOOL transcriptAvailable,transcriptVisible; @property NSInteger reloads; - (void)reload; - (void)changeChapterImageIndex:(NSInteger)index; @end
@implementation Info
- (void)reload { self.reloads++; }
- (void)changeChapterImageIndex:(NSInteger)index {}
@end
@interface Controls:NSObject @property BOOL transcriptAvailable,transcriptVisible,observedFailed; @property NSInteger timeUpdates,controlUpdates; - (void)updateControlsUI; - (void)updateTimeUI; @end
@implementation Controls
- (void)updateControlsUI { self.controlUpdates++;self.observedFailed=[PlaybackManager playbackManager].failed; } - (void)updateTimeUI { self.timeUpdates++; }
@end
@interface Application:NSObject @property NSInteger networkAccessTechnology,errorCount; @property NSString *lastError; - (void)showBackgroundErrorWithTitle:(NSString*)title message:(NSString*)message; @end
@implementation Application
- (void)showBackgroundErrorWithTitle:(NSString*)title message:(NSString*)message { self.errorCount++;self.lastError=message; }
@end
static Application *App;
static NSInteger kICNetworkAccessTechnlogyEDGE=1;
@interface Player:NSObject { NSInteger _state; BOOL _viewDidAppear; }
@property VDModalInfo *loadingInfo; @property Info *infoViewController; @property Controls *controller; @property UIImage *image;
@property NSError *presentedPlaybackError;
- (void)_stateMachine;
@end
@implementation Player
- (instancetype)init { if((self=[super init])) { _state=LoadedState;_viewDidAppear=YES;self.infoViewController=[Info new];self.controller=[Controls new]; } return self; }
- (NSInteger)_episodeArtworkCacheSize { return 320; }
- (void)_updateDynamicTintColorWithImage:(UIImage*)image {}
- (void)_updateArtworkImage {}
METHOD
@end
int main() { @autoreleasepool {
 App=[Application new];App.networkAccessTechnology=2;
 PlaybackManager *p=[PlaybackManager playbackManager];p.playingEpisode=[CDEpisode new];[AudioSession sharedAudioSession].episode=p.playingEpisode;
 Player *player=[Player new];int failures=0;
 #define CHECK(label,condition) do { BOOL ok=(condition);printf("%s: %s\n",label,ok?"PASS":"FAIL");failures+=!ok; } while(0)
 [player _stateMachine];
 CHECK("episode content loads before media readiness",player.infoViewController.reloads==1);
 CHECK("pending media without transcript keeps loading indication",player.loadingInfo.shown);
 VDModalInfo *pending=player.loadingInfo;player.infoViewController.transcriptAvailable=YES;
 [player _stateMachine];
 CHECK("readable text is not covered by pending-media overlay",!player.loadingInfo && pending.closed);
 [player.controller updateControlsUI]; // paused KVO fires before the manager sets failed.
 NSInteger beforeFailureUpdates=player.controller.controlUpdates;
 p.failed=YES;p.playbackError=[NSError errorWithDomain:@"ICStreamingCacheErrorDomain" code:503 userInfo:@{NSLocalizedDescriptionKey:@"HTTP 503: audio server unavailable"}];
 [player playbackManagerDidUpdateNotification:nil];
 CHECK("completed failure notification refreshes final transport state",player.controller.observedFailed && player.controller.controlUpdates==beforeFailureUpdates+1);
 CHECK("media failure has no loading overlay",player.loadingInfo==nil);
 CHECK("concrete media error stays visible",[App.lastError isEqual:p.playbackError.localizedDescription] && App.errorCount==1);
 [player playbackManagerDidUpdateNotification:nil];
 CHECK("repeated failed updates do not repeat the error",App.errorCount==1);
 CHECK("unchanged failed updates do not repeat transport refresh",player.controller.controlUpdates==beforeFailureUpdates+1);
 p.failed=NO;p.playbackError=nil;p.ready=YES;[player _stateMachine];
 CHECK("media-ready transition refreshes dependent player content",player.infoViewController.reloads==2 && !player.loadingInfo);
 [player _stateMachine];
 CHECK("ready playback continues updating controls",player.controller.timeUpdates>0);
 return failures?1:0;
} }
'''.replace("ENUM", enum).replace("METHOD", method)
with tempfile.TemporaryDirectory(prefix="instacast-player-failure-") as directory:
    tmp = Path(directory)
    (tmp / "main.m").write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", str(tmp / "main.m"), "-o", str(tmp / "test")], check=True)
    subprocess.run([str(tmp / "test")], check=True)
