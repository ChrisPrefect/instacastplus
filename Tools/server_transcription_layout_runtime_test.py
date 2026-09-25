#!/usr/bin/env python3
"""Render production transcription cells in UIKit; retain screenshots and measurements."""
import argparse
import json
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser()
parser.add_argument('--device',default='booted')
parser.add_argument('--locale',choices=['de','en'],default='de')
parser.add_argument('--width',type=int,default=393)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
source=(ROOT/'Classes/TranscriptionQueueViewController.m').read_text()
def declaration(signature):
    start=source.rindex(signature);brace=source.index('{',start);depth=0
    for end in range(brace,len(source)):
        depth+=(source[end]=='{')-(source[end]=='}')
        if depth==0:return source[start:end+1]
    raise AssertionError(signature)
status=declaration('- (NSString*)_updateCellStatus:').split('\n    switch (item.status)',1)[0]+'\nreturn nil;\n}'
cell=source[source.index('@interface ICTranscriptionQueueCell'):source.index('// MARK: - Log Detail View')]
parent=(ROOT/'Classes/DownloadsTableViewCell.h').read_text()+(ROOT/'Classes/DownloadsTableViewCell.m').read_text()
parent=re.sub(r'^#import.*\n','',parent,flags=re.M)
program=r'''
#import <UIKit/UIKit.h>
#define ICFontSize(v) (v)
#define ICTextColor UIColor.labelColor
#define ICMutedTextColor UIColor.secondaryLabelColor
#define kEpisodePlayButtonComboStateHolding 0
@interface EpisodePlayComboButton:UIButton
@property NSInteger comboState;
+ (instancetype)button;
@end
@implementation EpisodePlayComboButton
+ (instancetype)button { return [self buttonWithType:UIButtonTypeSystem]; }
@end
PARENT
CELL
typedef NS_ENUM(NSInteger,ICTranscriptionStatus) { ICTranscriptionStatusNone, ICTranscriptionStatusQueued, ICTranscriptionStatusDownloadingModel, ICTranscriptionStatusAnalyzingMusic, ICTranscriptionStatusTranscribing, ICTranscriptionStatusGeneratingChapters, ICTranscriptionStatusCompleted, ICTranscriptionStatusFailed, ICTranscriptionStatusCanceled };
@interface ICTranscriptionQueueItem:NSObject
@property ICTranscriptionStatus status;
@property BOOL usesServerTranscription,serverWaitingForNetwork,requiresExplicitRetryAfterCrash,serverConnectionIssue;
@property NSString *episodeHash,*statusDetail,*error,*serverPhase;
@property NSDate *nextRetryAt,*serverLastResponseAt;
@end
@implementation ICTranscriptionQueueItem @end
@interface ServerTranscriptionManager:NSObject
+ (instancetype)shared;
- (BOOL)hasConfirmedAdmissionForEpisodeHash:(NSString*)hash;
@end
@implementation ServerTranscriptionManager
+ (instancetype)shared { static id m; if(!m)m=[self new];return m; }
- (BOOL)hasConfirmedAdmissionForEpisodeHash:(NSString*)hash { return [hash isEqualToString:@"accepted"]; }
@end
HELPER
@interface Controller:UITableViewController
@property NSArray<ICTranscriptionQueueItem*> *displayedItems;
@end
@implementation Controller
- (NSString*)_elapsedTextForItem:(id)item { return nil; }
- (NSString*)_estimatedRemainingTextForItem:(id)item { return nil; }
METHODS
- (void)viewDidLoad {
 [super viewDidLoad]; self.title=NSLocalizedString(@"Server transcription",nil);
 NSMutableArray *items=[NSMutableArray array];
 NSArray *messages=@[@"Saved on this device. Waiting for internet; the request will be sent automatically when the connection returns.",@"Sending the saved request to the server.",@"Step 2 of 4 · Transcribing audio",@"The server response could not be read. Automatic retries have stopped. Check the saved request again."];
 for(NSInteger i=0;i<4;i++) { ICTranscriptionQueueItem *item=[ICTranscriptionQueueItem new]; item.usesServerTranscription=YES;
 item.status=i==2?ICTranscriptionStatusTranscribing:(i==3?ICTranscriptionStatusFailed:ICTranscriptionStatusQueued);
 item.statusDetail=NSLocalizedString(messages[i],nil);item.serverWaitingForNetwork=i==0;
 item.episodeHash=i==2?@"accepted":@"unsent";
 if(i==2)item.nextRetryAt=[NSDate dateWithTimeIntervalSinceNow:30];if(i==3)item.error=item.statusDetail;
 [items addObject:item]; }
 self.displayedItems=items;
}
- (NSInteger)tableView:(UITableView*)table numberOfRowsInSection:(NSInteger)section {return self.displayedItems.count;}
- (UITableViewCell*)tableView:(UITableView*)table cellForRowAtIndexPath:(NSIndexPath*)path {
 ICTranscriptionQueueCell *cell=[[ICTranscriptionQueueCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
 cell.serverItem=YES;[cell.playAccessoryButton removeFromSuperview];cell.sizeLabel.numberOfLines=0;
 cell.sizeLabel.font=[UIFont systemFontOfSize:13];cell.textLabel.text=@"Another World (SF 26)";
 cell.imageView.image=[UIImage systemImageNamed:@"waveform"];
 UIButton *info=[UIButton buttonWithType:UIButtonTypeInfoLight];info.frame=CGRectMake(0,0,44,44);cell.rightContentAccessoryView=info;
 [self _updateCellStatus:cell withItem:self.displayedItems[path.row]];return cell;
}
- (void)viewDidAppear:(BOOL)animated {
 [super viewDidAppear:animated]; [self.tableView layoutIfNeeded];
 dispatch_async(dispatch_get_main_queue(), ^{
 NSMutableArray *rows=[NSMutableArray array];BOOL passed=YES;
 for(ICTranscriptionQueueCell *cell in self.tableView.visibleCells) {
 CGFloat required=[cell.sizeLabel sizeThatFits:CGSizeMake(cell.sizeLabel.bounds.size.width,CGFLOAT_MAX)].height;
 BOOL fits=required<=cell.sizeLabel.bounds.size.height+0.5;BOOL font=cell.sizeLabel.font.pointSize==13;
 passed=passed&&fits&&font;
 [rows addObject:@{@"text":cell.sizeLabel.text?:@"",@"font":@(cell.sizeLabel.font.pointSize),@"fits":@(fits),@"height":@(cell.bounds.size.height),@"statusHeight":@(cell.sizeLabel.bounds.size.height),@"requiredHeight":@(required)}];
 }
 NSURL *dir=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
 UIWindow *window=self.view.window;UIImage *image=[[[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds] imageWithActions:^(UIGraphicsImageRendererContext *ctx){[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];}];
 [UIImagePNGRepresentation(image) writeToURL:[dir URLByAppendingPathComponent:@"screen.png"] atomically:YES];
 [[NSJSONSerialization dataWithJSONObject:@{@"passed":@(passed),@"rows":rows} options:NSJSONWritingPrettyPrinted error:nil] writeToURL:[dir URLByAppendingPathComponent:@"result.json"] atomically:YES];
 });
}
@end
@interface Scene:NSObject<UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation Scene
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
 self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];CGRect frame=self.window.frame;frame.size.width=TEST_WIDTH;self.window.frame=frame;
 self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
 self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[[Controller alloc] initWithStyle:UITableViewStylePlain]];[self.window makeKeyAndVisible];
}
@end
@interface App:NSObject<UIApplicationDelegate> @end
@implementation App @end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,@"App");}}
'''
program=program.replace('PARENT',parent).replace('CELL',cell).replace('HELPER',source[source.index('// Shared by'):source.index('@interface ICTranscriptionQueueCell')]).replace('METHODS',status+'\n'+declaration('- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:')).replace('TEST_WIDTH',str(args.width))
bundle='com.iteconomy.instacastplus.server-layout-test'
with tempfile.TemporaryDirectory(prefix='server-layout-') as directory:
    tmp=Path(directory);app=tmp/'Layout.app';app.mkdir();(tmp/'main.m').write_text(program)
    (app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleName':'Server layout test','CFBundleExecutable':'Layout','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UIDeviceFamily':[1,2],'UIApplicationSceneManifest':{'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Test','UISceneDelegateClassName':'Scene'}]}}}))
    for locale in ['en','de']:
        folder=app/(locale+'.lproj');folder.mkdir();shutil.copy(ROOT/f'Resources/{locale}.lproj/Localizable.strings',folder)
    sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
    subprocess.run(['xcrun','clang','-fobjc-arc','-target','arm64-apple-ios17.0-simulator','-isysroot',sdk,'-framework','UIKit','-framework','Foundation','-framework','CoreGraphics',str(tmp/'main.m'),'-o',str(app/'Layout')],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
    subprocess.run(['xcrun','simctl','install',args.device,str(app)],check=True)
    container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,bundle,'data'],text=True).strip())
    result=container/'Documents/result.json';result.unlink(missing_ok=True)
    subprocess.run(['xcrun','simctl','launch','--terminate-running-process',args.device,bundle,'-AppleLanguages',f'({args.locale})'],check=True)
    deadline=time.monotonic()+20
    while not result.exists() and time.monotonic()<deadline:time.sleep(.05)
    shutil.copy(result,args.output/'result.json');shutil.copy(container/'Documents/screen.png',args.output/'screen.png')
    data=json.loads(result.read_text());print(json.dumps(data,ensure_ascii=False,indent=2));assert data['passed'],'Server status layout/font does not match the measured presentation'
