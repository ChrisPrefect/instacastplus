#!/usr/bin/env python3
"""Exercise the player's real footer delegate methods in an isolated UIKit app."""
import argparse
from pathlib import Path
import plistlib
import json
import re
import time
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--device", default="6EF3C6D3-EF95-486B-B059-82AFE419404A")
parser.add_argument("--width", type=int, default=0)
parser.add_argument("--locale", choices=["de", "en"], default="de")
args = parser.parse_args()
source = (ROOT / "Classes/PlayerInfoViewController_v5.m").read_text()

def method(signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(signature)

signatures = ["- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:", "- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:", "- (void)_updateAudioIdentityNotice"]
for signature in ["- (void)_configureAudioIdentityFooter:", "- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:"]:
    if signature in source:
        signatures.append(signature)
methods = "\n".join(method(s) for s in signatures)
keys = re.findall(r'NSLocalizedString\(@("(?:[^"\\]|\\.)*")', method("- (NSString*)_audioIdentityNotice"))
translations = dict((json.loads(key), json.loads(value)) for key, value in
                    re.findall(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;',
                               (ROOT / f"Resources/{args.locale}.lproj/Localizable.strings").read_text()))
notice = max((translations[json.loads(key)] for key in keys), key=len)
program = r'''
#import <UIKit/UIKit.h>
#define ICMutedTextColor UIColor.secondaryLabelColor
@interface Episode:NSObject @property id feed; @end
@implementation Episode @end
@interface PlaybackManager:NSObject
+ (instancetype)playbackManager;
- (BOOL)autoSkipsChapterTitle:(NSString*)title forFeed:(id)feed;
@property Episode *playingEpisode;
@end
@implementation PlaybackManager
+ (instancetype)playbackManager { return nil; }
- (BOOL)autoSkipsChapterTitle:(NSString*)title forFeed:(id)feed { return NO; }
@end
@interface NoticeController:UITableViewController
@property BOOL showsNotice;
@property NSString *displayedAudioIdentityNotice;
@property NSArray *chapters;
@end
@implementation NoticeController
- (NSInteger)_chaptersSection { return 0; }
- (NSString*)_audioIdentityNotice { return self.showsNotice ? NOTICE_TEXT : nil; }
- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView { return 3; }
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section { return 0; }
METHODS
- (void)viewDidAppear:(BOOL)animated {
 [super viewDidAppear:animated];
 self.chapters = @[];
 self.showsNotice = YES;
 [self _updateAudioIdentityNotice];
 [self.tableView layoutIfNeeded];
 UITableViewHeaderFooterView *footer = [self.tableView footerViewForSection:0];
 UIListContentConfiguration *config = (id)footer.contentConfiguration;
 NSString *text = [self _audioIdentityNotice];
 BOOL multiline = [config isKindOfClass:UIListContentConfiguration.class] && config.textProperties.numberOfLines == 0;
 UIFont *font = multiline ? config.textProperties.font : footer.textLabel.font;
 CGFloat width = CGRectGetWidth(self.tableView.bounds) - 32;
 UILabel *measurement = [UILabel new]; measurement.font = font; measurement.text = text; measurement.numberOfLines = 0;
 CGFloat required = [measurement sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height;
 BOOL fits = CGRectGetHeight(footer.bounds) + 1.0 / UIScreen.mainScreen.scale >= required + 24;
 NSDictionary *result = @{@"text":text, @"fontSize":@(font.pointSize), @"multiline":@(multiline), @"fits":@(fits), @"height":@(CGRectGetHeight(footer.bounds)), @"requiredTextHeight":@(required)};
 NSURL *url = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"result.json"];
 [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToURL:url atomically:YES];
}
@end
@interface App:NSObject<UIApplicationDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation App
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
 CGRect frame = UIScreen.mainScreen.bounds; if (TEST_WIDTH > 0) frame.size.width = TEST_WIDTH;
 self.window = [[UIWindow alloc] initWithFrame:frame];
 self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
 self.window.rootViewController = [[NoticeController alloc] initWithStyle:UITableViewStylePlain];
 [self.window makeKeyAndVisible]; return YES;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,@"App"); } }
'''.replace("METHODS", methods).replace("TEST_WIDTH", str(args.width)).replace("NOTICE_TEXT", "@" + json.dumps(notice, ensure_ascii=False))
bundle = "com.iteconomy.instacastplus.notice-regression"
with tempfile.TemporaryDirectory(prefix="instacast-notice-layout-") as directory:
    tmp = Path(directory)
    app = tmp / "Notice.app"
    app.mkdir()
    (tmp / "main.m").write_text(program)
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":bundle,"CFBundleName":"Notice regression","CFBundleExecutable":"Notice","CFBundlePackageType":"APPL","CFBundleVersion":"1","CFBundleShortVersionString":"1","LSRequiresIPhoneOS":True,"UILaunchScreen":{},"UIDeviceFamily":[1,2]}))
    sdk = subprocess.check_output(["xcrun","--sdk","iphonesimulator","--show-sdk-path"],text=True).strip()
    subprocess.run(["xcrun","clang","-fobjc-arc","-target","arm64-apple-ios17.0-simulator","-isysroot",sdk,"-framework","UIKit","-framework","Foundation","-framework","CoreGraphics",str(tmp/"main.m"),"-o",str(app/"Notice")],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(["codesign","--force","--sign","-",str(app)],check=True,stdout=subprocess.DEVNULL)
    subprocess.run(["xcrun","simctl","install",args.device,str(app)],check=True)
    container = Path(subprocess.check_output(["xcrun","simctl","get_app_container",args.device,bundle,"data"],text=True).strip())
    result_file = container / "Documents/result.json"
    result_file.unlink(missing_ok=True)
    subprocess.run(["xcrun","simctl","launch",args.device,bundle],check=True)
    deadline = time.monotonic() + 15
    while not result_file.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    result = json.loads(result_file.read_text())
    print(result)
    assert result["multiline"] and result["fits"], "Player footer truncates its notice"
