#!/usr/bin/env python3
"""Execute the actual Objective-C marker/seek methods against a small player fixture."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Classes/PlaybackManager.m").read_text()
player_source = (ROOT / "Classes/PlayerInfoViewController_v5.m").read_text()
engine_source = (ROOT / "Classes/TranscriptionEngine.swift").read_text()
def swift_fragment(signature):
    start=engine_source.index(signature);brace=engine_source.index("{",start);depth=0
    for end in range(brace,len(engine_source)):
        depth+=(engine_source[end]=="{")-(engine_source[end]=="}")
        if not depth:return engine_source[start:end+1]
    raise AssertionError(signature)

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
if "- (void)_verifyGeneratedChapterAudioAtURL:" in source:
    signatures.append("- (void)_verifyGeneratedChapterAudioAtURL:")
if "- (id)_audioContentGenerationAtURL:" in source:
    signatures.append("- (id)_audioContentGenerationAtURL:")

preamble = r'''
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
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
static NSString *fixtureAudioSnapshot;
static NSString *fixtureAnalysisSnapshot;
static NSString *fixtureTranscriptSnapshot;
static int verificationRequests;
static NSURL *realAudioURL;
static NSString *realExpectedSHA;
static NSString *productionIdentity(NSString *mode,NSURL *url) {
 NSTask *task=[NSTask new];task.launchPath=@"SWIFT_IDENTITY_PATH";task.arguments=@[mode,url.path];NSPipe *pipe=[NSPipe pipe];task.standardOutput=pipe;
 [task launch];NSData *data=[pipe.fileHandleForReading readDataToEndOfFile];[task waitUntilExit];
 if(task.terminationStatus!=0)return nil;
 return [[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
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
- (NSString*)transcriptSnapshotIdentifierFor:(NSString*)hash { return fixtureTranscriptSnapshot ?: fixtureSnapshot; }
+ (NSString*)artifactSnapshotIdentifierAt:(NSURL*)url { if(realAudioURL && [url isEqual:realAudioURL])return productionIdentity(@"snapshot",url);return [url.path isEqual:@"/analysis"] ? (fixtureAnalysisSnapshot ?: fixtureSnapshot) : (fixtureAudioSnapshot ?: fixtureSnapshot); }
@end
@interface ChapterGenerator : NSObject
+ (instancetype)shared;
- (NSString*)chapterArtifactSnapshotIdentifierFor:(NSString*)hash;
- (void)verifyPlaybackAudioForEpisodeHash:(NSString*)hash audioURL:(NSURL*)url completion:(void(^)(BOOL,BOOL))completion;
@end
@implementation ChapterGenerator
+ (instancetype)shared { return [self new]; }
- (NSString*)chapterArtifactSnapshotIdentifierFor:(NSString*)hash { return fixtureAnalysisSnapshot ?: fixtureSnapshot; }
- (void)verifyPlaybackAudioForEpisodeHash:(NSString*)hash audioURL:(NSURL*)url completion:(void(^)(BOOL,BOOL))completion { verificationRequests++;
 if(realAudioURL){BOOL match=[productionIdentity(@"hash",url)isEqual:realExpectedSHA];pendingVerification=^(BOOL analysis,BOOL transcript){completion(match,match);};}
 else pendingVerification=[completion copy]; }
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
@property BOOL ready;
@property NSString *verifiedTranscriptSnapshot;
@property NSString *chapterTimelineIdentifier;
@property NSString *audioSnapshotAnchor;
@property id audioContentGenerationAnchor;
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
 PlaybackManager *p=[PlaybackManager new];p.ready=YES; CDEpisode *e=[CDEpisode new];e.objectHash=@"one";e.feed=[CDFeed new];e.feed.uid=@"feed";e.feed.values=[NSMutableDictionary new];p.playingEpisode=e;p.duration=100;p.audioSnapshotAnchor=@"snapshot";p.audioContentGenerationAnchor=nil;p.verifiedAnalysisSnapshot=@"snapshot";
 p.chapters=@[chapter(@"Content",0,10),chapter(@"Sponsor: A",10,20),chapter(@"Sponsor: B",20,30),chapter(@"Content",30,80),chapter(@"Sponsor: Tail",80,100)];
 [p _computeAutoSkipMarkers];return p;
}
static PlaybackManager *verifiedPlayer(BOOL analysis) {
 fixtureSnapshot=@"snapshot";fixtureAudioSnapshot=nil;fixtureAnalysisSnapshot=nil;fixtureTranscriptSnapshot=nil;
 PlaybackManager *p=player();p.pendingGeneratedChapters=p.chapters;p.mediaAsset=[AVURLAsset new];p.mediaAsset.URL=[NSURL URLWithString:@"instacast-stream-cache://source"];
 ICStreamingCacheLoader *loader=[ICStreamingCacheLoader new];loader.assetURL=p.mediaAsset.URL;loader.completeReadURL=[NSURL fileURLWithPath:@"/complete-import.mp3"];loader.leaseToken=@"current";p.streamCacheLoader=loader;
 [p _verifyGeneratedChapterAudioForCurrentAsset];pendingVerification(analysis,YES);pendingVerification=nil;return p;
}
@interface ProofObserver:NSObject
@property PlaybackManager *player;
@property BOOL rejectedPublishedProof;
@end
@implementation ProofObserver
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
 if(self.player.transcriptAudioVerified && ![self.player generatedArtifactTimingIsCurrent])self.rejectedPublishedProof=YES;
}
@end
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
 // Deterministic boundary cases for the real metadata-churn App E2E.
 p=verifiedPlayer(YES);fixtureAudioSnapshot=@"tracked";int requestCount=verificationRequests;
 check(![p generatedArtifactTimingIsCurrent] && !p.generatedChapterAudioVerified && !p.transcriptAudioVerified,@"Metadata change immediately revokes timestamp permissions");
 check(pendingVerification!=nil && verificationRequests==requestCount+1,@"Previously proven audio is rehashed once after metadata-only snapshot change");
 [p generatedArtifactTimingIsCurrent];check(verificationRequests==requestCount+1,@"Pending proof is not restarted by repeated UI reads");
 ProofObserver *observer=[ProofObserver new];observer.player=p;[p addObserver:observer forKeyPath:@"transcriptAudioVerified" options:0 context:NULL];
 if(pendingVerification)pendingVerification(YES,YES);
 check(p.generatedChapterAudioVerified && p.transcriptAudioVerified && [p generatedArtifactTimingIsCurrent],@"Matching bytes restore timing after metadata-only change");
 check([p.audioSnapshotAnchor isEqual:@"tracked"] && !observer.rejectedPublishedProof,@"New anchor precedes observable proof publication");
 [p removeObserver:observer forKeyPath:@"transcriptAudioVerified"];
 p=verifiedPlayer(YES);fixtureAudioSnapshot=@"changed-content";[p generatedArtifactTimingIsCurrent];if(pendingVerification)pendingVerification(NO,NO);
 check(!p.generatedChapterAudioVerified && !p.transcriptAudioVerified && [p.audioSnapshotAnchor isEqual:@"snapshot"],@"Changed audio bytes cannot replace the verified source anchor");
 for(int changed=0;changed<3;changed++) {
  p=verifiedPlayer(YES);fixtureAudioSnapshot=@"tracked";[p generatedArtifactTimingIsCurrent];
  if(changed==0)fixtureAudioSnapshot=@"changed-during-hash";
  if(changed==1)fixtureTranscriptSnapshot=@"changed-during-hash";
  if(changed==2)fixtureAnalysisSnapshot=@"changed-during-hash";
  if(pendingVerification)pendingVerification(YES,YES);
  check(!p.generatedChapterAudioVerified && !p.transcriptAudioVerified && [p.audioSnapshotAnchor isEqual:@"snapshot"],@"Changed source or artifact during revalidation rejects the callback");
 }
 for(int changed=0;changed<2;changed++) {
  p=verifiedPlayer(YES);fixtureAudioSnapshot=@"tracked";
  if(changed==0)fixtureTranscriptSnapshot=@"already-replaced";else fixtureAnalysisSnapshot=@"already-replaced";
  requestCount=verificationRequests;[p generatedArtifactTimingIsCurrent];
  check(verificationRequests==requestCount && !p.transcriptAudioVerified && !p.generatedChapterAudioVerified,@"A changed artifact cannot inherit revalidation of prior proof");
 }
 for(int changed=0;changed<5;changed++) {
  p=verifiedPlayer(YES);fixtureAudioSnapshot=@"tracked";[p generatedArtifactTimingIsCurrent];
  if(changed==0)p.playingEpisode.objectHash=@"other";
  if(changed==1)p.mediaAsset=[AVURLAsset new];
  if(changed==2)p.chapterLoadGeneration++;
  if(changed==3)p.streamCacheLoader=[ICStreamingCacheLoader new];
  if(changed==4)p.streamCacheLoader.leaseToken=@"superseded";
  if(pendingVerification)pendingVerification(YES,YES);
  check(!p.generatedChapterAudioVerified && !p.transcriptAudioVerified && [p.audioSnapshotAnchor isEqual:@"snapshot"],@"Revalidation cannot cross episode/asset/generation/loader/lease boundaries");
 }
 p=verifiedPlayer(NO);fixtureAudioSnapshot=@"tracked";[p generatedArtifactTimingIsCurrent];if(pendingVerification)pendingVerification(YES,YES);
 check(p.transcriptAudioVerified && !p.generatedChapterAudioVerified,@"Revalidation restores only artifact permissions actually proven before invalidation");
 fixtureSnapshot=@"snapshot";fixtureAudioSnapshot=nil;fixtureAnalysisSnapshot=nil;fixtureTranscriptSnapshot=nil;pendingVerification=nil;
 // Real production SHA + snapshot with controlled first-completion metadata change.
 NSString *directory=[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString];[[NSFileManager defaultManager]createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
 for(int variant=0;variant<6;variant++){
  realAudioURL=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"first-%d.wav",variant]]];
  [[NSData dataWithContentsOfFile:@"AUDIO_FIXTURE_PATH"]writeToURL:realAudioURL atomically:NO];realExpectedSHA=productionIdentity(@"hash",realAudioURL);
  p=player();p.pendingGeneratedChapters=p.chapters;p.mediaAsset=[AVURLAsset new];p.mediaAsset.URL=realAudioURL;p.audioSnapshotAnchor=nil;p.audioContentGenerationAnchor=nil;
  if(variant>=4){
   id selectionGeneration=nil;[[NSURL fileURLWithPath:realAudioURL.path]getResourceValue:&selectionGeneration forKey:NSURLGenerationIdentifierKey error:nil];p.audioContentGenerationAnchor=selectionGeneration;p.audioSnapshotAnchor=productionIdentity(@"snapshot",realAudioURL);
   if(variant==4)link(realAudioURL.path.UTF8String,[realAudioURL.path stringByAppendingString:@".before-hash"].UTF8String);
   else {struct stat prior;stat(realAudioURL.path.UTF8String,&prior);NSFileHandle *writer=[NSFileHandle fileHandleForWritingToURL:realAudioURL error:nil];[writer seekToFileOffset:1000];[writer writeData:[@"changed audio" dataUsingEncoding:NSUTF8StringEncoding]];[writer closeFile];struct timespec times[2]={prior.st_atimespec,prior.st_mtimespec};utimensat(AT_FDCWD,realAudioURL.path.UTF8String,times,0);realExpectedSHA=productionIdentity(@"hash",realAudioURL);}
   pendingVerification=nil;int count=verificationRequests;[p _verifyGeneratedChapterAudioForCurrentAsset];
   if(variant==4){check(pendingVerification!=nil,@"Metadata-only change before first hash preserves original byte-generation binding");if(pendingVerification)pendingVerification(YES,YES);check(p.transcriptAudioVerified && p.generatedChapterAudioVerified,@"Stable first hash can prove the original generation after pre-hash metadata churn");}
   else check(!pendingVerification && verificationRequests==count && !p.transcriptAudioVerified,@"Different originally buffered bytes cannot adopt a new matching artifact source before first hash");
   continue;
  }
  [p _verifyGeneratedChapterAudioForCurrentAsset];NSString *originalSnapshot=p.audioSnapshotAnchor;int beforeRetry=verificationRequests;void(^firstCompletion)(BOOL,BOOL)=[pendingVerification copy];pendingVerification=nil;
  struct stat before;stat(realAudioURL.path.UTF8String,&before);id originalGeneration=nil;[[NSURL fileURLWithPath:realAudioURL.path]getResourceValue:&originalGeneration forKey:NSURLGenerationIdentifierKey error:nil];
  if(variant==0 || variant==3){
   check(link(realAudioURL.path.UTF8String,[realAudioURL.path stringByAppendingString:@".alias"].UTF8String)==0,@"Metadata boundary creates a real hardlink without changing file bytes");
  }else{
   NSFileHandle *writer=[NSFileHandle fileHandleForWritingToURL:realAudioURL error:nil];[writer seekToFileOffset:1000];[writer writeData:[@"changed audio" dataUsingEncoding:NSUTF8StringEncoding]];[writer closeFile];
   if(variant==2){NSFileHandle *restore=[NSFileHandle fileHandleForWritingToURL:realAudioURL error:nil];NSData *original=[NSData dataWithContentsOfFile:@"AUDIO_FIXTURE_PATH"];[restore seekToFileOffset:1000];[restore writeData:[original subdataWithRange:NSMakeRange(1000,13)]];[restore closeFile];}
   struct timespec times[2]={before.st_atimespec,before.st_mtimespec};check(utimensat(AT_FDCWD,realAudioURL.path.UTF8String,times,0)==0,@"In-place negative control restores exact mtime");
  }
  id afterGeneration=nil;[[NSURL fileURLWithPath:realAudioURL.path]getResourceValue:&afterGeneration forKey:NSURLGenerationIdentifierKey error:nil];
  check(![originalSnapshot isEqual:productionIdentity(@"snapshot",realAudioURL)],@"Actual filesystem snapshot detects controlled metadata/content boundary");
  check((variant==0 || variant==3)?[originalGeneration isEqual:afterGeneration]:![originalGeneration isEqual:afterGeneration],@"Filesystem generation distinguishes metadata-only changes from real writes with preserved mtime");
  firstCompletion(YES,YES);
  if(variant==0 || variant==3){
   check(verificationRequests==beforeRetry+1 && pendingVerification && !p.transcriptAudioVerified,@"First matching hash with only metadata churn triggers one still-blocked revalidation");
   if(variant==3)link(realAudioURL.path.UTF8String,[realAudioURL.path stringByAppendingString:@".second-alias"].UTF8String);
   void(^secondCompletion)(BOOL,BOOL)=[pendingVerification copy];pendingVerification=nil;if(secondCompletion)secondCompletion(YES,YES);
   if(variant==0)check(p.transcriptAudioVerified && p.generatedChapterAudioVerified && [p generatedArtifactTimingIsCurrent],@"First hash proof survives metadata churn only after stable revalidation");
   else check(!p.transcriptAudioVerified && !pendingVerification && verificationRequests==beforeRetry+1,@"Repeated mutation never starts an unbounded hash loop");
  }else check(!p.transcriptAudioVerified && !p.generatedChapterAudioVerified && !pendingVerification && [p.audioSnapshotAnchor isEqual:originalSnapshot],@"Original content generation rejects modified or modified-and-restored bytes despite matching old hash");
 }
 realAudioURL=nil;realExpectedSHA=nil;[[NSFileManager defaultManager]removeItemAtPath:directory error:nil];
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
close = method("- (void)_releasePlaybackResourcesAndSaveCurrentPosition:")
assert "self.autoSkipMarkers = nil;" in close and "self.suppressedSkipMarker = -1;" in close
with tempfile.TemporaryDirectory(prefix="instacast-skip-") as directory:
    path = Path(directory)
    fixture = path / "main.m"
    helper = path / "identity.swift"
    helper.write_text("import Foundation\nimport CryptoKit\n" + swift_fragment("enum ICAudioIdentity {") + "\nfinal class Snapshot: NSObject {\n" + swift_fragment("@objc nonisolated static func artifactSnapshotIdentifier") + "\n}\n" + '''
@main struct IdentityProbe {
 static func main() async throws {
  let url=URL(fileURLWithPath:CommandLine.arguments[2])
  if CommandLine.arguments[1] == "hash" { print(try await ICAudioIdentity.sha256(of:url)) }
  else { print(Snapshot.artifactSnapshotIdentifier(at:url) ?? "missing") }
 }
}
''')
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(helper), "-o", str(path / "identity")], check=True)
    compiled = preamble + "\n".join(map(method, signatures)) + tests
    compiled = compiled.replace("SWIFT_IDENTITY_PATH", str(path / "identity")).replace("AUDIO_FIXTURE_PATH", str(ROOT / "Tools/fixtures/server-sponsor-e2e/fixture.wav"))
    fixture.write_text(compiled)
    subprocess.run(["clang", "-fobjc-arc", "-framework", "Foundation", str(fixture), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
print("Live auto-skip settings and interval runtime checks passed.")
