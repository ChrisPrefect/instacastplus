#!/usr/bin/env python3
"""Execute the actual Objective-C marker/seek methods against a small player fixture."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlaybackManager.m").read_text()
player_source = (ROOT / "Classes/PlayerInfoViewController_v5.m").read_text()

def method(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if not depth:
            return source[start:end + 1]
    raise AssertionError(signature)

signatures = [
    "- (NSString *)matchingSkipNameForChapter:",
    "- (NSString*)_matchingSkipNameForChapterTitle:",
    "- (BOOL)_autoSkipSponsorsEnabledForFeed:",
    "- (NSArray*)_effectiveAutoSkipNamesForFeed:",
    "- (void)_computeAutoSkipMarkers",
    "- (void)_suppressAutoSkipMarkerAtTime:",
    "- (void)nextTimeAfterSkipChapter:",
]
for optional in ["- (NSDictionary*)_currentAutoSkipConfiguration", "- (void)_refreshAutoSkipMarkersIfNeeded"]:
    if optional in source:
        signatures.append(optional)
if "- (void)_completeGeneratedChapterAudioVerification:" in source:
    signatures.append("- (void)_completeGeneratedChapterAudioVerification:")
    signatures.append("- (void)_verifyGeneratedChapterAudioForCurrentAsset")
    signatures.append("- (void)_publishChapterTimeline:")
    signatures.append("- (BOOL)generatedArtifactTimingIsCurrent")

preamble = r'''
#import <Foundation/Foundation.h>
#undef TARGET_OS_IPHONE
#define TARGET_OS_IPHONE 1
typedef double CMTime;
#define CMTimeGetSeconds(x) (x)
NSString *kFeedPropertyAutoSkipSponsors = @"AutoSkipSponsors";
NSString *kAutoSkipSponsors = @"AutoSkipSponsors";
static NSUserDefaults *testDefaults;
#define USER_DEFAULTS testDefaults
@interface CDFeed : NSObject
@property NSString *uid;
@property NSMutableDictionary *values;
- (NSString*)stringForKey:(NSString*)key;
- (double)doubleForKey:(NSString*)key;
@end
@implementation CDFeed
- (NSString*)stringForKey:(NSString*)key { return self.values[key]; }
- (double)doubleForKey:(NSString*)key { return [self.values[key] doubleValue]; }
@end
@interface CDEpisode : NSObject
@property BOOL consumed;
@property CDFeed *feed;
@property NSString *objectHash;
@end
@implementation CDEpisode @end
@interface ICMetadataChapter : NSObject
@property NSString *title;
@property CMTime start;
@property CMTime end;
@end
@implementation ICMetadataChapter @end
@interface AVURLAsset : NSObject
@property double duration;
@property NSURL *URL;
@end
@implementation AVURLAsset
- (instancetype)init { self=[super init];if(self)self.duration=100;return self; }
@end
@interface ICStreamingCacheLoader : NSObject
@property NSURL *assetURL;
@property NSURL *completeReadURL;
@property NSString *leaseToken;
@end
@implementation ICStreamingCacheLoader @end
static void (^pendingVerification)(BOOL, BOOL);
static NSString *fixtureSnapshot = @"snapshot";
@interface ICTranscriptionPaths : NSObject
+ (NSURL*)analysisJSONURLFor:(NSString*)hash;
@end
@implementation ICTranscriptionPaths
+ (NSURL*)analysisJSONURLFor:(NSString*)hash { return [NSURL fileURLWithPath:@"/analysis"]; }
@end
@interface TranscriptionEngine : NSObject
+ (instancetype)shared;
+ (NSString*)artifactSnapshotIdentifierAt:(NSURL*)url;
- (NSString*)transcriptSnapshotIdentifierFor:(NSString*)hash;
@end
@implementation TranscriptionEngine
+ (instancetype)shared { return [self new]; }
- (NSString*)transcriptSnapshotIdentifierFor:(NSString*)hash { return fixtureSnapshot; }
+ (NSString*)artifactSnapshotIdentifierAt:(NSURL*)url { return fixtureSnapshot; }
@end
@interface ChapterGenerator : NSObject
+ (instancetype)shared;
- (void)verifyPlaybackAudioForEpisodeHash:(NSString*)hash audioURL:(NSURL*)url completion:(void(^)(BOOL,BOOL))completion;
@end
@implementation ChapterGenerator
+ (instancetype)shared { return [self new]; }
- (void)verifyPlaybackAudioForEpisodeHash:(NSString*)hash audioURL:(NSURL*)url completion:(void(^)(BOOL,BOOL))completion { pendingVerification=[completion copy]; }
@end
@interface ICSharePlayCoordinator : NSObject
+ (instancetype)sharedCoordinator;
- (BOOL)hasActiveSession;
- (BOOL)canAdvanceAutomatically;
@end
@implementation ICSharePlayCoordinator
+ (instancetype)sharedCoordinator { return [self new]; }
- (BOOL)hasActiveSession { return NO; }
- (BOOL)canAdvanceAutomatically { return YES; }
@end
@interface ICDiagnosticLogger : NSObject
+ (instancetype)shared;
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata;
@end
@implementation ICDiagnosticLogger
+ (instancetype)shared { static id logger; if (!logger) logger=[self new]; return logger; }
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata {}
@end
@interface PlaybackManager : NSObject { float *_chapterTimesIdx; }
+ (instancetype)playbackManager;
@property CDEpisode *playingEpisode;
@property NSArray *chapters;
@property NSArray *autoSkipMarkers;
@property NSDictionary *autoSkipConfiguration;
@property BOOL chaptersUseGeneratedAnalysis;
@property BOOL generatedChapterAudioVerified;
@property BOOL generatedAudioVerificationCompleted;
@property BOOL automaticChapterSkippingAudioUnverified;
@property BOOL generatedChapterTimelineUnverified;
@property BOOL transcriptAudioVerified;
@property NSString *verifiedTranscriptSnapshot;
@property NSString *chapterTimelineIdentifier;
@property NSString *audioSnapshotAnchor;
@property NSString *verifiedAnalysisSnapshot;
@property AVURLAsset *audioSnapshotAsset;
@property NSArray *pendingGeneratedChapters;
@property NSArray *originalChapterTimeline;
@property ICMetadataChapter *seekingChapter;
@property NSInteger currentChapter;
@property NSUInteger chapterLoadGeneration;
@property AVURLAsset *mediaAsset;
@property ICStreamingCacheLoader *streamCacheLoader;
@property NSURL *audioVerificationSourceURL;
@property NSInteger suppressedSkipMarker;
@property BOOL isAutoSkipping;
@property NSDate *lastAutoSkipDate;
@property double time;
@property double duration;
@property int seeks;
@property int finishes;
@end
static PlaybackManager *testPlayer;
@implementation PlaybackManager
+ (instancetype)playbackManager { return testPlayer; }
- (void)_findAndSetCurrentChapter:(double)time {}
- (void)_logPlaybackAutoSkipEvent:(NSString*)message episode:(CDEpisode*)episode currentTime:(double)time duration:(double)duration metadata:(NSDictionary*)metadata {}
- (void)seekToTime:(double)time tolerance:(BOOL)tolerance { self.time=time; self.seeks++; }
- (void)_finishEpisodeDueToSkip:(CDEpisode*)episode { self.finishes++; }
'''
tests = r'''
@end
@interface PlayerInfoFixture : NSObject
@property NSDictionary *selectedTranscriptDescriptor;
@property NSString *transcriptLoadedEpisodeHash;
@property NSArray<NSDictionary*> *transcriptCues;
@end
@implementation PlayerInfoFixture
TRANSCRIPT_GUARD
@end
static int failures;
static void check(BOOL ok, NSString *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); failures++; } }
static ICMetadataChapter *chapter(NSString *title,double start,double end) { ICMetadataChapter *c=[ICMetadataChapter new];c.title=title;c.start=start;c.end=end;return c; }
static PlaybackManager *player(void) {
 PlaybackManager *p=[PlaybackManager new]; CDEpisode *e=[CDEpisode new];e.objectHash=@"one";e.feed=[CDFeed new];e.feed.uid=@"feed";e.feed.values=[NSMutableDictionary new];p.playingEpisode=e;p.duration=100;p.audioSnapshotAnchor=@"snapshot";p.verifiedAnalysisSnapshot=@"snapshot";
 p.chapters=@[chapter(@"Content",0,10),chapter(@"Sponsor: A",10,20),chapter(@"Sponsor: B",20,30),chapter(@"Content",30,80),chapter(@"Sponsor: Tail",80,100)];
 [p _computeAutoSkipMarkers];return p;
}
int main(void) { @autoreleasepool {
 NSString *suite=[@"InstacastSkipTest." stringByAppendingString:NSUUID.UUID.UUIDString];testDefaults=[[NSUserDefaults alloc] initWithSuiteName:suite];
 [testDefaults setBool:YES forKey:kAutoSkipSponsors];
 PlaybackManager *p=player();[testDefaults setBool:NO forKey:kAutoSkipSponsors];p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==0,@"Disable global setting immediately prevents skipping");
 p=player();[testDefaults setBool:YES forKey:kAutoSkipSponsors];p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1 && p.time==30,@"Enable global setting immediately merges adjacent sponsors");
 p=player();p.playingEpisode.feed.values[kFeedPropertyAutoSkipSponsors]=@"no";p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==0,@"Feed no overrides global yes immediately");
 [testDefaults setBool:NO forKey:kAutoSkipSponsors];p=player();p.playingEpisode.feed.values[kFeedPropertyAutoSkipSponsors]=@"yes";p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1,@"Feed yes overrides global no immediately");
 [testDefaults setBool:YES forKey:kAutoSkipSponsors];p=player();p.time=80;[p _suppressAutoSkipMarkerAtTime:80];[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.finishes==0 && p.seeks==0,@"Manual scrub into tail sponsor is respected");
 p=player();p.time=10;[p _suppressAutoSkipMarkerAtTime:10];[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==0,@"Manual scrub at start suppresses that interval");[p _suppressAutoSkipMarkerAtTime:30];p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1,@"End boundary belongs outside prior skip interval");
 p=player();p.playingEpisode.feed.values[@"feed_auto_skip_start_chapter_Sponsor: "]=@5;p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==0,@"Live start offset is respected");p.time=15;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1 && p.time==30,@"Offset start remains inclusive");
 [testDefaults setBool:NO forKey:kAutoSkipSponsors];p=player();p.playingEpisode.feed.values[@"feed_auto_skip_chapter_name"]=@"Sponsor: ";p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1,@"Explicit keyword remains active independently of sponsor toggle");
 [testDefaults setBool:YES forKey:kAutoSkipSponsors];
 p=player();p.time=9.999;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==0,@"Before start is not skipped");p.time=30;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==0,@"Exact resume is not skipped");p.time=80;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.finishes==1,@"Normal playback still finishes final sponsor");
 p=player();p.time=10;[p _suppressAutoSkipMarkerAtTime:10];p.playingEpisode.objectHash=@"two";[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1,@"New episode cannot inherit manual suppression");
 p=player();p.pendingGeneratedChapters=p.chapters;p.chaptersUseGeneratedAnalysis=YES;p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==0 && p.automaticChapterSkippingAudioUnverified,@"Unknown audio identity blocks generated jumps");
 [p _completeGeneratedChapterAudioVerification:NO episodeHash:@"one" asset:p.mediaAsset generation:0];check(p.chapters.count==0,@"Unverified generated timestamps must not remain available to chapter UI and manual seeks");
 AVURLAsset *asset=[AVURLAsset new];p.mediaAsset=asset;p.chapterLoadGeneration=2;
 [p _completeGeneratedChapterAudioVerification:YES episodeHash:@"one" asset:asset generation:1];check(!p.generatedChapterAudioVerified,@"Old generation cannot authorize current playback");
 [p _completeGeneratedChapterAudioVerification:YES episodeHash:@"previous episode" asset:asset generation:2];check(!p.generatedChapterAudioVerified,@"Old episode completion cannot authorize current playback");
 [p _completeGeneratedChapterAudioVerification:YES episodeHash:@"one" asset:[AVURLAsset new] generation:2];check(!p.generatedChapterAudioVerified,@"Other media asset cannot authorize current playback");
 [p _completeGeneratedChapterAudioVerification:YES episodeHash:@"one" asset:asset generation:2];[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1 && !p.automaticChapterSkippingAudioUnverified,@"Matching current audio identity enables generated jumps");
 p=player();p.chaptersUseGeneratedAnalysis=YES;p.mediaAsset=[AVURLAsset new];p.mediaAsset.URL=[NSURL URLWithString:@"instacast-stream-cache://source"];
 ICStreamingCacheLoader *loader=[ICStreamingCacheLoader new];loader.assetURL=p.mediaAsset.URL;loader.leaseToken=@"current";p.streamCacheLoader=loader;pendingVerification=nil;
 [p _verifyGeneratedChapterAudioForCurrentAsset];check(!pendingVerification,@"Incomplete streaming source cannot be verified");
 loader.completeReadURL=[NSURL fileURLWithPath:@"/complete-import.mp3"];[p _verifyGeneratedChapterAudioForCurrentAsset];check(pendingVerification!=nil,@"Own completed cache can be verified without reopening");
 loader.leaseToken=@"replaced";pendingVerification(YES,YES);check(!p.generatedChapterAudioVerified && !p.transcriptAudioVerified,@"Superseded stream lease cannot authorize playback");
 p.audioVerificationSourceURL=nil;[p _verifyGeneratedChapterAudioForCurrentAsset];p.streamCacheLoader=[ICStreamingCacheLoader new];pendingVerification(YES,YES);check(!p.generatedChapterAudioVerified && !p.transcriptAudioVerified,@"Replaced loader completion cannot authorize playback");
 p.streamCacheLoader=loader;p.audioVerificationSourceURL=nil;[p _verifyGeneratedChapterAudioForCurrentAsset];pendingVerification(YES,YES);check(p.generatedChapterAudioVerified && p.transcriptAudioVerified,@"Same completed loader and lease enables verified playback");pendingVerification=nil;
 p=player();p.mediaAsset=[AVURLAsset new];p.originalChapterTimeline=@[chapter(@"Publisher",0,100)];p.pendingGeneratedChapters=@[chapter(@"Generated",0,100)];[testDefaults setBool:NO forKey:kAutoSkipSponsors];[p _completeGeneratedChapterAudioVerification:NO episodeHash:@"one" asset:p.mediaAsset generation:0];check([[(ICMetadataChapter*)p.chapters[0] title] isEqualToString:@"Publisher"] && p.generatedChapterTimelineUnverified,@"Mismatch keeps publisher timeline and notice independent of auto-skip");[p _completeGeneratedChapterAudioVerification:YES episodeHash:@"one" asset:p.mediaAsset generation:0];check([[(ICMetadataChapter*)p.chapters[0] title] isEqualToString:@"Generated"] && !p.generatedChapterTimelineUnverified,@"Matching proof publishes generated timeline");
 testPlayer=player();PlayerInfoFixture *ui=[PlayerInfoFixture new];ui.transcriptCues=@[@{@"start":@10,@"end":@20,@"text":@"Timed cue"}];ui.selectedTranscriptDescriptor=@{@"isGenerated":@YES,@"transcriptSnapshot":@"snapshot"};ui.transcriptLoadedEpisodeHash=@"one";check(![ui _transcriptTimingVerified],@"Unknown SRT identity disables timestamp navigation");testPlayer.transcriptAudioVerified=YES;testPlayer.verifiedTranscriptSnapshot=@"snapshot";check([ui _transcriptTimingVerified],@"Matching local SRT identity enables timestamp navigation");ui.transcriptLoadedEpisodeHash=@"previous";check(![ui _transcriptTimingVerified],@"A noncurrent transcript cannot seek current playback");ui.transcriptLoadedEpisodeHash=@"one";ui.selectedTranscriptDescriptor=@{@"isGenerated":@NO};testPlayer.transcriptAudioVerified=NO;check([ui _transcriptTimingVerified],@"Timed publisher transcript uses its own timeline without generated audio proof");
 ui.transcriptLoadedEpisodeHash=@"previous";check(![ui _transcriptTimingVerified],@"Publisher timeline from another episode cannot seek current playback");ui.transcriptLoadedEpisodeHash=@"one";
 ui.transcriptCues=@[];check(![ui _transcriptTimingVerified],@"Missing cues cannot authorize timestamp navigation");ui.transcriptCues=@[@{@"untimed":@YES,@"text":@"Plain text"}];check(![ui _transcriptTimingVerified],@"Untimed publisher text cannot authorize timestamp navigation");ui.transcriptCues=@[@{@"start":@10,@"end":@20,@"text":@"Timed cue"}];testPlayer.transcriptAudioVerified=YES;
 ui.selectedTranscriptDescriptor=@{@"isGenerated":@YES,@"transcriptSnapshot":@"old"};check(![ui _transcriptTimingVerified],@"Old cached cues cannot inherit fresh proof");
 ui.selectedTranscriptDescriptor=@{@"isGenerated":@YES,@"transcriptSnapshot":@"snapshot"};fixtureSnapshot=@"replaced";check(![ui _transcriptTimingVerified],@"Post-proof source replacement revokes timing");check(!testPlayer.transcriptAudioVerified,@"Replacement invalidates published proof");fixtureSnapshot=@"snapshot";
 for (int played=0; played<=1; played++) {
  [testDefaults setBool:YES forKey:kAutoSkipSponsors];
  p=player();p.playingEpisode.consumed=played;p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1 && p.time==30,@"Sponsor skips apply identically on replay");
  p=player();p.playingEpisode.consumed=played;p.time=80;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.finishes==1,@"Final sponsor skip applies identically on replay");
  [testDefaults setBool:NO forKey:kAutoSkipSponsors];
  p=player();p.playingEpisode.consumed=played;p.playingEpisode.feed.values[@"feed_auto_skip_chapter_name"]=@"Sponsor: ";p.time=10;[p nextTimeAfterSkipChapter:p.playingEpisode];check(p.seeks==1,@"Named chapter skips apply identically on replay");
 }
 [testDefaults removePersistentDomainForName:suite];
 return failures ? 1:0;
} }
'''
guard_start = player_source.index("- (BOOL)_transcriptTimingVerified\n")
guard_end = player_source.index("\n- (", guard_start + 1)
tests = tests.replace("TRANSCRIPT_GUARD", player_source[player_source.index("- (BOOL)_transcriptDescriptorIsCurrent:"):guard_start] + player_source[guard_start:guard_end])
# Keep teardown ownership pinned without executing the unrelated AVPlayer teardown.
close = method("- (void) closeAndSaveCurrentPosition:")
assert "self.autoSkipMarkers = nil;" in close and "self.suppressedSkipMarker = -1;" in close
with tempfile.TemporaryDirectory(prefix="instacast-skip-") as directory:
    path = Path(directory)
    fixture = path / "main.m"
    fixture.write_text(preamble + "\n".join(map(method, signatures)) + tests)
    subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(fixture), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
print("Live auto-skip settings and interval runtime checks passed.")
