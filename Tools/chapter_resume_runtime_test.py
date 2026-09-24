#!/usr/bin/env python3
"""Run the production chapter-selection logic against durable defaults."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Classes/PlaybackManager.m').read_text()
signature = '- (NSTimeInterval)timeForChapterSelectionAtIndex:'
assert signature in source, 'Direct chapter selection does not yet remember per-chapter positions'
method = signature + source.split(signature, 1)[1].split('\n- (', 1)[0]
fixture = r'''
#import <Foundation/Foundation.h>
#import <math.h>
static NSUserDefaults *defaults;
#define USER_DEFAULTS defaults
NSString *PlayerRememberChapterPosition = @"RememberChapterPosition";
NSString *PlayerChapterPlaybackPositions = @"ChapterPlaybackPositions";
@interface CDEpisode : NSObject
@property NSString *objectHash;
@property double duration;
@end
@implementation CDEpisode @end
@interface PlaybackManager : NSObject
@property CDEpisode *playingEpisode;
@property double position;
@property double duration;
@end
@implementation PlaybackManager
METHOD
@end
static void check(double actual, double expected, const char *message) {
    if (!isfinite(actual) || fabs(actual - expected) > 0.001) { fprintf(stderr, "%s: %.3f != %.3f\n", message, actual, expected); exit(1); }
}
int main() { @autoreleasepool {
    NSString *suite = [@"ChapterResumeTest." stringByAppendingString:NSUUID.UUID.UUIDString];
    defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults registerDefaults:@{PlayerRememberChapterPosition: @YES}];
    CDEpisode *episode = [CDEpisode new]; episode.objectHash = @"episode-A"; episode.duration = 300;
    NSArray *times = @[@0, @100, @200];
    PlaybackManager *p = [PlaybackManager new]; p.playingEpisode = episode; p.duration = 300;
    p.position = 37.5 / 300;
    check([p timeForChapterSelectionAtIndex:1 chapterTimes:times episode:episode], 100, "First visit starts at chapter beginning");
    p.position = 148.25 / 300;
    check([p timeForChapterSelectionAtIndex:0 chapterTimes:times episode:episode], 37.5, "Returning resumes old chapter");
    p.position = 37.5 / 300;
    check([p timeForChapterSelectionAtIndex:0 chapterTimes:times episode:episode], 0, "Current chapter restarts");
    p.position = 0;
    check([p timeForChapterSelectionAtIndex:1 chapterTimes:times episode:episode], 148.25, "Other chapter keeps its position");
    // A fresh player and fresh defaults instance model returning after closing the app.
    p = [PlaybackManager new]; defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults registerDefaults:@{PlayerRememberChapterPosition: @YES}];
    check([p timeForChapterSelectionAtIndex:1 chapterTimes:times episode:episode], 148.25, "Position survives player recreation");
    CDEpisode *other = [CDEpisode new]; other.objectHash = @"episode-B";
    check([p timeForChapterSelectionAtIndex:1 chapterTimes:times episode:other], 100, "Episodes do not share positions");
    [defaults setBool:NO forKey:PlayerRememberChapterPosition];
    check([p timeForChapterSelectionAtIndex:1 chapterTimes:times episode:episode], 100, "Disabled setting always starts at beginning");
    [defaults setBool:YES forKey:PlayerRememberChapterPosition];
    check([p timeForChapterSelectionAtIndex:1 chapterTimes:@[@0,@110,@210] episode:episode], 110, "Changed chapter timeline discards stale positions");
    // The position getter returns the normalized target while an AVPlayer seek is pending.
    episode.objectHash = @"rapid-switch"; episode.duration = 305;
    p.playingEpisode = episode; p.duration = 305; p.position = 37.5 / 305;
    NSArray *boundaryTimes = @[@0, @200];
    double target = [p timeForChapterSelectionAtIndex:1 chapterTimes:boundaryTimes episode:episode];
    check(target, 200, "Jump to the second chapter");
    p.position = target / p.duration;
    check([p timeForChapterSelectionAtIndex:0 chapterTimes:boundaryTimes episode:episode], 37.5,
          "Immediate return across a rounded chapter boundary preserves the old position");
    NSDictionary *saved = [defaults dictionaryForKey:PlayerChapterPlaybackPositions][episode.objectHash];
    check([saved[@"positions"][@"1"] doubleValue], 200, "Saved position stays inside its chapter");
    check([p timeForChapterSelectionAtIndex:1 chapterTimes:boundaryTimes episode:episode], 200,
          "Retapping the current boundary restarts that chapter");
    [defaults removePersistentDomainForName:suite];
    puts("Chapter resume runtime checks passed");
}}
'''
with tempfile.TemporaryDirectory(prefix='instacast-chapter-resume-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(fixture.replace('METHOD', method))
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')], check=True)
