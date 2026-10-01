#!/usr/bin/env python3
"""Exercise the production page loader when its SQLite reader cannot be opened.

Failure analysis, recorded before writing this test or the production repair:
* newExportBackgroundContext returns nil when addPersistentStore fails. Messaging
  that nil context must not turn the missing query into a successful empty page,
  discard the visible episodes, reset their paging offset, or end the list.
* The failure must set pageError and release loadingPage so the existing retry
  footer is available. Retrying must request a new reader and preserve the same
  snapshot if opening that reader fails again.

Isolation justification: an E2E cannot reliably force an OS/SQLite store-open
failure without modifying or damaging the store. This harness compiles the actual
_loadNextPage and _retryPageLoad implementations verbatim from production. Only
the reader factory and UI boundary are controlled doubles. It does not claim to
exercise UIKit rendering or replace the separate HTTP/simulator E2E evidence.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import shlex
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
PRODUCTION = ROOT / "Classes/ListEpisodesTableViewController.m"


def method(source, signature):
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(signature)


HARNESS = r'''
#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import <CoreGraphics/CoreGraphics.h>
#define EPISODE_PAGE_SIZE 25
#define UITableViewScrollPositionTop 1
#define UITableViewRowAnimationNone 0
typedef struct { CGFloat top, left, bottom, right; } UIEdgeInsets;

@interface NSIndexPath (Rows)
@property(readonly) NSInteger row, section;
+ (instancetype)indexPathForRow:(NSInteger)row inSection:(NSInteger)section;
@end
@implementation NSIndexPath (Rows)
- (NSInteger)row { return [self indexAtPosition:1]; }
- (NSInteger)section { return [self indexAtPosition:0]; }
+ (instancetype)indexPathForRow:(NSInteger)row inSection:(NSInteger)section {
    NSUInteger indexes[] = {section, row};
    return [self indexPathWithIndexes:indexes length:2];
}
@end

@interface UIView : NSObject
+ (void)performWithoutAnimation:(void (^)(void))actions;
@end
@implementation UIView
+ (void)performWithoutAnimation:(void (^)(void))actions { actions(); }
@end
@interface UITableView : NSObject
@property BOOL dragging, decelerating;
@property CGPoint contentOffset;
@property CGSize contentSize;
@property CGRect bounds;
@property UIEdgeInsets adjustedContentInset;
@property NSUInteger reloadCount;
@property(readonly) NSArray<NSIndexPath*> *indexPathsForVisibleRows;
- (CGRect)rectForRowAtIndexPath:(NSIndexPath*)index;
- (void)layoutIfNeeded;
- (void)scrollToRowAtIndexPath:(NSIndexPath*)index atScrollPosition:(NSInteger)position animated:(BOOL)animated;
- (void)insertRowsAtIndexPaths:(NSArray*)paths withRowAnimation:(NSInteger)animation;
@end
@implementation UITableView
- (NSArray*)indexPathsForVisibleRows { return @[]; }
- (CGRect)rectForRowAtIndexPath:(NSIndexPath*)index { return CGRectMake(0, index.row * 72, 390, 72); }
- (void)layoutIfNeeded {}
- (void)scrollToRowAtIndexPath:(NSIndexPath*)index atScrollPosition:(NSInteger)position animated:(BOOL)animated {}
- (void)insertRowsAtIndexPaths:(NSArray*)paths withRowAnimation:(NSInteger)animation {}
@end

@interface CDEpisode : NSManagedObject @end
@implementation CDEpisode @end
@interface CDList : NSObject
@property(strong) NSManagedObjectID *objectID;
@property NSUInteger numberOfEpisodes, numberOfPlayedEpisodes, numberOfPlayedDownloadedEpisodes;
@property NSInteger playbackTime;
- (NSArray<CDEpisode*>*)sortedEpisodesWithOffset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError**)error;
@end
@implementation CDList
- (NSArray*)sortedEpisodesWithOffset:(NSUInteger)offset limit:(NSUInteger)limit error:(NSError**)error {
    @throw [NSException exceptionWithName:@"UnexpectedQuery" reason:@"No context was opened" userInfo:nil];
}
@end
@interface ProbeDatabase : NSObject
@property NSUInteger readerRequests;
@property(strong) NSManagedObjectContext *objectContext;
- (NSManagedObjectContext*)newExportBackgroundContext;
- (NSManagedObjectContext*)newBackgroundContext;
@end
@implementation ProbeDatabase
- (NSManagedObjectContext*)newExportBackgroundContext { self.readerRequests++; return nil; }
- (NSManagedObjectContext*)newBackgroundContext {
    @throw [NSException exceptionWithName:@"UnexpectedReader" reason:@"Replacement must use its reader factory" userInfo:nil];
}
@end
static ProbeDatabase *DMANAGER;

@interface ListEpisodesTableViewController : NSObject {
    BOOL _didRestoreScrollPosition;
}
@property NSInteger episodesLoadGeneration;
@property(strong) NSMutableArray<CDEpisode*> *loadedEpisodes, *reloadedEpisodes;
@property(strong) NSArray<CDEpisode*> *episodes;
@property NSUInteger reloadedPageOffset, nextPageOffset;
@property BOOL episodeReloadPending, loadingPage, reachedListEnd, statisticsLoaded;
@property(strong) NSError *pageError;
@property NSUInteger totalEpisodeCount, playedEpisodeCount, playedDownloadedEpisodeCount;
@property NSInteger totalPlaybackTime;
@property(strong) CDList *list;
@property(strong) UITableView *tableView;
@property NSUInteger footerUpdates, errorFooterUpdates, selectionCaptures;
- (void)_loadNextPage;
- (void)_retryPageLoad:(id)sender;
- (BOOL)_deferEpisodeReloadDuringInteraction;
- (void)updateEpisodes;
- (void)_updatePageFooter;
- (void)_captureSelectedEpisodeObjectIDsForReload;
- (void)reloadDataAndPreserveSelection;
- (void)_storeScrollPosition;
- (void)_restorePendingEpisodeSelectionFromPage:(NSArray*)page startingAtRow:(NSUInteger)row;
- (void)_updateToolbarItemsAnimated:(BOOL)animated;
- (void)_updateToolbarLabels;
- (void)_restoreScrollPositionIfNeeded;
@end
@implementation ListEpisodesTableViewController
- (BOOL)_deferEpisodeReloadDuringInteraction { return NO; }
- (void)updateEpisodes { @throw [NSException exceptionWithName:@"UnexpectedReload" reason:@"No interaction is active" userInfo:nil]; }
- (void)_updatePageFooter { self.footerUpdates++; if (self.pageError) self.errorFooterUpdates++; }
- (void)_captureSelectedEpisodeObjectIDsForReload { self.selectionCaptures++; }
- (void)reloadDataAndPreserveSelection { self.tableView.reloadCount++; self.tableView.contentOffset = CGPointZero; }
- (void)_storeScrollPosition {}
- (void)_restorePendingEpisodeSelectionFromPage:(NSArray*)page startingAtRow:(NSUInteger)row {}
- (void)_updateToolbarItemsAnimated:(BOOL)animated {}
- (void)_updateToolbarLabels {}
- (void)_restoreScrollPositionIfNeeded {}
PRODUCTION_METHODS
@end

static NSUInteger failures;
static void require(BOOL condition, NSString *message) {
    if (!condition) { failures++; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}
static BOOL waitForFooter(ListEpisodesTableViewController *controller, NSUInteger previous) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (controller.footerUpdates <= previous && deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return controller.footerUpdates > previous;
}
static void report(ListEpisodesTableViewController *controller, NSString *phase) {
    NSDictionary *state = @{
        @"phase": phase, @"loaded": @(controller.loadedEpisodes.count),
        @"nextPageOffset": @(controller.nextPageOffset), @"offsetY": @(controller.tableView.contentOffset.y),
        @"loadingPage": @(controller.loadingPage), @"reachedListEnd": @(controller.reachedListEnd),
        @"pageError": controller.pageError.description ?: @"", @"readerRequests": @(DMANAGER.readerRequests),
        @"errorFooterUpdates": @(controller.errorFooterUpdates), @"reloads": @(controller.tableView.reloadCount),
        @"selectionCaptures": @(controller.selectionCaptures)
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
    puts([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
}
int main(void) { @autoreleasepool {
    DMANAGER = [ProbeDatabase new];
    ListEpisodesTableViewController *controller = [ListEpisodesTableViewController new];
    controller.list = [CDList new];
    controller.tableView = [UITableView new];
    controller.tableView.contentOffset = CGPointMake(0, 545);
    controller.tableView.contentSize = CGSizeMake(390, 2000);
    controller.tableView.bounds = CGRectMake(0, 0, 390, 800);
    // Their identity and count matter; no managed-object property is read when
    // the external context factory fails before the production fetch begins.
    controller.loadedEpisodes = (id)[NSMutableArray arrayWithObjects:[NSObject new], [NSObject new], [NSObject new], nil];
    NSMutableArray *visibleSnapshot = controller.loadedEpisodes;
    controller.episodes = visibleSnapshot;
    controller.reloadedEpisodes = [NSMutableArray array];
    controller.nextPageOffset = 3;
    controller.episodesLoadGeneration = 7;
    [controller _loadNextPage];
    require(waitForFooter(controller, 0), @"Reader failure must finish the page operation");
    report(controller, @"first-reader-failure");
    require(controller.pageError != nil, @"nil reader must produce pageError, not successful empty data");
    require(controller.loadedEpisodes == visibleSnapshot && controller.episodes == visibleSnapshot && controller.episodes.count == 3,
            @"Reader failure must preserve the visible episode snapshot");
    require(controller.nextPageOffset == 3 && !controller.reachedListEnd, @"Reader failure must preserve paging position and must not declare list end");
    require(controller.tableView.contentOffset.y == 545 && controller.tableView.reloadCount == 0 && controller.selectionCaptures == 0,
            @"Reader failure must not reload the visible table, move its offset, or reset selection");
    require(!controller.loadingPage && controller.errorFooterUpdates == 1,
            @"Reader failure must release loadingPage and expose the error footer");

    NSUInteger footerUpdates = controller.footerUpdates;
    [controller _retryPageLoad:nil];
    require(waitForFooter(controller, footerUpdates), @"Retry must perform and finish another reader attempt");
    report(controller, @"retry-reader-failure");
    require(DMANAGER.readerRequests == 2, @"Retry must request a new reader instead of stopping at false list end");
    require(controller.pageError != nil && !controller.loadingPage && controller.errorFooterUpdates == 2,
            @"Repeated reader failure must retain an actionable error and allow another retry");
    require(controller.loadedEpisodes == visibleSnapshot && controller.nextPageOffset == 3 && controller.tableView.contentOffset.y == 545,
            @"Retry failure must preserve the original snapshot and position");
    if (!failures) puts("PASS: production page loader preserves snapshot and supports retry after reader-open failure");
    return failures ? 1 : 0;
} }
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, default=ROOT / "build/ScrollRefreshEvidence/reader-context-current")
    args = parser.parse_args()
    out = args.evidence_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    source = PRODUCTION.read_text()
    methods = "\n\n".join(method(source, signature) for signature in (
        "- (void) _loadNextPage", "- (void)_retryPageLoad:(id)sender",
    ))
    probe = out / "probe.m"
    binary = out / "probe"
    probe.write_text(HARNESS.replace("PRODUCTION_METHODS", methods))
    command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
               "-framework", "CoreData", "-framework", "CoreGraphics", str(probe), "-o", str(binary)]
    compile_result = subprocess.run(command, capture_output=True, text=True)
    (out / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        print(compile_result.stderr, file=sys.stderr)
        return compile_result.returncode
    result = subprocess.run([str(binary)], capture_output=True, text=True)
    (out / "run.log").write_text(result.stdout + result.stderr)
    (out / "report.json").write_text(json.dumps({
        "kind": "isolated production-method runtime test", "passed": result.returncode == 0,
        "command": shlex.join([sys.executable, str(Path(__file__).resolve()), "--evidence-dir", str(out)]),
        "compileCommand": shlex.join(command), "environment": platform.platform(),
        "productionFile": str(PRODUCTION), "productionSHA256": hashlib.sha256(source.encode()).hexdigest(),
        "fixture": "reader factory returns nil on the initial attempt and retry",
        "expected": "snapshot, selection and offset preserved; pageError exposed; second reader requested on retry",
        "exitCode": result.returncode,
    }, indent=2) + "\n")
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
