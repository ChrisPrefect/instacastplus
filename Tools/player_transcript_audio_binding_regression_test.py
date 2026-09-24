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
program = r'''
#import <Foundation/Foundation.h>
@interface Episode:NSObject @property NSString *objectHash; @end
@implementation Episode @end
@interface PlaybackManager:NSObject
@property BOOL transcriptAudioVerified;
@property BOOL timingCurrent;
@property Episode *playingEpisode;
@property NSString *verifiedTranscriptSnapshot;
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
@interface Player:NSObject
@property NSDictionary *selectedTranscriptDescriptor;
@property NSString *transcriptLoadedEpisodeHash;
@property NSArray *transcriptCues;
- (BOOL)_generatedTranscriptMayLoadForEpisodeHash:(NSString*)hash;
@end
@implementation Player
METHODS
@end
int main() { @autoreleasepool {
 Player *player=[Player new]; PlaybackManager *p=[PlaybackManager playbackManager];
 p.playingEpisode=[Episode new]; p.playingEpisode.objectHash=@"episode";
 [TranscriptionEngine shared].snapshot=@"srt-A";
 NSDictionary *d=@{@"isGenerated":@YES,@"transcriptSnapshot":@"srt-A"};
 int failures=0;
 #define CHECK(name, expected) do { BOOL actual=[player _transcriptDescriptorIsCurrent:d episodeHash:@"episode"]; printf("%s: %s\n",name,actual==(expected)?"PASS":"FAIL"); failures += actual != (expected); } while(0)
 CHECK("pending audio proof must not load",NO);
 p.timingCurrent=YES;
 CHECK("mismatched transcript must not load even with valid chapter proof",NO);
 p.transcriptAudioVerified=YES;p.verifiedTranscriptSnapshot=@"srt-A";
 CHECK("matching audio and current transcript",YES);
 p.playingEpisode.objectHash=@"different-episode";
 CHECK("same cached transcript after episode switch",NO);
 p.playingEpisode.objectHash=@"episode";p.timingCurrent=NO;
 CHECK("audio replaced after proof",NO);
 p.timingCurrent=YES;[TranscriptionEngine shared].snapshot=@"srt-B";
 CHECK("transcript replaced after proof",NO);
 d=@{@"isGenerated":@YES,@"transcriptSnapshot":@"srt-B"};
 CHECK("new transcript cannot inherit old proof",NO);
 p.transcriptAudioVerified=NO;d=@{@"isGenerated":@NO};
 CHECK("publisher transcript uses its separate source contract",YES);
 player.selectedTranscriptDescriptor=d;player.transcriptLoadedEpisodeHash=@"episode";
 player.transcriptCues=@[@{@"start":@140.988,@"end":@148.514,@"text":@"Publisher cue"}];
 #define TIMING(name, expected) do { BOOL actual=[player _transcriptTimingVerified]; printf("%s: %s\n",name,actual==(expected)?"PASS":"FAIL"); failures += actual != (expected); } while(0)
 TIMING("publisher WebVTT must allow tap and automatic follow without generated audio proof",YES);
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
 return failures ? 1 : 0;
} }
'''.replace("METHODS", methods)
with tempfile.TemporaryDirectory(prefix="instacast-transcript-binding-") as directory:
    tmp = Path(directory)
    (tmp / "main.m").write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    str(tmp / "main.m"), "-o", str(tmp / "test")], check=True)
    subprocess.run([str(tmp / "test")], check=True)
