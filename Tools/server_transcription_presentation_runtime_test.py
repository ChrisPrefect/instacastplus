#!/usr/bin/env python3
"""Execute the production server-cell text and toolbar predicate in Foundation.

The transport fault matrix is in server_transcription_admission_runtime_test.py.
This test checks the UI contract without depending on network timing or a window.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Classes/TranscriptionQueueViewController.m').read_text()

def declaration(signature):
    start = source.rindex(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(signature)

# Compile the server branch verbatim. Local engine dependencies are outside this test.
status = declaration('- (NSString*)_updateCellStatus:').split('\n    switch (item.status)', 1)[0] + '\n return nil;\n}'
helpers = '\n'.join(declaration(signature) for signature in ['- (NSString*)_singleStatusTextWithHeadline:', '- (BOOL)_statusDetail:', '- (NSString*)_normalizedStatusText:'])
if 'static NSString* ICServerTranscriptionStatusText(' in source:
    helpers = source[source.index('// Shared by'):source.index('@interface ICTranscriptionQueueCell')] + '\n' + helpers
program = r'''
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSInteger, ICTranscriptionStatus) { ICTranscriptionStatusNone, ICTranscriptionStatusQueued, ICTranscriptionStatusDownloadingModel, ICTranscriptionStatusAnalyzingMusic, ICTranscriptionStatusTranscribing, ICTranscriptionStatusGeneratingChapters, ICTranscriptionStatusCompleted, ICTranscriptionStatusFailed, ICTranscriptionStatusCanceled };
@interface ICTranscriptionQueueItem:NSObject
@property ICTranscriptionStatus status;
@property BOOL usesServerTranscription, serverWaitingForNetwork, requiresExplicitRetryAfterCrash, serverConnectionIssue;
@property NSString *statusDetail, *error, *episodeHash, *serverPhase;
@property NSDate *nextRetryAt, *serverLastResponseAt;
@end
@implementation ICTranscriptionQueueItem @end
@interface TranscriptionQueue:NSObject
@property NSArray *items, *displayItems;
+ (instancetype)shared;
@end
@implementation TranscriptionQueue
+ (instancetype)shared { static id q; if (!q) q=[self new]; return q; }
@end
@interface ServerTranscriptionManager:NSObject
+ (instancetype)shared;
- (BOOL)wasAdmissionRejectedForEpisodeHash:(id)hash;
- (BOOL)hasConfirmedAdmissionForEpisodeHash:(id)hash;
@end
@implementation ServerTranscriptionManager
+ (instancetype)shared { static id q; if (!q) q=[self new]; return q; }
- (BOOL)wasAdmissionRejectedForEpisodeHash:(id)hash { return NO; }
- (BOOL)hasConfirmedAdmissionForEpisodeHash:(id)hash { return YES; }
@end
@interface Label:NSObject
@property NSInteger numberOfLines, lineBreakMode;
@property id textColor;
@property NSString *text;
@property BOOL hidden;
@end
@implementation Label @end
@interface DownloadsTableViewCell:NSObject
@property BOOL showsErrorStatus;
@property Label *sizeLabel, *timeLabel, *progressView;
@end
@implementation DownloadsTableViewCell @end
@interface UIColor:NSObject
+ (id)systemGreenColor;
+ (id)systemRedColor;
@end
@implementation UIColor
+ (id)systemGreenColor { return nil; }
+ (id)systemRedColor { return nil; }
@end
#define ICMutedTextColor nil
#define NSLineBreakByWordWrapping 0
STATIC_HELPER
@interface Controller:NSObject @end
@implementation Controller
- (NSString*)_elapsedTextForItem:(id)item { return @"1:20"; }
- (NSString*)_estimatedRemainingTextForItem:(id)item { return nil; }
METHODS
@end
int main(void) { @autoreleasepool {
 Controller *vc=[Controller new]; ICTranscriptionQueueItem *server=[ICTranscriptionQueueItem new];
 server.usesServerTranscription=YES; server.status=ICTranscriptionStatusTranscribing;
 server.statusDetail=@"Step 2 of 4 · Transcribing audio"; server.nextRetryAt=[NSDate dateWithTimeIntervalSince1970:1900000000];
 TranscriptionQueue.shared.items=@[]; TranscriptionQueue.shared.displayItems=@[server];
 BOOL serverButton=[vc backgroundControlsAvailable];
 NSString *text=[vc _updateCellStatus:nil withItem:server];
 ICTranscriptionQueueItem *local=[ICTranscriptionQueueItem new]; local.status=ICTranscriptionStatusQueued;
 TranscriptionQueue.shared.items=@[local]; TranscriptionQueue.shared.displayItems=@[server,local];
 BOOL localButton=[vc backgroundControlsAvailable];
 local.status=ICTranscriptionStatusCompleted;
 BOOL completedButton=[vc backgroundControlsAvailable];
 NSString *next = ICServerTranscriptionNextAction(server);
 BOOL timing=[next containsString:@"Next status check"] && [next containsString:@"does not provide a remaining time"];
 printf("%s\n", [[@{@"serverButton":@(serverButton),@"localButton":@(localButton),@"completedButton":@(completedButton),@"status":text ?: @"",@"honestTiming":@(timing)} description] UTF8String]);
 return (!serverButton && localButton && !completedButton && timing) ? 0 : 1;
}}
'''
static = ''
if helpers.startswith('// Shared by'):
    split = helpers.index('\n- (NSString*)')
    static, helpers = helpers[:split], helpers[split:]
program = program.replace('STATIC_HELPER', static).replace('METHODS', declaration('- (BOOL)backgroundControlsAvailable') + '\n' + helpers + '\n' + status)
with tempfile.TemporaryDirectory(prefix='server-presentation-') as directory:
    path=Path(directory); (path/'test.m').write_text(program)
    subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation',str(path/'test.m'),'-o',str(path/'test')],check=True)
    subprocess.run([str(path/'test')],check=True)
