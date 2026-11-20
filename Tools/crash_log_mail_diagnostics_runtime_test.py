#!/usr/bin/env python3
"""Exercise the production mail lifecycle observer and result handler.

Failures covered: missing/crossed attempt IDs, losing the presented composer on a
background/foreground round trip, unreported disappearance/deallocation, absent
result/error details, and erasing the sent result when old logs are cleared.
An isolated check is needed because a configured MessageUI account and a mail
service termination are not reliably available in the simulator. UIKit boundary
doubles deliver the callbacks; unchanged production methods write a real JSONL
artifact. This does not reproduce the user's mail service or prove draft recovery.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Classes/OptionsViewController.m').read_text()


def method(signature):
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if not depth:
            return source[start:end + 1]
    raise AssertionError(signature)


name = 'ICCrashLogMailComposeViewController'
assert '@interface ' + name in source, 'Crash-log composer has no lifecycle diagnostics'
start = source.index('@interface ' + name)
interface = source[start:source.index('@end', start) + 4]
start = source.index('@implementation ' + name)
implementation = source[start:source.index('@end', start) + 4]
delegate = method('- (void)mailComposeController:')
action = method('- (void)emailCrashLogsClicked')

program = r'''
#import <Foundation/Foundation.h>
#include <stdio.h>
@interface NSString(Localization)
@property(readonly) NSString* ls;
@end
@implementation NSString(Localization)
- (NSString*)ls {return self;}
@end
typedef NSInteger UIApplicationState;
enum { UIApplicationStateActive, UIApplicationStateInactive, UIApplicationStateBackground };
typedef NSInteger MFMailComposeResult;
enum { MFMailComposeResultCancelled, MFMailComposeResultSaved, MFMailComposeResultSent, MFMailComposeResultFailed };
static NSString* UIApplicationWillResignActiveNotification=@"resign";
static NSString* UIApplicationDidEnterBackgroundNotification=@"background";
static NSString* UIApplicationWillEnterForegroundNotification=@"foreground";
static NSString* UIApplicationDidBecomeActiveNotification=@"active";
static NSString* UIApplicationWillTerminateNotification=@"terminate";
static NSString* UIApplicationDidReceiveMemoryWarningNotification=@"memory";
static NSString* UISceneDidDisconnectNotification=@"disconnect";
@interface UIApplication:NSObject
@property NSInteger applicationState;
+ (instancetype)sharedApplication;
@end
@implementation UIApplication
+ (instancetype)sharedApplication {static id app;if(!app)app=[self new];return app;}
@end
@interface SceneSession:NSObject
@property NSString* persistentIdentifier;
@end
@implementation SceneSession @end
@interface UIScene:NSObject
@property NSInteger activationState;
@property SceneSession* session;
@end
@implementation UIScene @end
@interface UIWindowScene:UIScene @end
@implementation UIWindowScene @end
@interface UIWindow:NSObject
@property UIWindowScene* windowScene;
@end
@implementation UIWindow @end
@interface UIView:NSObject
@property UIWindow* window;
@end
@implementation UIView @end
@interface MFMailComposeViewController:NSObject
@property(weak) id mailComposeDelegate;
@property UIView* viewIfLoaded;
@property NSObject* presentingViewController;
@property NSObject* presentedViewController;
@property BOOL isBeingDismissed, isBeingPresented;
+ (BOOL)canSendMail;
- (void)setSubject:(NSString*)value;
- (void)setToRecipients:(NSArray*)value;
- (void)setMessageBody:(NSString*)value isHTML:(BOOL)html;
- (void)addAttachmentData:(NSData*)data mimeType:(NSString*)type fileName:(NSString*)name;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)viewDidDisappear:(BOOL)animated;
@end
@implementation MFMailComposeViewController
+ (BOOL)canSendMail {return YES;}
- (void)setSubject:(NSString*)value {}
- (void)setToRecipients:(NSArray*)value {}
- (void)setMessageBody:(NSString*)value isHTML:(BOOL)html {}
- (void)addAttachmentData:(NSData*)data mimeType:(NSString*)type fileName:(NSString*)name {}
- (void)viewWillAppear:(BOOL)animated {}
- (void)viewDidAppear:(BOOL)animated {}
- (void)viewWillDisappear:(BOOL)animated {}
- (void)viewDidDisappear:(BOOL)animated {}
@end
static NSString* output;
@interface ICDiagnosticMailAttachment:NSObject
@property NSString* fileName;
@property NSString* mimeType;
@property NSData* data;
@end
@implementation ICDiagnosticMailAttachment @end
@interface ICDiagnosticLogger:NSObject
+ (instancetype)shared;
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata;
- (void)clearCrashLogMailArtifacts;
- (NSString*)crashLogMailBody;
- (NSArray*)crashLogMailAttachments;
@end
@implementation ICDiagnosticLogger
+ (instancetype)shared {static id logger;if(!logger)logger=[self new];return logger;}
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata {
 NSMutableData* data=[[NSJSONSerialization dataWithJSONObject:@{@"category":category,@"message":message,@"metadata":metadata} options:0 error:nil] mutableCopy];
 [data appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
 NSFileHandle* file=[NSFileHandle fileHandleForWritingAtPath:output];
 if(file){[file seekToEndOfFile];[file writeData:data];[file closeFile];}
 else [data writeToFile:output atomically:YES];
}
- (void)clearCrashLogMailArtifacts { [NSData.data writeToFile:output atomically:YES]; }
- (NSString*)crashLogMailBody {return @"Fixture";}
- (NSArray*)crashLogMailAttachments {
 ICDiagnosticMailAttachment* file=[ICDiagnosticMailAttachment new];
 file.fileName=@"InstacastPlus-CrashLogs.txt";file.mimeType=@"text/plain";file.data=[@"fixture" dataUsingEncoding:NSUTF8StringEncoding];return @[file];
}
@end
INTERFACE
IMPLEMENTATION
@interface OptionsViewController:NSObject
@property BOOL sendingCrashLogMail;
@property(copy) void(^dismissCompletion)(void);
@property MFMailComposeViewController* presentedViewController;
@property NSInteger dismissals, errors;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void(^)(void))completion;
- (void)presentError:(NSError*)error;
- (void)presentViewController:(MFMailComposeViewController*)controller animated:(BOOL)animated completion:(void(^)(void))completion;
- (void)presentAlertControllerWithTitle:(NSString*)title message:(NSString*)message button:(NSString*)button animated:(BOOL)animated completion:(void(^)(void))completion;
@end
@implementation OptionsViewController
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void(^)(void))completion {self.dismissals++;self.dismissCompletion=completion;}
- (void)presentError:(NSError*)error {self.errors++;}
- (void)presentViewController:(MFMailComposeViewController*)controller animated:(BOOL)animated completion:(void(^)(void))completion {self.presentedViewController=controller;if(completion)completion();}
- (void)presentAlertControllerWithTitle:(NSString*)title message:(NSString*)message button:(NSString*)button animated:(BOOL)animated completion:(void(^)(void))completion {self.errors++;}
ACTION
DELEGATE
@end
static void require(BOOL condition, NSString* message) {
 if(!condition){fprintf(stderr,"FAIL: %s\n",message.UTF8String);exit(1);}
}
static NSArray* events(void) {
 NSMutableArray* result=[NSMutableArray array];
 for(NSString* line in [[NSString stringWithContentsOfFile:output encoding:NSUTF8StringEncoding error:nil] componentsSeparatedByString:@"\n"]){
  if(!line.length)continue;
  NSDictionary* entry=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  require(entry!=nil,@"Every retained event must be valid JSON");[result addObject:entry];
 }
 return result;
}
int main(int argc,const char* argv[]){@autoreleasepool{
 output=@(argv[1]);
 __weak id released;
 NSString* firstID;
 @autoreleasepool{
  ICCrashLogMailComposeViewController* composer=[ICCrashLogMailComposeViewController new];released=composer;
  firstID=composer.diagnosticAttemptID;
  composer.viewIfLoaded=[UIView new];composer.viewIfLoaded.window=[UIWindow new];
  composer.viewIfLoaded.window.windowScene=[UIWindowScene new];
  composer.viewIfLoaded.window.windowScene.session=[SceneSession new];
  composer.viewIfLoaded.window.windowScene.session.persistentIdentifier=@"fixture-scene";
  composer.presentingViewController=[NSObject new];
  [composer viewWillAppear:YES];[composer viewDidAppear:YES];
  for(NSString* event in @[UIApplicationWillResignActiveNotification,UIApplicationDidEnterBackgroundNotification,UIApplicationWillEnterForegroundNotification,UIApplicationDidBecomeActiveNotification,UIApplicationDidReceiveMemoryWarningNotification,UIApplicationWillTerminateNotification]){
   [UIApplication sharedApplication].applicationState=[event isEqual: UIApplicationDidEnterBackgroundNotification]?2:0;
   [[NSNotificationCenter defaultCenter] postNotificationName:event object:nil];
  }
  NSArray* lines=events();NSMutableSet* messages=[NSMutableSet set];
  for(NSDictionary* entry in lines){
   require([entry[@"metadata"][@"attemptID"] isEqual:firstID],@"Lifecycle events must share one attempt ID");
   [messages addObject:entry[@"message"]];
   if([entry[@"message"] isEqual:UIApplicationDidEnterBackgroundNotification]){
    require([entry[@"metadata"][@"composerPresented"] boolValue],@"Backgrounding must record that the same composer remains presented");
    require([entry[@"metadata"][@"applicationState"] integerValue]==2,@"Background state missing");
   }
  }
  require([messages containsObject:UIApplicationDidBecomeActiveNotification] && [messages containsObject:UIApplicationWillTerminateNotification],@"Foreground/termination events missing");
  composer.isBeingDismissed=YES;[composer viewWillDisappear:YES];composer.presentingViewController=nil;composer.viewIfLoaded.window=nil;[composer viewDidDisappear:YES];
 }
 require(released==nil,@"Diagnostics must not retain the composer/draft");
 require([events().lastObject[@"message"] isEqual:@"deallocated"],@"Composer deallocation must be recorded");
 for(NSNumber* result in @[@0,@1,@2,@3]){
  ICCrashLogMailComposeViewController* composer=[ICCrashLogMailComposeViewController new];
  require(![composer.diagnosticAttemptID isEqual:firstID],@"Each attempt requires a new ID");
  OptionsViewController* owner=[OptionsViewController new];owner.sendingCrashLogMail=YES;
  NSError* error=result.integerValue==3?[NSError errorWithDomain:@"MailFixture" code:42 userInfo:nil]:nil;
  [owner mailComposeController:composer didFinishWithResult:result.integerValue error:error];
  require(owner.dismissals==1 && !owner.sendingCrashLogMail,@"Existing dismissal behavior changed");
  require(owner.errors==(error?1:0),@"Existing error presentation changed");
  require(owner.dismissCompletion!=nil,@"Missing dismissal completion");owner.dismissCompletion();owner.dismissCompletion=nil;
  BOOL found=NO;
  for(NSDictionary* entry in events()){
   NSDictionary* metadata=entry[@"metadata"];
   if([entry[@"message"] isEqual:@"dismiss-completed"] && [metadata[@"attemptID"] isEqual:composer.diagnosticAttemptID]){
    found=YES;require([metadata[@"result"] integerValue]==result.integerValue,@"Result must survive clearing old logs");
    require([metadata[@"errorCode"] integerValue]==(error?42:0),@"Mail service error details missing");
   }
  }
  require(found,@"Result/dismiss completion was not retained");
 }
 OptionsViewController* owner=[OptionsViewController new];[owner emailCrashLogsClicked];
 require([owner.presentedViewController isKindOfClass:ICCrashLogMailComposeViewController.class],@"Real settings action must present the diagnostic composer");
 require([events().lastObject[@"message"] isEqual:@"presentation-completed"],@"Presentation completion missing");
 BOOL prepared=NO;
 for(NSDictionary* event in events())if([event[@"message"] isEqual:@"presentation-requested"]){
  prepared=YES;require([event[@"metadata"][@"attachmentBytes"] integerValue]==7 && [event[@"metadata"][@"attachmentCount"] integerValue]==1,@"Attachment size/count missing");
 }
 require(prepared,@"Presentation request missing");
 puts("PASS: production settings action and mail diagnostic contract: lifecycle snapshots, deallocation, results/errors and post-send evidence");
}return 0;}
'''.replace('INTERFACE', interface).replace('IMPLEMENTATION', implementation).replace('DELEGATE', delegate).replace('ACTION', action)

with tempfile.TemporaryDirectory(prefix='instacast-crash-mail-') as directory:
    path = Path(directory)
    (path / 'probe.m').write_text(program)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    str(path / 'probe.m'), '-o', str(path / 'probe')], check=True)
    subprocess.run([str(path / 'probe'), str(path / 'events.jsonl')], check=True)
    # Also compile the observer against the actual UIKit/MessageUI declarations.
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    (path / 'sdk.m').write_text('''#import <MessageUI/MessageUI.h>
@interface NSString(Localization)
@property(readonly) NSString* ls;
@end
@interface ICDiagnosticMailAttachment:NSObject
@property NSString* fileName;
@property NSString* mimeType;
@property NSData* data;
@end
@interface ICDiagnosticLogger:NSObject
+ (instancetype)shared;
- (void)logEvent:(NSString*)category message:(NSString*)message metadata:(NSDictionary*)metadata;
- (void)clearCrashLogMailArtifacts;
- (NSString*)crashLogMailBody;
- (NSArray*)crashLogMailAttachments;
@end
''' + interface + '\n' + implementation + '''
@interface UIViewController(Alerts)
- (void)presentError:(NSError*)error;
- (void)presentAlertControllerWithTitle:(NSString*)title message:(NSString*)message button:(NSString*)button animated:(BOOL)animated completion:(void(^)(void))completion;
@end
@interface OptionsViewController:UIViewController<MFMailComposeViewControllerDelegate>
@property BOOL sendingCrashLogMail;
@end
@implementation OptionsViewController
''' + action + '\n' + delegate + '\n@end\n')
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-fsyntax-only', '-Werror',
                    '-target', 'arm64-apple-ios17.0-simulator', '-isysroot', sdk,
                    str(path / 'sdk.m')], check=True)
