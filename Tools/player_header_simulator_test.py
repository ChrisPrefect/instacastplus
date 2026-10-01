#!/usr/bin/env python3
"""Exercise the production player header with real Core Data episodes and local audio.

The injected driver calls the same presentation/actions as the app and samples
rendered UILabel geometry. It does not replace app methods or animation behavior.
Use a dedicated simulator named 'Instacast Player Header Regression'. Evidence
includes commands, fixtures, screenshots, presentation-layer samples and checks.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import uuid
import wave

BUNDLE = 'com.iteconomy.instacastplus'
DRIVER = r'''
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <QuartzCore/QuartzCore.h>

@interface NSObject (HeaderProbeCalls)
+ (id)sharedDatabaseManager;
+ (id)sharedAudioSession;
+ (id)playbackViewControllerWithEpisode:(id)episode;
- (void)presentFromParentViewController:(UIViewController*)parent autostart:(BOOL)autostart completion:(void(^)(void))completion;
- (void)playEpisode:(id)episode queueUpCurrent:(BOOL)queue at:(double)position autostart:(BOOL)autostart;
- (void)save;
@end

static NSString* directory;
static NSArray* episodes;
static UINavigationController* player;

static UIViewController* root(void) {
    for (UIWindowScene* scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* window in scene.windows) if (window.isKeyWindow) return window.rootViewController;
    }
    return nil;
}

static NSArray* rect(CGRect value) {
    return @[@(value.origin.x), @(value.origin.y), @(value.size.width), @(value.size.height)];
}

static void labels(UIView* view, NSMutableArray* result) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel* label = (UILabel*)view;
        CALayer* layer = label.layer.presentationLayer ?: label.layer;
        [result addObject:@{@"text": label.text ?: @"", @"lines": @(label.numberOfLines),
            @"breakMode": @(label.lineBreakMode), @"shrinks": @(label.adjustsFontSizeToFitWidth),
            @"fontSize": @(label.font.pointSize), @"alignment": @(label.textAlignment),
            @"frame": rect([label convertRect:label.bounds toView:nil]),
            @"localX": @(layer.frame.origin.x), @"width": @(label.bounds.size.width),
            @"parentWidth": @(label.superview.bounds.size.width),
            @"accessible": @(label.isAccessibilityElement), @"accessibilityLabel": label.accessibilityLabel ?: @""}];
    }
    for (UIView* child in view.subviews) labels(child, result);
}

static NSDictionary* snapshot(void) {
    UIView* header = player.viewControllers.firstObject.navigationItem.titleView;
    NSMutableArray* found = [NSMutableArray array];
    if (header) labels(header, found);
    return @{@"time": @(CACurrentMediaTime()), @"labels": found,
        @"headerFrame": rect([header convertRect:header.bounds toView:nil]),
        @"headerAccessibilityLabel": header.accessibilityLabel ?: @"",
        @"windowWidth": @(player.view.window.bounds.size.width),
        @"reduceMotion": @(UIAccessibilityIsReduceMotionEnabled()),
        @"active": @(UIApplication.sharedApplication.applicationState == UIApplicationStateActive),
        @"visible": @(root().presentedViewController == player && !player.isBeingPresented)};
}

@interface ICPlayerHeaderProbe : NSObject @end
@implementation ICPlayerHeaderProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"PlayerHeaderProbe"];
        __block NSString* lastID;
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer* timer) {
            if (!root() || ![(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSDictionary* request = [NSJSONSerialization JSONObjectWithData:
                [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]] ?: NSData.data options:0 error:nil];
            if (!request || [lastID isEqual:request[@"id"]]) return;
            lastID = request[@"id"];
            if (!episodes) {
                id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                NSManagedObjectContext* context = [database valueForKey:@"objectContext"];
                [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                NSMutableArray* fixtures = [NSMutableArray array];
                for (NSDictionary* fixture in request[@"fixtures"]) {
                    id feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:fixture[@"podcast"] forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:[@"https://example.invalid/" stringByAppendingString:NSUUID.UUID.UUIDString]] forKey:@"sourceURL"];
                    [feed setValue:@YES forKey:@"subscribed"];
                    id episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"objectHash"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:fixture[@"episode"] forKey:@"title"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@180 forKey:@"duration"];
                    [episode setValue:feed forKey:@"feed"];
                    id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    [fixtures addObject:episode];
                }
                [database save];
                episodes = fixtures;
            }
            NSString* action = request[@"action"];
            if ([action isEqual:@"open"]) {
                player = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:episodes[[request[@"index"] integerValue]]];
                [(id)player presentFromParentViewController:root() autostart:NO completion:nil];
            } else if ([action isEqual:@"switch"]) {
                [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:episodes[[request[@"index"] integerValue]] queueUpCurrent:NO at:0 autostart:NO];
            } else if ([action isEqual:@"close"]) {
                UIBarButtonItem* close = player.viewControllers.firstObject.navigationItem.leftBarButtonItem;
                [UIApplication.sharedApplication sendAction:close.action to:close.target from:close forEvent:nil];
            } else if ([action isEqual:@"notes"]) {
                UIBarButtonItem* notes = player.viewControllers.firstObject.navigationItem.rightBarButtonItem;
                [UIApplication.sharedApplication sendAction:notes.action to:notes.target from:notes forEvent:nil];
            } else if ([action isEqual:@"back"]) {
                [player popViewControllerAnimated:YES];
            }
            NSDictionary* reply = @{@"id": lastID, @"state": snapshot()};
            [[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--udid', required=True)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--reduce-motion', action='store_true', help='Verify static titles with the simulator Reduce Motion preference already enabled')
    args = parser.parse_args()
    out = args.evidence.resolve()
    out.mkdir(parents=True, exist_ok=True)

    def run(command, check=True, env=None):
        result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env)
        with (out / 'commands.log').open('a') as log:
            log.write(shlex.join(command) + '\n' + result.stdout)
        if check and result.returncode:
            raise RuntimeError(result.stdout)
        return result.stdout.strip()

    devices = json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j']))['devices']
    runtime, device = next((r, d) for r, group in devices.items() for d in group if d['udid'] == args.udid)
    assert device['name'] == 'Instacast Player Header Regression' and device['state'] == 'Booted'
    fixtures = [dict(podcast='Bits und so Plus', episode='1012 (Mserve)'),
                dict(podcast='Ein sehr langer Podcastname mit vielen Worten für die einzeilige Darstellung',
                     episode='1012 – Ein ausführlicher Episodentitel über Podcasts und gute Bedienbarkeit')]
    (out / 'environment.json').write_text(json.dumps(dict(
        command=shlex.join([sys.executable, *sys.argv]), device=device, runtime=runtime,
        app=str(args.app.resolve()), fixtures=fixtures, reduceMotion=args.reduce_motion,
        driver='Production presentation and button actions, real Core Data and local WAV; no method replacements',
        expected='Two centered single lines; podcast truncates; long episode waits 2 s, scrolls at 24 pt/s, holds 1 s, jumps home; short title stationary',
        binarySHA256={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in args.app.glob('InstacastPlus*') if p.is_file()}), indent=2))
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'])
    source, library = out / 'HeaderProbe.m', out / 'HeaderProbe.dylib'
    source.write_text(DRIVER)
    run(['xcrun', 'clang', '-dynamiclib', '-fobjc-arc', '-target', 'arm64-apple-ios17.0-simulator',
         '-isysroot', sdk, '-framework', 'UIKit', '-framework', 'CoreData', '-framework', 'QuartzCore', str(source), '-o', str(library)])
    run(['codesign', '-s', '-', str(library)])
    run(['xcrun', 'simctl', 'terminate', args.udid, BUNDLE], check=False)
    run(['xcrun', 'simctl', 'install', args.udid, str(args.app.resolve())])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.udid, BUNDLE, 'data']))
    directory = container / 'Documents/PlayerHeaderProbe'
    directory.mkdir(parents=True, exist_ok=True)
    for name in ['command.json', 'reply.json']:
        (directory / name).unlink(missing_ok=True)
    with wave.open(str(directory / 'fixture.wav'), 'wb') as wav:
        wav.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        wav.writeframes(b'\0\0' * 8000 * 180)
    shutil.copy2(directory / 'fixture.wav', out / 'fixture.wav')
    run(['xcrun', 'simctl', 'launch', f'--stdout={out / "stdout.log"}', f'--stderr={out / "stderr.log"}', args.udid, BUNDLE],
        env=dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(library)))

    def command(action='status', **parameters):
        request = dict(id=str(uuid.uuid4()), action=action, fixtures=fixtures, **parameters)
        temporary = directory / 'command.tmp'
        temporary.write_text(json.dumps(request))
        temporary.replace(directory / 'command.json')
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if (directory / 'reply.json').exists():
                reply = json.loads((directory / 'reply.json').read_text())
                if reply['id'] == request['id']:
                    with (out / 'observations.jsonl').open('a') as log:
                        log.write(json.dumps(dict(request=request, reply=reply)) + '\n')
                    return reply['state']
            time.sleep(0.05)
        raise RuntimeError(f'No response for {action}')

    def screenshot(name):
        run(['xcrun', 'simctl', 'io', args.udid, 'screenshot', str(out / f'{name}.png')])

    def title(state, text):
        matches = [label for label in state['labels'] if label['text'] == text]
        return matches[-1] if matches else None

    def open_player(index):
        command('open', index=index)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            state = command()
            if state['visible'] and state['active']:
                return state
            time.sleep(0.1)
        raise RuntimeError('Player did not appear')

    checks = {}
    try:
        state = open_player(0)
        screenshot('short-title')
        feed, episode = (title(state, fixtures[0][key]) for key in ['podcast', 'episode'])
        checks['both_titles_visible'] = feed is not None and episode is not None
        if not checks['both_titles_visible']:
            return 1
        checks['one_line_each_in_order'] = feed['lines'] == episode['lines'] == 1 and feed['frame'][1] < episode['frame'][1]
        checks['header_centered'] = abs(state['headerFrame'][0] + state['headerFrame'][2] / 2 - state['windowWidth'] / 2) < 2
        x = episode['localX']
        time.sleep(3)
        checks['short_title_stationary'] = abs(title(command(), fixtures[0]['episode'])['localX'] - x) < 0.5
        command('switch', index=1)
        time.sleep(0.3)
        start = command()
        feed = title(start, fixtures[1]['podcast'])
        checks['podcast_truncates_without_shrinking'] = feed is not None and feed['lines'] == 1 and feed['breakMode'] == 4 and not feed['shrinks']
        checks['system_motion_preference'] = start['reduceMotion'] == args.reduce_motion
        checks['full_titles_accessible'] = all(text in start['headerAccessibilityLabel'] for text in fixtures[1].values())
        if args.reduce_motion:
            initial = title(start, fixtures[1]['episode'])
            time.sleep(5)
            later = title(command(), fixtures[1]['episode'])
            checks['reduced_motion_stays_static_and_truncates'] = initial is not None and later is not None and abs(later['localX'] - initial['localX']) < 0.5 and later['breakMode'] == 4
            screenshot('reduced-motion')
            return 0 if all(checks.values()) else 1
        samples = []
        for index in range(105):
            state = command()
            label = title(state, fixtures[1]['episode'])
            if label:
                samples.append(dict(t=state['time'] - start['time'], x=label['localX'], width=label['width'], viewport=label['parentWidth']))
            if index in (0, 18, 70):
                screenshot(f'long-title-{index}')
            time.sleep(0.2)
        (out / 'motion.json').write_text(json.dumps(samples, indent=2))
        checks['episode_switch_updates_title'] = bool(samples)
        if samples:
            home = samples[0]['x']
            checks['initial_pause'] = all(abs(s['x'] - home) < 1 for s in samples if s['t'] < 1.3)
            moving = [(a, b) for a, b in zip(samples, samples[1:]) if b['x'] < a['x'] - 2]
            speeds = [(a['x'] - b['x']) / (b['t'] - a['t']) for a, b in moving]
            checks['slow_constant_scroll'] = len(speeds) > 5 and all(21 < s < 27 for s in sorted(speeds)[2:-2])
            end = min(s['x'] for s in samples)
            checks['full_title_revealed'] = abs(end + samples[0]['width'] - samples[0]['viewport']) < 2
            end_samples = [s for s in samples if abs(s['x'] - end) < 0.5]
            checks['end_pause'] = bool(end_samples) and end_samples[-1]['t'] - end_samples[0]['t'] >= 0.7
            checks['jumps_back_to_start'] = any(b['x'] - a['x'] > 100 and abs(b['x'] - home) < 1 for a, b in zip(samples, samples[1:]))
        command('notes')
        time.sleep(0.7)
        command('back')
        time.sleep(0.7)
        returned = title(command(), fixtures[1]['episode'])
        time.sleep(3)
        later = title(command(), fixtures[1]['episode'])
        checks['scroll_restarts_after_show_notes'] = returned is not None and later is not None and later['localX'] < returned['localX'] - 10
        command('close')
        time.sleep(1)
        reopened = open_player(0)
        checks['reopen_short_title_resets_scroll'] = title(reopened, fixtures[0]['episode']) is not None
        screenshot('reopened')
        return 0 if all(checks.values()) else 1
    finally:
        (out / 'result.json').write_text(json.dumps(checks, indent=2))
        print(json.dumps(checks, indent=2))
        if (container / 'Documents/Logs').exists():
            shutil.copytree(container / 'Documents/Logs', out / 'Logs', dirs_exist_ok=True)


if __name__ == '__main__':
    sys.exit(main())
