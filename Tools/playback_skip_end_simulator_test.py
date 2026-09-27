#!/usr/bin/env python3
"""Real-app skip-end/replay regression with AVPlayer, Core Data and player UI.

Uses a dedicated simulator and a generated 24-second WAV. The injected driver only
creates the fixture, opens the production player UI and records state; no playback
method is replaced. Retains commands, screenshots, diagnostics and observations.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import subprocess
import sys
import time
import wave

BUNDLE = "com.iteconomy.instacastplus"
DRIVER = r'''
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <AVFoundation/AVFoundation.h>

@interface NSObject (SkipEndDriverCalls)
+ (id)sharedDatabaseManager;
+ (id)playbackManager;
+ (id)playbackViewControllerWithEpisode:(id)episode;
- (void)presentFromParentViewController:(UIViewController*)parent autostart:(BOOL)autostart completion:(void(^)(void))completion;
- (void)save;
- (void)setString:(NSString*)value forKey:(NSString*)key;
@end

static NSString* documents;
static id episode;
static id database;
static NSString* hash;
static NSMutableArray* observations;
static AVPlayerItem* observedItem;
static NSInteger mediaEndCount;
static NSInteger completionCount;
static double mediaEndClock;

static UIViewController* rootViewController(void) {
    for (UIWindowScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            for (UIWindow* window in scene.windows) if (window.isKeyWindow) return window.rootViewController;
        }
    }
    return nil;
}

static NSDictionary* snapshot(NSString* phase) {
    id manager = [NSClassFromString(@"PlaybackManager") playbackManager];
    AVPlayer* player = [manager valueForKey:@"player"];
    double clock = player ? CMTimeGetSeconds(player.currentTime) : 0;
    return @{@"phase": phase, @"clock": @(isfinite(clock) ? clock : -1),
        @"rate": @(player.rate), @"position": [episode valueForKey:@"position"],
        @"duration": [episode valueForKey:@"duration"],
        @"consumed": [episode valueForKey:@"consumed"],
        @"timeLeft": [episode valueForKey:@"timeLeft"],
        @"episodeHash": hash,
        @"databasePath": [[database valueForKey:@"databaseURL"] path],
        @"mediaEndCount": @(mediaEndCount), @"completionCount": @(completionCount),
        @"mediaEndClock": @(mediaEndClock),
        @"hasPlayer": @(player != nil),
        @"playerPresented": @(rootViewController().presentedViewController != nil),
        @"temporaryPosition": [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"TemporaryPlaybackPositions"] objectForKey:hash] ?: NSNull.null};
}

static void record(NSString* phase) {
    [observations addObject:snapshot(phase)];
    [[NSJSONSerialization dataWithJSONObject:observations options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[documents stringByAppendingPathComponent:@"skip-end-observations.json"] atomically:YES];
}

static void openPlayer(void) {
    id controller = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:episode];
    [controller presentFromParentViewController:rootViewController() autostart:YES completion:nil];
}

@interface ICSkipEndDriver : NSObject @end
@implementation ICSkipEndDriver
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        observations = [NSMutableArray array];
        for (NSString* name in @[@"MPPlaybackManagerDidEndNotification", @"CacheManagerWillCommitCacheFileDeletionNotification"]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification* note) {
                NSLog(@"SkipEndTrace %@ %@ %@", note.name, note.userInfo, NSThread.callStackSymbols);
            }];
        }
        [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:nil queue:nil usingBlock:^(NSNotification* note) {
            if (note.object == observedItem) {
                mediaEndCount++;
                mediaEndClock = CMTimeGetSeconds(observedItem.currentTime);
            }
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:@"MPPlaybackManagerEpisodeDidFinishNotification" object:nil queue:nil usingBlock:^(NSNotification* note) {
            if ([note.object valueForKey:@"playingEpisode"] == episode) completionCount++;
        }];
        __block NSInteger stage = 0;
        __block NSDate* stageStart;
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer* timer) {
            if (stage == 0) {
                id delegate = UIApplication.sharedApplication.delegate;
                if (!delegate || ![delegate valueForKey:@"mainViewController"]) return;
                if (!rootViewController() || rootViewController().presentedViewController) return;
                database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                NSManagedObjectContext* context = [database valueForKey:@"objectContext"];
                if (!context) return;
                NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
                [defaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                [defaults setBool:NO forKey:@"IntelligentSleepTimerAlwaysActive"];
                [defaults setBool:NO forKey:@"ScreenTimerAlwaysActive"];
                [defaults setDouble:8 forKey:@"PlayerAutoSkipEndPeriod"];
                [defaults setDouble:2 forKey:@"PlayerAutoSkipStartPeriod"];
                id feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                [feed setValue:@"Skip End Regression" forKey:@"title"];
                [feed setValue:[NSURL URLWithString:@"https://example.invalid/skip-end.xml"] forKey:@"sourceURL"];
                [feed setValue:@YES forKey:@"subscribed"];
                episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                hash = NSUUID.UUID.UUIDString;
                [episode setValue:hash forKey:@"objectHash"];
                [episode setValue:hash forKey:@"guid"];
                [episode setValue:@"Skip End: 24 seconds, skip last 8" forKey:@"title"];
                [episode setValue:NSDate.date forKey:@"pubDate"];
                [episode setValue:@24 forKey:@"duration"];
                [episode setValue:@NO forKey:@"consumed"];
                [episode setValue:feed forKey:@"feed"];
                if (getenv("IC_SKIP_CHAPTER")) {
                    [defaults setDouble:0 forKey:@"PlayerAutoSkipEndPeriod"];
                    [feed setString:@"Outro" forKey:[[feed valueForKey:@"uid"] stringByAppendingString:@"_auto_skip_chapter_name"]];
                    for (NSInteger index = 0; index < 2; index++) {
                        id chapter = [NSEntityDescription insertNewObjectForEntityForName:@"Chapter" inManagedObjectContext:context];
                        [chapter setValue:episode forKey:@"episode"];
                        [chapter setValue:@(index) forKey:@"index"];
                        [chapter setValue:index ? @"Outro" : @"Main" forKey:@"title"];
                        [chapter setValue:index ? @16 : @0 forKey:@"timecode"];
                        [chapter setValue:index ? @8 : @16 forKey:@"duration"];
                    }
                }
                if (getenv("IC_SKIP_COMPLETED")) {
                    [episode setValue:@YES forKey:@"consumed"];
                    [episode setValue:@24 forKey:@"position"];
                    [defaults setObject:@{hash: @16} forKey:@"TemporaryPlaybackPositions"];
                }
                id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                [medium setValue:episode forKey:@"episode"];
                [medium setValue:[NSURL fileURLWithPath:[documents stringByAppendingPathComponent:@"skip-end.wav"]] forKey:@"fileURL"];
                [medium setValue:@"audio/wav" forKey:@"mimeType"];
                [database save];
                record(@"fixture");
                openPlayer();
                stage = 1;
                stageStart = NSDate.date;
            } else if (stage == 1) {
                AVPlayer* player = [[NSClassFromString(@"PlaybackManager") playbackManager] valueForKey:@"player"];
                if (player.currentItem) observedItem = player.currentItem;
                NSDictionary* state = snapshot(@"playing");
                if (-stageStart.timeIntervalSinceNow > 4 && observations.count == 1) record(@"playing");
                if (observations.count > 1 && [state[@"consumed"] boolValue] && ![state[@"hasPlayer"] boolValue]) {
                    record(@"finished");
                    stage = 2;
                } else if (-stageStart.timeIntervalSinceNow > 45) {
                    record(@"finish-timeout");
                    [timer invalidate];
                }
            } else if (stage == 2) {
                // The runner takes a screenshot before requesting another user play.
                if (![[NSFileManager defaultManager] fileExistsAtPath:[documents stringByAppendingPathComponent:@"skip-end-replay"]]) return;
                // The episode list becomes available after the production player dismisses itself.
                if (rootViewController().presentedViewController) return;
                record(@"ready-to-replay");
                openPlayer();
                stageStart = NSDate.date;
                stage = 3;
            } else if (stage == 3) {
                AVPlayer* player = [[NSClassFromString(@"PlaybackManager") playbackManager] valueForKey:@"player"];
                if (player.currentItem) observedItem = player.currentItem;
                if (-stageStart.timeIntervalSinceNow > 4) {
                    record(@"replayed");
                    stage = 4;
                }
            } else if (stage == 4) {
                if (![snapshot(@"replay-finished")[@"hasPlayer"] boolValue]) {
                    record(@"replay-finished");
                    [timer invalidate];
                } else if (-stageStart.timeIntervalSinceNow > 45) {
                    record(@"replay-finish-timeout");
                    [timer invalidate];
                }
            }
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
    parser.add_argument("--completed", action="store_true", help="Start with the completed position and stale resume left by older builds")
    parser.add_argument("--chapter", action="store_true", help="Finish by skipping an Outro chapter instead of an end period")
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
    assert device["state"] == "Booted"
    assert device["name"] == "Instacast Skip End Regression", "Use a dedicated simulator for the generated fixture"
    (output / "environment.json").write_text(json.dumps({
        "device": device, "app": str(args.app.resolve()),
        "command": shlex.join([sys.executable, *sys.argv]),
        "fixture": "24-second mono 8 kHz PCM WAV; start skip 2 s; end skip 8 s",
        "previouslyCompleted": args.completed,
        "skipFinalChapter": args.chapter,
        "expected": "AVPlayer reaches 24 s; normal completion clears both saved positions, marks heard; replay starts at 2 s and skips to the end again",
        "driver": "Calls the production player presentation used by episode selection; playback implementation is unchanged",
    }, indent=2))
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    source, library = output / "SkipEndDriver.m", output / "SkipEndDriver.dylib"
    source.write_text(DRIVER)
    run(["xcrun", "--sdk", "iphonesimulator", "clang", "-dynamiclib", "-fobjc-arc",
         "-target", "arm64-apple-ios17.0-simulator", "-isysroot", sdk,
         "-framework", "UIKit", "-framework", "CoreData", "-framework", "AVFoundation", "-framework", "CoreMedia",
         str(source), "-o", str(library)])
    run(["codesign", "-s", "-", str(library)])
    run(["xcrun", "simctl", "terminate", args.udid, BUNDLE], check=False)
    run(["xcrun", "simctl", "install", args.udid, str(args.app.resolve())])
    container = Path(run(["xcrun", "simctl", "get_app_container", args.udid, BUNDLE, "data"]))
    documents = container / "Documents"
    documents.mkdir(exist_ok=True)
    for name in ["skip-end-observations.json", "skip-end-replay"]:
        (documents / name).unlink(missing_ok=True)
    with wave.open(str(documents / "skip-end.wav"), "wb") as wav:
        wav.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
        wav.writeframes(b"\0\0" * 8000 * 24)
    shutil.copy2(documents / "skip-end.wav", output / "fixture.wav")
    env = dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library))
    if args.completed:
        env["SIMCTL_CHILD_IC_SKIP_COMPLETED"] = "1"
    if args.chapter:
        env["SIMCTL_CHILD_IC_SKIP_CHAPTER"] = "1"
    run(["xcrun", "simctl", "launch", f"--stdout={output / 'stdout.log'}",
         f"--stderr={output / 'stderr.log'}", args.udid, BUNDLE], env=env)
    observations = documents / "skip-end-observations.json"

    def observe(phase, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if observations.exists():
                states = json.loads(observations.read_text())
                match = next((s for s in states if s["phase"] == phase), None)
                if match:
                    shutil.copy2(observations, output / "observations.json")
                    run(["xcrun", "simctl", "io", args.udid, "screenshot", str(output / f"{phase}.png")])
                    return match
            time.sleep(0.2)
        raise RuntimeError(f"No {phase} observation; inspect app diagnostics")

    try:
        playing = observe("playing", 35)
        finished = observe("finished", 35)
        query = "SELECT ZPOSITION, ZCONSUMED FROM ZEPISODE WHERE ZOBJECTHASH = ?"
        with sqlite3.connect(f"file:{finished['databasePath']}?mode=ro", uri=True) as connection:
            persisted = connection.execute(query, (finished["episodeHash"],)).fetchone()
        (output / "persisted-completion.json").write_text(json.dumps({
            "query": query, "episodeHash": finished["episodeHash"], "positionAndConsumed": persisted,
        }, indent=2))
        (documents / "skip-end-replay").touch()
        replayed = observe("replayed", 20)
        replay_finished = observe("replay-finished", 35)
        checks = {
            "initial_play_runs_from_start_skip": bool(playing["hasPlayer"] and playing["rate"] > 0 and 2 <= playing["clock"] < 10),
            "player_reached_media_end": finished["mediaEndCount"] == 1 and abs(finished["mediaEndClock"] - 24) < 0.01,
            "normal_completion_once": finished["completionCount"] == 1,
            "saved_position_cleared": finished["position"] == 0 and persisted == (0, 1),
            "fully_heard": bool(finished["consumed"]),
            "temporary_resume_cleared": finished["temporaryPosition"] is None,
            "replay_runs_from_start_skip": bool(replayed["hasPlayer"] and replayed["rate"] > 0 and 2 <= replayed["clock"] < 10),
            "replay_also_reaches_media_end": replay_finished["mediaEndCount"] == 2 and abs(replay_finished["mediaEndClock"] - 24) < 0.01,
            "replay_completes_once_and_clears_positions": replay_finished["completionCount"] == 2 and replay_finished["position"] == 0 and replay_finished["temporaryPosition"] is None and bool(replay_finished["consumed"]),
        }
        (output / "result.json").write_text(json.dumps(checks, indent=2))
        print(json.dumps(checks, indent=2))
        return 0 if all(checks.values()) else 1
    finally:
        if observations.exists():
            shutil.copy2(observations, output / "observations.json")
        if (documents / "Logs").exists():
            shutil.copytree(documents / "Logs", output / "Logs", dirs_exist_ok=True)


if __name__ == "__main__":
    sys.exit(main())
