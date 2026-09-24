#!/usr/bin/env python3
"""Execute the widget producer and exporter delivery methods with controlled queues.

Foundation performs the real JSON and filesystem work. Only the app-group URL,
dispatch scheduling, and playback handler are substituted, so foreground/Darwin
interleavings can be reproduced without running an iOS widget extension.
"""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
producer = (ROOT / "InstacastWidgets/Intents/WidgetControlIntents.swift").read_text()
exporter = (ROOT / "Classes/WidgetDataExporter.m").read_text()


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


producer_enum = block(producer, "enum PendingWidgetActionStore")
producer_enum, substitutions = re.subn(
    r"FileManager\.default\.containerURL\(\s*"
    r"forSecurityApplicationGroupIdentifier: ICWidgetConstants\.appGroupID\s*\)",
    "Optional(URL(fileURLWithPath: CommandLine.arguments[1]))",
    producer_enum,
)
assert substitutions == 1, "Only substitute the app-group entitlement lookup."
swift = "import Foundation\n" + producer_enum + """
do {
let count = CommandLine.arguments.count > 5 ? Int(CommandLine.arguments[5])! : 1
for _ in 0..<count {
try PendingWidgetActionStore.enqueue(
    action: CommandLine.arguments[2],
    chapterIndex: Int(CommandLine.arguments[3]),
    chapterTimelineIdentifier: CommandLine.arguments[4]
)
}
} catch {
    print(error)
    exit(1)
}
"""

method_start = exporter.index("- (void)_widgetControlAction:")
method_end = exporter.index("- (void)_handleWidgetAction:", method_start)
methods = exporter[method_start:method_end]
constants = "\n".join(re.findall(
    r"static NSString\* const kPendingAction\w+\s*=\s*@\"[^\"]+\";", exporter
))

harness = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
static NSMutableArray *workerBlocks, *mainBlocks;
static NSUInteger failures = 0;
static void testDispatch(dispatch_queue_t queue, dispatch_block_t block) {
    [(queue == dispatch_get_main_queue() ? mainBlocks : workerBlocks) addObject:[block copy]];
}
#define dispatch_async(queue, ...) testDispatch(queue, __VA_ARGS__)
#define DebugLog(...) ((void)0)
#define ErrLog(...) ((void)0)
CONSTANTS
@interface Exporter : NSObject
@property(nonatomic,strong) NSURL *containerURL;
@property(nonatomic,strong) dispatch_queue_t pendingWidgetActionQueue;
@property(nonatomic,strong) NSMutableArray *handled;
- (void)_widgetControlAction:(NSNotification *)note;
- (void)_consumePendingWidgetActionIfNeeded;
- (void)_consumePendingWidgetActionNotification:(NSNotification *)note;
@end
@implementation Exporter
- (void)_handleWidgetAction:(NSString *)action chapterIndex:(NSNumber *)index chapterTimelineIdentifier:(NSString *)timeline {
    [self.handled addObject:@{@"action":action, @"index":index ?: @(-1), @"timeline":timeline ?: @""}];
}
METHODS
@end
static void drain(NSMutableArray *queue) {
    while (queue.count) {
        dispatch_block_t work = queue.firstObject;
        [queue removeObjectAtIndex:0];
        work();
    }
}
static void settle(void) {
    NSUInteger rounds = 0;
    while (mainBlocks.count || workerBlocks.count) {
        if (++rounds > 1000) { fprintf(stderr, "Dispatch failed to settle\n"); exit(2); }
        drain(mainBlocks);
        drain(workerBlocks);
    }
}
static void require(BOOL pass, NSString *message) {
    if (!pass) { failures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}
static void enqueue(NSString *binary, Exporter *exporter, NSString *action, NSInteger chapter) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:binary];
    task.arguments = @[exporter.containerURL.path, action, [@(chapter) stringValue], @"timeline-A"];
    [task launch]; [task waitUntilExit];
    require(task.terminationStatus == 0, @"Real Swift producer must succeed");
}
static Exporter *fresh(NSURL *root, NSString *name) {
    Exporter *e = [Exporter new];
    e.containerURL = [root URLByAppendingPathComponent:name isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:e.containerURL withIntermediateDirectories:YES attributes:nil error:nil];
    e.pendingWidgetActionQueue = dispatch_queue_create("test.widget-actions", DISPATCH_QUEUE_SERIAL);
    e.handled = [NSMutableArray array];
    return e;
}
static NSArray *actions(Exporter *e) { return [e.handled valueForKey:@"action"]; }
int main(int argc, const char **argv) { @autoreleasepool {
    workerBlocks = [NSMutableArray array]; mainBlocks = [NSMutableArray array];
    NSURL *root = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSString *binary = [NSString stringWithUTF8String:argv[2]];
    NSNotification *notice = [NSNotification notificationWithName:@"WidgetControlActionNotification" object:nil userInfo:@{@"action":@"playpause"}];

    Exporter *lifecycle = fresh(root, @"lifecycle");
    enqueue(binary, lifecycle, @"playpause", 0);
    [lifecycle _consumePendingWidgetActionNotification:notice];
    [lifecycle _consumePendingWidgetActionNotification:notice];
    settle();
    require([actions(lifecycle) isEqual:@[@"playpause"]], @"One pending tap must execute once across both foreground notifications");

    Exporter *darwin = fresh(root, @"darwin");
    enqueue(binary, darwin, @"playpause", 0);
    [darwin _widgetControlAction:notice];
    [darwin _consumePendingWidgetActionNotification:notice];
    settle();
    require([actions(darwin) isEqual:@[@"playpause"]], @"Darwin and foreground must consume the same tap once");
    [darwin _widgetControlAction:notice];
    settle();
    require([actions(darwin) isEqual:@[@"playpause"]], @"A delayed duplicate notification must not replay an already consumed tap");

    Exporter *between = fresh(root, @"between");
    enqueue(binary, between, @"skipforward", 0);
    [between _consumePendingWidgetActionIfNeeded];
    drain(workerBlocks);
    require(mainBlocks.count > 0 && between.handled.count == 0, @"Suspend delivery after the real file read and before playback");
    enqueue(binary, between, @"skipbackward", 0);
    settle();
    [between _consumePendingWidgetActionIfNeeded];
    settle();
    require([actions(between) isEqual:@[@"skipforward", @"skipbackward"]], @"A new tap written while the previous callback is pending must survive");

    Exporter *repeated = fresh(root, @"repeated");
    enqueue(binary, repeated, @"skipforward", 0);
    enqueue(binary, repeated, @"skipforward", 0);
    [repeated _consumePendingWidgetActionIfNeeded];
    settle();
    require([actions(repeated) isEqual:@[@"skipforward", @"skipforward"]], @"Two genuine identical taps before consumption must both execute");

    Exporter *burst = fresh(root, @"burst");
    NSTask *burstTask = [NSTask new];
    burstTask.executableURL = [NSURL fileURLWithPath:binary];
    burstTask.arguments = @[burst.containerURL.path, @"skipforward", @"0", @"timeline-A", @"65"];
    [burstTask launch]; [burstTask waitUntilExit];
    require(burstTask.terminationStatus == 0, @"Producer burst must persist successfully");
    [burst _consumePendingWidgetActionIfNeeded];
    settle();
    require(burst.handled.count == 65, @"A burst must continue across bounded consumption batches without another notification");

    Exporter *chapters = fresh(root, @"chapters");
    enqueue(binary, chapters, @"skipchapter", 1);
    enqueue(binary, chapters, @"skipchapter", 3);
    [chapters _widgetControlAction:notice];
    settle();
    require([actions(chapters) isEqual:@[@"skipchapter", @"skipchapter"]]
        && [[chapters.handled valueForKey:@"index"] isEqual:@[@1, @3]]
        && [[chapters.handled valueForKey:@"timeline"] isEqual:@[@"timeline-A", @"timeline-A"]],
        @"Chapter index and timeline must remain bound to their own ordered action payload");

    Exporter *legacy = fresh(root, @"legacy");
    NSData *payload = [NSJSONSerialization dataWithJSONObject:@{@"action":@"playpause", @"timestamp":@0} options:0 error:nil];
    [payload writeToURL:[legacy.containerURL URLByAppendingPathComponent:@"widget_pending_action.json"] atomically:YES];
    [legacy _widgetControlAction:notice];
    [legacy _consumePendingWidgetActionNotification:notice];
    settle();
    require([actions(legacy) isEqual:@[@"playpause"]], @"The pre-upgrade single action must join the same once-only consumption path");
    printf("Widget delivery runtime checks: %lu failures\n", (unsigned long)failures);
    return failures ? 1 : 0;
} }
'''.replace("CONSTANTS", constants).replace("METHODS", methods)

with tempfile.TemporaryDirectory(prefix="widget-action-regression-") as temporary:
    directory = Path(temporary)
    (directory / "producer.swift").write_text(swift)
    (directory / "consumer.m").write_text(harness)
    subprocess.run([
        "swiftc", str(directory / "producer.swift"), "-o", str(directory / "producer")
    ], check=True)
    subprocess.run([
        "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
        "-Wno-incompatible-pointer-types", str(directory / "consumer.m"),
        "-o", str(directory / "consumer")
    ], check=True)
    subprocess.run([
        str(directory / "consumer"), str(directory), str(directory / "producer")
    ], check=True)
    blocked = directory / "blocked"
    blocked.mkdir()
    (blocked / "widget_pending_actions").write_text("not a directory")
    result = subprocess.run([
        str(directory / "producer"), str(blocked), "playpause", "0", "timeline-A"
    ], capture_output=True, text=True)
    assert result.returncode != 0, "A failed durable enqueue must throw instead of reporting a successful widget action."
