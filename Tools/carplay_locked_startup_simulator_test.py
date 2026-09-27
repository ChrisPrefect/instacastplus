#!/usr/bin/env python3
"""Probe real app startup with the locked-device API value injected in Simulator.

See carplay_locked_startup_investigation.md for failure analysis and limitations.
Uses an explicitly selected disposable simulator; does not reset its app data.
The injected library is test-only and never becomes part of the app bundle.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

BUNDLE = "com.iteconomy.instacastplus"
HOOK = r'''
#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>
#import <objc/runtime.h>

static BOOL unlocked;
static BOOL protectedDataAvailable(id object, SEL selector) { return unlocked; }

@interface ICStartupProbe : NSObject
@end
@implementation ICStartupProbe
+ (void)load {
    // Override only the application's inherited getter, never its startup code.
    if (getenv("IC_PROBE_LOCKED")) {
        Class application = NSClassFromString(@"Application");
        Method getter = class_getInstanceMethod(UIApplication.class, @selector(isProtectedDataAvailable));
        NSCAssert(application && class_addMethod(application, @selector(isProtectedDataAvailable),
                  (IMP)protectedDataAvailable, method_getTypeEncoding(getter)), @"Probe injection failed");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* report = [documents stringByAppendingPathComponent:@"startup-probe.json"];
        NSString* unlock = [documents stringByAppendingPathComponent:@"startup-probe-unlock"];
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer* timer) {
            UIApplication* app = UIApplication.sharedApplication;
            if (!app.delegate) return;
            if (!unlocked && [[NSFileManager defaultManager] fileExistsAtPath:unlock]) {
                unlocked = YES;
                [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationProtectedDataDidBecomeAvailable object:app];
            }
            id main = [(NSObject*)app.delegate valueForKey:@"mainViewController"];
            NSMutableArray* scenes = [NSMutableArray array];
            for (UIScene* scene in app.connectedScenes) {
                NSMutableDictionary* state = [@{@"role": scene.session.role,
                    @"activationState": @(scene.activationState)} mutableCopy];
                if ([scene isKindOfClass:CPTemplateApplicationScene.class]) {
                    CPTemplate* root = ((CPTemplateApplicationScene*)scene).interfaceController.rootTemplate;
                    state[@"rootClass"] = root ? NSStringFromClass(root.class) : @"";
                    if ([root isKindOfClass:CPListTemplate.class]) {
                        state[@"title"] = ((CPListTemplate*)root).title ?: @"";
                        state[@"sections"] = @(((CPListTemplate*)root).sections.count);
                    }
                }
                [scenes addObject:state];
            }
            NSDictionary* state = @{
                @"protectedDataAvailable": @(app.protectedDataAvailable),
                @"databaseStartupState": [(NSObject*)app.delegate valueForKey:@"databaseStartupState"],
                @"mainViewController": main ? NSStringFromClass([main class]) : @"",
                @"mainViewControllerIdentity": main ? [NSString stringWithFormat:@"%p", main] : @"",
                @"scenes": scenes,
            };
            [[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:report atomically:YES];
        }];
    });
}
@end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--normal", action="store_true", help="Observe without overriding the API")
    parser.add_argument("--expect-failed", action="store_true", help="Require database failure for a prepared invalid fixture")
    args = parser.parse_args()
    output = args.evidence.resolve()
    output.mkdir(parents=True, exist_ok=True)
    commands = []

    def run(command, *, env=None, check=True):
        commands.append(shlex.join(command))
        result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (output / "commands.log").write_text("\n".join(commands) + "\n")
        with (output / "tool-output.log").open("a") as log:
            log.write(shlex.join(command) + "\n" + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout)
        return result.stdout.strip()

    devices = json.loads(run(["xcrun", "simctl", "list", "devices", "--json"]))
    device = next(d for group in devices["devices"].values() for d in group if d["udid"] == args.udid)
    assert device["state"] == "Booted", "Boot the explicitly selected disposable simulator first"
    (output / "environment.json").write_text(json.dumps({
        "device": device, "app": str(args.app.resolve()), "lockedAPIInjected": not args.normal,
        "command": shlex.join([sys.executable, *sys.argv]),
        "limitation": "API injection; no hardware data protection is simulated",
    }, indent=2))
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    source = output / "StartupProbe.m"
    library = output / "StartupProbe.dylib"
    source.write_text(HOOK)
    run(["xcrun", "--sdk", "iphonesimulator", "clang", "-dynamiclib", "-fobjc-arc",
         "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
         "-framework", "UIKit", "-framework", "CarPlay", str(source), "-o", str(library)])
    run(["codesign", "-s", "-", str(library)])
    run(["xcrun", "simctl", "terminate", args.udid, BUNDLE], check=False)
    run(["xcrun", "simctl", "install", args.udid, str(args.app.resolve())])
    container = Path(run(["xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"]))
    documents = container / "Documents"
    documents.mkdir(exist_ok=True)
    probe = documents / "startup-probe.json"
    unlock = documents / "startup-probe-unlock"
    probe.unlink(missing_ok=True)
    unlock.unlink(missing_ok=True)
    env = dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library))
    if not args.normal:
        env["SIMCTL_CHILD_IC_PROBE_LOCKED"] = "1"
    run(["xcrun", "simctl", "launch", args.udid, BUNDLE], env=env)

    def observe(name, predicate, timeout=20):
        deadline = time.monotonic() + timeout
        state = None
        while time.monotonic() < deadline:
            if probe.exists():
                state = json.loads(probe.read_text())
                if predicate(state):
                    break
            time.sleep(0.2)
        assert state is not None, "The runtime probe produced no observations"
        (output / f"{name}.json").write_text(json.dumps(state, indent=2))
        run(["xcrun", "simctl", "io", args.udid, "screenshot", str(output / f"{name}.png")])
        return state

    expected = 3 if args.expect_failed else 2
    state = observe("startup", lambda s: s["databaseStartupState"] == expected)
    if not args.normal:
        assert state["protectedDataAvailable"] is False, "Locked-device input was not applied"
    passed = state["databaseStartupState"] == expected
    if not args.expect_failed:
        passed = passed and bool(state["mainViewController"])
    if not args.normal and not args.expect_failed:
        unlock.touch()
        recovered = observe("after-unlock", lambda s: s["protectedDataAvailable"] and s["databaseStartupState"] == 2)
        assert recovered["databaseStartupState"] == 2, "Unlock did not recover startup"
        if passed:
            assert state["mainViewControllerIdentity"] == recovered["mainViewControllerIdentity"], "Unlock restarted the app UI"
    logs = documents / "Logs"
    if logs.exists():
        shutil.copytree(logs, output / "Logs", dirs_exist_ok=True)
    result = {"passed": bool(passed), "expectedDatabaseState": expected, "observed": state}
    (output / "result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
