#!/usr/bin/env python3
"""Run real checkpoint/chapter validators and the widget action branch, without iOS."""
from pathlib import Path
import subprocess, tempfile
R=Path(__file__).resolve().parents[1]
def extract(source, signature):
 start=source.index(signature);brace=source.index('{',start);depth=0
 for end in range(brace,len(source)):
  depth+=(source[end]=='{')-(source[end]=='}')
  if not depth:return source[start:end+1]
e=(R/'Classes/TranscriptionEngine.swift').read_text();g=(R/'Classes/ChapterGenerator.swift').read_text()
checkpoint=extract(e,'private struct TranscriptionCheckpoint:').replace('private struct','struct',1)
validator=extract(g,'private static func validatePersistedChapterIntervals').replace('private static','static',1)
snapshot=extract(e,'@objc nonisolated static func artifactSnapshotIdentifier')
swift='''import Foundation
import Darwin
struct ICGeneratedChapter { let start:Double; let end:Double }
CHECKPOINT
class Validator:NSObject {
VALIDATOR
SNAPSHOT
}
let good=TranscriptionCheckpoint(lastTimestamp:10,cues:[.init(start:0,end:10,text:"speech")],engineType:0,consecutiveFailures:0)
precondition(good.isValid(forDuration:10))
for end in [11.0, -1, Double.nan, Double.infinity] {
 var invalid=good;invalid.lastTimestamp=end;precondition(!invalid.isValid(forDuration:10))
}
var overlap=good;overlap.cues.append(.init(start:5,end:9,text:"overlap"));precondition(!overlap.isValid(forDuration:10))
try Validator.validatePersistedChapterIntervals([.init(start:0,end:10),.init(start:10,end:20)])
for bad in [[ICGeneratedChapter(start:-1,end:2)], [.init(start:10,end:9)], [.init(start:0,end:10),.init(start:9,end:20)], [.init(start:0,end:Double.infinity)], [.init(start:0,end:Double.greatestFiniteMagnitude)]] {
 do { try Validator.validatePersistedChapterIntervals(bad);fatalError("invalid timeline accepted") } catch {}
}
let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at:file) }
try Data("old".utf8).write(to:file)
let before=Validator.artifactSnapshotIdentifier(at:file)
try Data("new".utf8).write(to:file,options:.atomic)
precondition(before != Validator.artifactSnapshotIdentifier(at:file))
precondition(Validator.artifactSnapshotIdentifier(at:nil) == nil)
print("Checkpoint ranges, generated interval semantics and file replacement snapshot checks passed")
'''.replace('CHECKPOINT',checkpoint).replace('VALIDATOR',validator).replace('SNAPSHOT',snapshot)
w=(R/'Classes/WidgetDataExporter.m').read_text();start=w.index('        NSInteger targetIdx =',w.index('    if ([action isEqualToString:@"skipchapter"]) {'));end=w.index('\n    }',start);branch=w[start:end]
objc='''#import <Foundation/Foundation.h>
@interface ICMetadataChapter:NSObject @end
@implementation ICMetadataChapter @end
@interface Playback:NSObject
@property NSArray *chapters;
@property NSString *chapterTimelineIdentifier;
@property BOOL ready;
@property int seeks;
@property int plays;
- (void)seekToChapter:(ICMetadataChapter*)chapter;
- (void)play;
@end
@implementation Playback
- (void)seekToChapter:(ICMetadataChapter*)chapter { self.seeks++; }
- (void)play { self.plays++; }
@end
@interface Harness:NSObject
@property int exports;
@property int deferred;
@property NSNumber *deferredStart;
@end
@implementation Harness
- (void)_scheduleControlActionNowPlayingExport { self.exports++; }
- (void)_performAction:(NSString*)action afterLoadingEpisode:(NSString*)episodeIdentifier chapterStartTime:(NSNumber*)chapterStartTime { self.deferred++; self.deferredStart=chapterStartTime; }
- (void)invoke:(Playback*)pm index:(NSNumber*)chapterIndex timeline:(NSString*)timelineIdentifier episode:(NSString*)episodeIdentifier start:(NSNumber*)chapterStartTime {
 NSString *action=@"skipchapter";
 BRANCH
}
@end
int main(){ @autoreleasepool {
 Harness *h=[Harness new];
 Playback *p=[Playback new];p.ready=YES;p.chapters=@[[ICMetadataChapter new]];p.chapterTimelineIdentifier=@"episode-A-timeline-1";
 [h invoke:p index:@0 timeline:@"episode-A-timeline-1" episode:@"A" start:@12.5];NSCAssert(p.seeks==1&&p.plays==1&&h.deferred==0,@"Current action seeks by index and plays, like the app player");
 p.chapterTimelineIdentifier=@"episode-A-timeline-2";[h invoke:p index:@0 timeline:@"episode-A-timeline-1" episode:nil start:nil];NSCAssert(p.seeks==1&&h.deferred==0,@"Old same-episode timeline without a start time rejected");
 [h invoke:p index:@0 timeline:@"episode-A-timeline-1" episode:@"A" start:@12.5];NSCAssert(p.seeks==1&&h.deferred==1&&[h.deferredStart isEqual:@12.5],@"Old timeline never seeks by index; selects by episode and start time");
 p.chapterTimelineIdentifier=@"episode-A-timeline-1";p.ready=NO;[h invoke:p index:@0 timeline:@"episode-A-timeline-1" episode:@"A" start:@12.5];NSCAssert(p.seeks==1&&h.deferred==2,@"Timeline still loading waits for readiness");
 p.ready=YES;[h invoke:p index:@0 timeline:nil episode:nil start:nil];[h invoke:p index:@-1 timeline:p.chapterTimelineIdentifier episode:nil start:nil];[h invoke:p index:@1 timeline:p.chapterTimelineIdentifier episode:nil start:nil];NSCAssert(p.seeks==1&&h.deferred==2,@"Missing identity and bad index rejected");
 puts("Widget timeline action freshness checks passed");
} }
'''.replace('BRANCH',branch)
with tempfile.TemporaryDirectory(prefix='instacast-artifact-semantics-') as d:
 p=Path(d);(p/'main.swift').write_text(swift);(p/'main.m').write_text(objc)
 subprocess.run(['swiftc','-swift-version','6',str(p/'main.swift'),'-o',str(p/'swift-test')],check=True)
 subprocess.run([str(p/'swift-test')],check=True)
 subprocess.run(['clang','-fobjc-arc','-framework','Foundation',str(p/'main.m'),'-o',str(p/'objc-test')],check=True)
 subprocess.run([str(p/'objc-test')],check=True)
