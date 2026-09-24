#!/usr/bin/env python3
"""Execute the production next-chapter method at chapter timeline boundaries."""
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlaybackManager.m").read_text()
start = source.index("- (void) nextChapter\n")
end = source.index("\n- (void) previousChapter", start)
method = source[start:end]

program = r'''
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
@interface ICMetadataChapter : NSObject
@property CMTime start;
@end
@implementation ICMetadataChapter @end
@interface PlaybackManager : NSObject
@property NSInteger currentChapter;
@property NSArray *chapters;
@property NSTimeInterval soughtTime;
@property NSUInteger seeks;
- (BOOL)generatedArtifactTimingIsCurrent;
- (void)seekToTime:(NSTimeInterval)time tolerance:(BOOL)tolerance;
- (void)nextChapter;
@end
@implementation PlaybackManager
- (BOOL)generatedArtifactTimingIsCurrent { return YES; }
- (void)seekToTime:(NSTimeInterval)time tolerance:(BOOL)tolerance {
    self.soughtTime = time;
    self.seeks++;
}
METHOD
@end
static int check(NSString *name, NSArray *chapters, NSInteger current,
                 NSUInteger expectedSeeks, NSTimeInterval expectedTime) {
    PlaybackManager *player = [PlaybackManager new];
    player.chapters = chapters;
    player.currentChapter = current;
    player.soughtTime = -1;
    [player nextChapter];
    BOOL passed = player.seeks == expectedSeeks && player.soughtTime == expectedTime;
    printf("%s: %s (seeks=%lu, target=%.0f)\n", name.UTF8String,
           passed ? "PASS" : "FAIL", (unsigned long)player.seeks, player.soughtTime);
    return passed ? 0 : 1;
}
int main(void) { @autoreleasepool {
    ICMetadataChapter *first = [ICMetadataChapter new];
    first.start = CMTimeMakeWithSeconds(30, 1000);
    ICMetadataChapter *second = [ICMetadataChapter new];
    second.start = CMTimeMakeWithSeconds(60, 1000);
    int failures = 0;
    failures += check(@"Before first chapter jumps to its start", @[first, second], -1, 1, 30);
    failures += check(@"First chapter advances to second", @[first, second], 0, 1, 60);
    failures += check(@"Last chapter does not seek", @[first, second], 1, 0, -1);
    failures += check(@"Empty timeline does not seek", @[], -1, 0, -1);
    failures += check(@"Missing timeline does not seek", nil, -1, 0, -1);
    failures += check(@"Single upcoming chapter remains reachable", @[first], -1, 1, 30);
    failures += check(@"Single current chapter does not seek", @[first], 0, 0, -1);
    return failures ? 1 : 0;
} }
'''.replace("METHOD", method)

with tempfile.TemporaryDirectory(prefix="instacast-next-chapter-") as directory:
    path = Path(directory)
    (path / "main.m").write_text(program)
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    "-framework", "CoreMedia", str(path / "main.m"),
                    "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
