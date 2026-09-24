#!/usr/bin/env python3
"""Run the player's actual notice method against pending and publisher states."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlayerInfoViewController_v5.m").read_text()
start = source.index("- (NSString*)_audioIdentityNotice")
brace = source.index("{", start)
depth = 0
for end in range(brace, len(source)):
    depth += (source[end] == "{") - (source[end] == "}")
    if depth == 0:
        method = source[start:end + 1]
        break

program = r'''
#import <Foundation/Foundation.h>
@interface PlaybackManager : NSObject
@property BOOL generatedChapterTimelineUnverified;
@property BOOL generatedAudioVerificationCompleted;
+ (instancetype)playbackManager;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager { static id instance; if (!instance) instance = [self new]; return instance; }
@end
@interface Player : NSObject
@property NSArray *transcriptCues;
@property NSDictionary *selectedTranscriptDescriptor;
@property BOOL timingVerified;
- (BOOL)_transcriptTimingVerified;
- (NSString*)_audioIdentityNotice;
@end
@implementation Player
- (BOOL)_transcriptTimingVerified { return self.timingVerified; }
METHOD
@end
int main() { @autoreleasepool {
    Player *player = [Player new];
    PlaybackManager *playback = [PlaybackManager playbackManager];
    player.transcriptCues = @[];
    playback.generatedChapterTimelineUnverified = YES;
    playback.generatedAudioVerificationCompleted = NO;
    NSString *pending = [player _audioIdentityNotice];
    BOOL pendingPass = pending == nil;
    printf("pending verification: %s\n", pendingPass ? "PASS" : "FAIL: shown as unavailable before a result exists");
    playback.generatedChapterTimelineUnverified = NO;
    playback.generatedAudioVerificationCompleted = YES;
    player.transcriptCues = @[@"publisher cue"];
    player.selectedTranscriptDescriptor = @{@"isGenerated": @NO};
    NSString *publisher = [player _audioIdentityNotice];
    BOOL publisherPass = publisher == nil;
    printf("publisher transcript: %s\n", publisherPass ? "PASS" : "FAIL: generated-audio warning applied to publisher transcript");
    player.selectedTranscriptDescriptor = @{@"isGenerated": @YES};
    player.timingVerified = YES;
    BOOL verifiedPass = [player _audioIdentityNotice] == nil;
    printf("verified generated transcript: %s\n", verifiedPass ? "PASS" : "FAIL");
    playback.generatedChapterTimelineUnverified = YES;
    BOOL failedChaptersPass = [[player _audioIdentityNotice] isEqualToString:@"Chapters could not be loaded."];
    playback.generatedChapterTimelineUnverified = NO;
    player.timingVerified = NO;
    BOOL failedTranscriptPass = [[player _audioIdentityNotice] isEqualToString:@"Jumping to transcript passages is unavailable."];
    printf("completed failures remain visible: %s\n", failedChaptersPass && failedTranscriptPass ? "PASS" : "FAIL");
    return pendingPass && publisherPass && verifiedPass && failedChaptersPass && failedTranscriptPass ? 0 : 1;
} }
'''.replace("METHOD", method)

with tempfile.TemporaryDirectory(prefix="instacast-notice-state-") as directory:
    tmp = Path(directory)
    (tmp / "main.m").write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    str(tmp / "main.m"), "-o", str(tmp / "test")], check=True)
    subprocess.run([str(tmp / "test")], check=True)
