#!/usr/bin/env python3
"""Exercise the production icon-suggestion action with real Foundation URLs.

The native E2E covers the actual default-client handoff. This isolated check is
needed for the unavailable-handler path: forcing that through E2E would require
changing the user's system mail association or removing mail applications.
Concrete failures: gating on Apple Mail account state despite another default
client, presenting an embedded composer, wrong recipient, missing/damaged DE/EN
subject/body during URL encoding, a premature error while the asynchronous open
is pending, an error after success, or no localized error when opening fails.
Only UIKit's external open and alert presentation are recording doubles; the
actual production action and real shipped localization files execute unchanged.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'Classes/AppearanceSettingsViewController.m').read_text()
start = source.index('- (void) suggestAppIconsAction:(id)sender')
brace = source.index('{', start)
depth = 0
for end in range(brace, len(source)):
    depth += (source[end] == '{') - (source[end] == '}')
    if depth == 0:
        action = source[start:end + 1]
        break

harness = r'''
#import <Foundation/Foundation.h>
#include <stdio.h>
static NSDictionary* translations;
@interface NSString (Localization)
@property(readonly) NSString* ls;
@end
@implementation NSString (Localization)
- (NSString*)ls { return translations[self] ?: self; }
@end
@interface UIApplication : NSObject
@property NSURL* openedURL;
@property(copy) void(^completion)(BOOL);
+ (instancetype)sharedApplication;
- (void)openURL:(NSURL*)url options:(NSDictionary*)options completionHandler:(void(^)(BOOL))completion;
@end
@implementation UIApplication
+ (instancetype)sharedApplication { static UIApplication* app; if (!app) app = [self new]; return app; }
- (void)openURL:(NSURL*)url options:(NSDictionary*)options completionHandler:(void(^)(BOOL))completion {
    self.openedURL = url; self.completion = completion;
}
@end
// Only needed so the pre-change production action can compile and prove failure.
@interface MFMailComposeViewController : NSObject
@property id mailComposeDelegate;
+ (BOOL)canSendMail;
- (void)setSubject:(NSString*)s;
- (void)setToRecipients:(NSArray*)a;
- (void)setMessageBody:(NSString*)s isHTML:(BOOL)html;
@end
@implementation MFMailComposeViewController
+ (BOOL)canSendMail { return NO; }
- (void)setSubject:(NSString*)s {}
- (void)setToRecipients:(NSArray*)a {}
- (void)setMessageBody:(NSString*)s isHTML:(BOOL)html {}
@end
@interface AppearanceSettingsViewController : NSObject
@property NSInteger alerts, embeddedComposers;
@property NSString* alertTitle;
@property NSString* alertMessage;
- (void)presentAlertControllerWithTitle:(NSString*)title message:(NSString*)message button:(NSString*)button animated:(BOOL)animated completion:(void(^)(void))completion;
- (void)presentViewController:(id)controller animated:(BOOL)animated completion:(void(^)(void))completion;
@end
@implementation AppearanceSettingsViewController
- (void)presentAlertControllerWithTitle:(NSString*)title message:(NSString*)message button:(NSString*)button animated:(BOOL)animated completion:(void(^)(void))completion {
    self.alerts++; self.alertTitle = title; self.alertMessage = message;
}
- (void)presentViewController:(id)controller animated:(BOOL)animated completion:(void(^)(void))completion { self.embeddedComposers++; }
ACTION
@end
static int failures;
static void require(BOOL ok, NSString* message) {
    if (!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); failures++; }
}
int main(int argc, const char* argv[]) { @autoreleasepool {
    for (NSString* language in @[@"de", @"en"]) {
        NSString* path = [NSString stringWithFormat:@"%s/Resources/%@.lproj/Localizable.strings", argv[1], language];
        translations = [NSDictionary dictionaryWithContentsOfFile:path];
        require(translations != nil, @"Real localization table must load");
        UIApplication* app = [UIApplication sharedApplication];
        for (NSNumber* succeeds in @[@YES, @NO]) {
            app.openedURL = nil; app.completion = nil;
            AppearanceSettingsViewController* controller = [AppearanceSettingsViewController new];
            [controller suggestAppIconsAction:nil];
            require(app.openedURL != nil, @"Icon suggestion must open an external URL even when Apple Mail cannot send");
            if (!app.openedURL) continue;
            require(controller.embeddedComposers == 0, @"No embedded composer may be presented");
            require(controller.alerts == 0, @"No error before asynchronous opening finishes");
            NSURLComponents* url = [NSURLComponents componentsWithURL:app.openedURL resolvingAgainstBaseURL:NO];
            require([url.scheme isEqual:@"mailto"] && [url.path isEqual:@"info@instacast.ch"], @"Wrong external mail recipient");
            NSMutableDictionary* query = [NSMutableDictionary dictionary];
            for (NSURLQueryItem* item in url.queryItems) query[item.name] = item.value;
            BOOL german = [language isEqual:@"de"];
            require([query[@"subject"] isEqual:german ? @"App-Icon-Vorschlag" : @"App Icon Suggestion"], @"Subject must survive localized URL round trip");
            require([query[@"body"] isEqual:german ? @"Bitte hängen Sie Ihre Icon-Dateien an oder fügen Sie einen Link zu Ihrem Entwurf ein." : @"Please attach your icon files or include a link to your design."], @"Body must survive localized URL round trip, including German umlauts");
            require(app.completion != nil, @"Missing external-open completion handler");
            if (app.completion) app.completion(succeeds.boolValue);
            require(controller.alerts == (succeeds.boolValue ? 0 : 1), @"Only a failed handoff shows one error");
            if (!succeeds.boolValue) {
                require([controller.alertTitle isEqual:translations[@"Email not configured."]], @"Failure title must be localized");
                require([controller.alertMessage isEqual:translations[@"Please configure email on this device."]], @"Failure message must be localized");
            }
        }
    }
    if (failures) return 1;
    puts("PASS: production mail action, DE/EN URL round trips, Apple Mail unavailable, asynchronous success/failure");
    return 0;
}}
'''.replace('ACTION', action)
with tempfile.TemporaryDirectory(prefix='instacast-icon-mail-url-') as directory:
    path = Path(directory)
    (path / 'test.m').write_text(harness)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
                    str(path / 'test.m'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test'), str(ROOT)], check=True)
