#!/usr/bin/env python3
"""Execute the production transcript admission predicate with audio-proof states."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlayerInfoViewController_v5.m").read_text()

def method(signature):
    start = source.index(signature)
    while source.find(";", start) < source.find("{", start):
        start = source.index(signature, start + len(signature))
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if not depth:
            return source[start:end + 1]
    raise AssertionError(signature)

methods = method("- (BOOL)_transcriptDescriptorIsCurrent:")
if "- (BOOL)_generatedTranscriptMayLoadForEpisodeHash:" in source:
    methods += "\n" + method("- (BOOL)_generatedTranscriptMayLoadForEpisodeHash:")
methods += "\n" + method("- (BOOL)_transcriptTimingVerified")
methods += "\n" + method("- (void)_applyLoadedTranscriptCues:")
methods += "\n" + method("- (void)_updateTranscriptSyncTimerState")
program = r'''
#import <Foundation/Foundation.h>
@interface Episode:NSObject @property NSString *objectHash; @end
@implementation Episode @end
@interface PlaybackManager:NSObject
@property BOOL transcriptAudioVerified;
@property BOOL timingCurrent;
@property BOOL ready;
@property Episode *playingEpisode;
@property NSString *verifiedTranscriptSnapshot;
@property double time;
+ (instancetype)playbackManager;
- (BOOL)generatedArtifactTimingIsCurrent;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager { static id instance; if (!instance) instance=[self new]; return instance; }
- (BOOL)generatedArtifactTimingIsCurrent { return self.timingCurrent; }
@end
@interface TranscriptionEngine:NSObject
@property NSString *snapshot;
+ (instancetype)shared;
- (NSString*)transcriptSnapshotIdentifierFor:(NSString*)hash;
@end
@implementation TranscriptionEngine
+ (instancetype)shared { static id instance; if (!instance) instance=[self new]; return instance; }
- (NSString*)transcriptSnapshotIdentifierFor:(NSString*)hash { return self.snapshot; }
@end
@interface AudioSession:NSObject
@property Episode *episode;
+ (instancetype)sharedAudioSession;
@end
@implementation AudioSession
+ (instancetype)sharedAudioSession { static id s;if(!s)s=[self new];return s; }
@end
#define CDEpisode Episode
static NSUserDefaults *testDefaults;
#define USER_DEFAULTS testDefaults
static NSString *s_transcriptCachedEpisodeHash;
static NSArray *s_transcriptCachedCues,*s_transcriptCachedSources;
static NSDictionary *s_transcriptCachedDescriptor;
@interface View:NSObject @property id window; @end
@implementation View @end
@interface Player:NSObject
@property NSDictionary *selectedTranscriptDescriptor;
@property NSString *transcriptLoadedEpisodeHash;
@property NSArray *transcriptCues,*transcriptSources;
@property BOOL transcriptVisible,isViewLoaded,transcriptAvailable;
@property NSUInteger activeTranscriptCueIndex;
@property NSInteger rebuilds;
@property View *view;
@property NSTimer *transcriptSyncTimer;
- (BOOL)_generatedTranscriptMayLoadForEpisodeHash:(NSString*)hash;
@end
@implementation Player
- (void)_updateAudioIdentityNotice {}
- (void)_rebuildTranscriptLines { self.rebuilds++; }
- (void)_updateTranscriptPickerButton {}
- (void)_setTranscriptAvailableState:(BOOL)available { self.transcriptAvailable=available; }
- (void)_updateTranscriptCueForPlaybackTime:(double)time animated:(BOOL)animated {}
- (void)_focusTranscriptCueAtIndex:(NSUInteger)index animated:(BOOL)animated {}
- (void)_applyTranscriptVisibility {}
- (void)_prefetchTranscriptSourcesForEpisode:(Episode*)episode {}
- (void)_updateTranscriptLabelAppearance {}
METHODS
@end
int main() { @autoreleasepool {
 testDefaults=[[NSUserDefaults alloc] initWithSuiteName:[@"PlayerTextTest." stringByAppendingString:NSUUID.UUID.UUIDString]];
 Player *player=[Player new]; PlaybackManager *p=[PlaybackManager playbackManager];
 p.playingEpisode=[Episode new]; p.playingEpisode.objectHash=@"episode";
 [TranscriptionEngine shared].snapshot=@"srt-A";
 NSDictionary *d=@{@"isGenerated":@YES,@"transcriptSnapshot":@"srt-A"};
 int failures=0;
 #define CHECK(name, expected) do { BOOL actual=[player _transcriptDescriptorIsCurrent:d episodeHash:@"episode"]; printf("%s: %s\n",name,actual==(expected)?"PASS":"FAIL"); failures += actual != (expected); } while(0)
 CHECK("pending audio proof permits current text",YES);
 p.timingCurrent=YES;
 CHECK("unverified transcript audio permits current text",YES);
 p.transcriptAudioVerified=YES;p.verifiedTranscriptSnapshot=@"srt-A";
 CHECK("matching audio and current transcript",YES);
 p.playingEpisode.objectHash=@"different-episode";
 CHECK("same cached transcript after episode switch",NO);
 p.playingEpisode.objectHash=@"episode";p.timingCurrent=NO;
 CHECK("audio replacement does not hide current text",YES);
 p.timingCurrent=YES;[TranscriptionEngine shared].snapshot=@"srt-B";
 CHECK("transcript replaced after proof",NO);
 d=@{@"isGenerated":@YES,@"transcriptSnapshot":@"srt-B"};
 CHECK("new current text loads independently of old timing proof",YES);
 p.transcriptAudioVerified=NO;d=@{@"isGenerated":@NO};
 CHECK("publisher transcript uses its separate source contract",YES);
 player.selectedTranscriptDescriptor=d;player.transcriptLoadedEpisodeHash=@"episode";
 player.transcriptCues=@[@{@"start":@140.988,@"end":@148.514,@"text":@"Publisher cue"}];
 #define TIMING(name, expected) do { BOOL actual=[player _transcriptTimingVerified]; printf("%s: %s\n",name,actual==(expected)?"PASS":"FAIL"); failures += actual != (expected); } while(0)
 TIMING("publisher text with pending or failed media must not seek or follow",NO);
 CHECK("publisher text remains readable without ready media",YES);
 p.ready=YES;
 TIMING("publisher WebVTT must allow tap and automatic follow without generated audio proof",YES);
 p.ready=NO;
 TIMING("publisher timing is revoked when ready media is lost",NO);
 p.ready=YES;
 player.transcriptLoadedEpisodeHash=@"old-episode";
 TIMING("publisher transcript from previous episode must not seek",NO);
 player.transcriptLoadedEpisodeHash=@"episode";player.selectedTranscriptDescriptor=nil;
 TIMING("missing transcript source must not seek",NO);
 player.selectedTranscriptDescriptor=d;player.transcriptCues=@[@{@"start":@0,@"end":@3153600000.0,@"text":@"Untimed text",@"untimed":@YES}];
 TIMING("untimed publisher text must not claim synchronized playback",NO);
 player.transcriptCues=@[@{@"start":@140.988,@"end":@148.514,@"text":@"Generated cue"}];
 player.selectedTranscriptDescriptor=@{@"isGenerated":@YES,@"transcriptSnapshot":@"srt-B"};
 TIMING("generated transcript still requires matching audio proof",NO);
 p.transcriptAudioVerified=YES;p.verifiedTranscriptSnapshot=@"srt-B";
 TIMING("generated transcript with matching audio proof remains interactive",YES);
 p.ready=NO;p.transcriptAudioVerified=NO;p.timingCurrent=NO;p.verifiedTranscriptSnapshot=nil;
 player.transcriptCues=@[];player.selectedTranscriptDescriptor=nil;player.transcriptLoadedEpisodeHash=nil;
 player.transcriptVisible=YES;player.isViewLoaded=YES;player.view=[View new];player.view.window=[NSObject new];player.activeTranscriptCueIndex=NSNotFound;
 NSArray *readableCues=@[@{@"start":@12,@"end":@20,@"text":@"Server text remains readable without local audio."}];
 NSDictionary *currentDescriptor=@{@"isGenerated":@YES,@"transcriptSnapshot":@"srt-B"};
 [player _applyLoadedTranscriptCues:readableCues descriptor:currentDescriptor resolvedURL:@"file:///fixture.srt"];
 BOOL applied=player.transcriptCues.count==1 && player.transcriptAvailable && player.rebuilds==1 && [player.transcriptLoadedEpisodeHash isEqual:@"episode"] && !player.transcriptSyncTimer && ![player _transcriptTimingVerified];
 printf("actual cue application without audio proof, no follow timer: %s\n",applied?"PASS":"FAIL");failures+=!applied;
 [TranscriptionEngine shared].snapshot=@"srt-C";
 [player _applyLoadedTranscriptCues:@[@{@"text":@"stale result"}] descriptor:currentDescriptor resolvedURL:@"file:///fixture.srt"];
 BOOL staleRejected=player.rebuilds==1 && [player.transcriptCues isEqual:readableCues];
 printf("stale parser callback cannot overwrite current displayed text: %s\n",staleRejected?"PASS":"FAIL");failures+=!staleRejected;
 [player.transcriptSyncTimer invalidate];
 return failures ? 1 : 0;
} }
'''.replace("METHODS", methods)
with tempfile.TemporaryDirectory(prefix="instacast-transcript-binding-") as directory:
    tmp = Path(directory)
    (tmp / "main.m").write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    str(tmp / "main.m"), "-o", str(tmp / "test")], check=True)
    subprocess.run([str(tmp / "test")], check=True)
