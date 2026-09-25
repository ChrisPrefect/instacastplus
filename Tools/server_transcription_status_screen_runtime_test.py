#!/usr/bin/env python3
"""Render the real status controller with deterministic queue boundaries, not a full app E2E."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--device', default='675CC86D-C1EA-41D7-A244-0318E0EE1121')
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--locale', default='de', choices=['de', 'en'])
parser.add_argument('--scenario', default='running', choices=['offline', 'sending', 'running', 'retrying', 'failed', 'import', 'completed'])
parser.add_argument('--width', type=int, default=393)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
source = (ROOT / 'Classes/TranscriptionQueueViewController.m').read_text()
helpers = source[source.index('// Shared by'):source.index('@interface ICTranscriptionQueueCell')]
controller = source[source.index('@interface TranscriptionLogDetailViewController'):source.index('@interface TranscriptionQueue (')]
program = r'''
#import <UIKit/UIKit.h>
#define ICFontSize(v) (v)
#define ICTextColor UIColor.labelColor
#define ICMutedTextColor UIColor.secondaryLabelColor
#define ICBackgroundColor UIColor.systemBackgroundColor
#define ICTintColor UIColor.systemOrangeColor
typedef NS_ENUM(NSInteger,ICTranscriptionStatus) { ICTranscriptionStatusNone, ICTranscriptionStatusQueued, ICTranscriptionStatusDownloadingModel, ICTranscriptionStatusAnalyzingMusic, ICTranscriptionStatusTranscribing, ICTranscriptionStatusGeneratingChapters, ICTranscriptionStatusCompleted, ICTranscriptionStatusFailed, ICTranscriptionStatusCanceled };
@interface ICTranscriptionQueueItem:NSObject
@property ICTranscriptionStatus status;
@property BOOL usesServerTranscription,serverWaitingForNetwork,requiresExplicitRetryAfterCrash,serverConnectionIssue;
@property NSString *episodeHash,*episodeTitle,*feedTitle,*statusDetail,*error,*serverPhase;
@property NSDate *nextRetryAt,*serverLastResponseAt;
@end
@implementation ICTranscriptionQueueItem @end
@interface ServerTranscriptionManager:NSObject
@property NSArray *items;
+ (instancetype)shared;
- (BOOL)hasConfirmedAdmissionForEpisodeHash:(NSString*)hash;
- (void)retryEpisodeHash:(NSString*)hash;
- (void)dequeueEpisodeHash:(NSString*)hash;
@end
@implementation ServerTranscriptionManager
+ (instancetype)shared { static id m; if(!m)m=[self new];return m; }
- (BOOL)hasConfirmedAdmissionForEpisodeHash:(NSString*)hash { return ![@[@"offline",@"sending"] containsObject:@"SCENARIO"]; }
- (void)retryEpisodeHash:(NSString*)hash {}
- (void)dequeueEpisodeHash:(NSString*)hash {}
@end
@interface ICTranscriptionLogEntry:NSObject
@property NSString *phase,*message,*detailText;
@property NSDate *timestamp;
@end
@implementation ICTranscriptionLogEntry @end
@interface TranscriptionLogger:NSObject
+ (instancetype)shared;
- (NSArray*)entriesWithEpisodeHash:(NSString*)hash;
@end
@implementation TranscriptionLogger
+ (instancetype)shared { static id m; if(!m)m=[self new];return m; }
- (NSArray*)entriesWithEpisodeHash:(NSString*)hash {
 ICTranscriptionLogEntry *e=[ICTranscriptionLogEntry new];e.phase=@"status";e.message=@"Previous diagnostic event";e.timestamp=[NSDate date];return @[e];
}
@end
HELPERS
CONTROLLER
@interface FixtureStatusController:TranscriptionLogDetailViewController
@property (nonatomic,copy) void (^capture)(void);
@end
@implementation FixtureStatusController
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if(self.capture)self.capture(); }
@end
@interface Scene:NSObject<UIWindowSceneDelegate> @property (nonatomic,strong) UIWindow *window; @end
@implementation Scene
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
 ICTranscriptionQueueItem *item=[ICTranscriptionQueueItem new];item.usesServerTranscription=YES;item.episodeHash=@"fixture";item.episodeTitle=@"Another World (SF 26)";
 item.status=ICTranscriptionStatusTranscribing;item.serverPhase=@"transcribing";
 item.statusDetail=NSLocalizedString(@"Step 2 of 4 · Transcribing audio",nil);
 item.serverLastResponseAt=[NSDate date];item.nextRetryAt=[NSDate dateWithTimeIntervalSinceNow:30];
 NSString *scenario=@"SCENARIO";
 if([scenario isEqual:@"offline"]) {item.serverWaitingForNetwork=YES;item.status=ICTranscriptionStatusQueued;item.serverPhase=nil;item.serverLastResponseAt=nil;item.statusDetail=NSLocalizedString(@"Saved on this device. Waiting for internet; the request will be sent automatically when the connection returns.",nil);}
 if([scenario isEqual:@"sending"]) {item.serverPhase=@"sending";item.serverLastResponseAt=nil;item.nextRetryAt=nil;item.statusDetail=NSLocalizedString(@"Sending the saved request to the server.",nil);}
 if([scenario isEqual:@"retrying"]) {item.serverConnectionIssue=YES;item.statusDetail=NSLocalizedString(@"Server vorübergehend nicht erreichbar. Neuer Versuch ist geplant.",nil);}
 if([scenario isEqual:@"failed"]||[scenario isEqual:@"import"]) {item.status=ICTranscriptionStatusFailed;item.nextRetryAt=nil;item.serverPhase=[scenario isEqual:@"import"]?@"importing":@"failed";item.error=NSLocalizedString(@"Das Server-Ergebnis ist unvollständig oder enthält doppelte Artefakte.",nil);}
 if([scenario isEqual:@"completed"]) {item.status=ICTranscriptionStatusCompleted;item.nextRetryAt=nil;}
 ServerTranscriptionManager.shared.items=@[item];
 self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];CGRect frame=self.window.frame;frame.size.width=TEST_WIDTH;self.window.frame=frame;
 self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
 FixtureStatusController *vc=[[FixtureStatusController alloc] initWithStyle:UITableViewStyleInsetGrouped];vc.episodeHash=item.episodeHash;vc.displayTitle=item.episodeTitle;
 self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:vc];[self.window makeKeyAndVisible];
 vc.capture = ^{
 [vc.view layoutIfNeeded];[vc.tableView layoutIfNeeded];
 NSMutableArray *nodes=[NSMutableArray array];
 __block void (^walk)(UIView*);walk=^(UIView *view){if(view.accessibilityIdentifier||[view isKindOfClass:UILabel.class]) [nodes addObject:@{@"id":view.accessibilityIdentifier?:@"",@"text":[view isKindOfClass:UILabel.class]?((UILabel*)view).text?:@"":@""}];for(UIView *child in view.subviews)walk(child);};walk(vc.view);walk=nil;
 BOOL title=NO,next=NO,process=NO,historyHidden=YES;
 for(NSDictionary *node in nodes){title|=[node[@"id"] isEqual:@"ICServerStatusTitle"];next|=[node[@"id"] isEqual:@"ICServerNextAction"];process|=[node[@"id"] isEqual:@"ICServerProcess"];if([node[@"text"] containsString:@"Previous diagnostic event"])historyHidden=NO;}
 NSURL *dir=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
 UIImage *image=[[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds] imageWithActions:^(UIGraphicsImageRendererContext *ctx){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
 [UIImagePNGRepresentation(image) writeToURL:[dir URLByAppendingPathComponent:@"screen.png"] atomically:YES];
 [[NSJSONSerialization dataWithJSONObject:@{@"passed":@(title&&next&&process&&historyHidden),@"title":@(title),@"nextAction":@(next),@"process":@(process),@"historyHidden":@(historyHidden),@"nodes":nodes} options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[dir URLByAppendingPathComponent:@"result.json"] atomically:YES];
 };
}
@end
@interface App:NSObject<UIApplicationDelegate> @end
@implementation App @end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,@"App");}}
'''.replace('HELPERS', helpers).replace('CONTROLLER', controller).replace('SCENARIO', args.scenario).replace('TEST_WIDTH', str(args.width))
bundle = 'com.iteconomy.instacastplus.server-status-test'
with tempfile.TemporaryDirectory(prefix='server-status-') as directory:
    tmp = Path(directory)
    app = tmp / 'Status.app'
    app.mkdir()
    (tmp / 'main.m').write_text(program)
    (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle, 'CFBundleName': 'Server status test', 'CFBundleExecutable': 'Status', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'CFBundleShortVersionString': '1', 'LSRequiresIPhoneOS': True, 'UILaunchScreen': {}, 'UIDeviceFamily': [1, 2], 'UIApplicationSceneManifest': {'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{'UISceneConfigurationName': 'Test', 'UISceneDelegateClassName': 'Scene'}]}}}))
    for locale in ['en', 'de']:
        folder = app / (locale + '.lproj')
        folder.mkdir()
        shutil.copy(ROOT / f'Resources/{locale}.lproj/Localizable.strings', folder)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk, '-framework', 'UIKit', '-framework', 'CoreGraphics', '-framework', 'Foundation', str(tmp / 'main.m'), '-o', str(app / 'Status')], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    subprocess.run(['xcrun', 'simctl', 'install', args.device, str(app)], check=True)
    container = Path(subprocess.check_output(['xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data'], text=True).strip())
    result = container / 'Documents/result.json'
    result.unlink(missing_ok=True)
    subprocess.run(['xcrun', 'simctl', 'launch', '--terminate-running-process', args.device, bundle, '-AppleLanguages', f'({args.locale})'], check=True)
    deadline = time.monotonic() + 20
    while not result.exists() and time.monotonic() < deadline:
        time.sleep(.05)
    shutil.copy(result, args.output / 'result.json')
    shutil.copy(container / 'Documents/screen.png', args.output / 'screen.png')
    data = json.loads(result.read_text())
    print(json.dumps(data, ensure_ascii=False, indent=2))
    assert data['passed'], 'Status needs a distinct current state, next action, process and collapsed diagnostics'
