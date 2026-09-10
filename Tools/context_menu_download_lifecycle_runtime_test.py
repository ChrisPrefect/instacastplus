#!/usr/bin/env python3
"""Replay download completion between context-menu configuration and presentation.

Compile the actual Objective-C configuration, update gates, count-change handler
and dismissal callbacks. Foundation doubles record table writes; this exercises
app lifecycle logic without claiming to reproduce UIKit's rendering in a simulator.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
episodes = (ROOT / 'Classes/EpisodesTableViewController.m').read_text()
lists = (ROOT / 'Classes/ListEpisodesTableViewController.m').read_text()


def method(source, signature):
    start = source.index(signature)
    start = source.rfind('\n- (', 0, start) + 1 if not signature.startswith('- (') else start
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if depth == 0:
            return source[start:end + 1]
    raise AssertionError(signature)


enum_start = episodes.index('typedef NS_ENUM(NSInteger, ICEpisodeListDeferredUpdate)')
enum_end = episodes.index('};', enum_start) + 2
methods = '\n'.join(method(episodes, signature) for signature in (
    'contextMenuConfigurationForRowAtIndexPath:',
    'willDisplayContextMenuWithConfiguration:',
    'willEndContextMenuInteractionWithConfiguration:',
    '- (BOOL) _deferTableUpdateDuringSwipe:',
    '- (BOOL) _deferEpisodeReloadDuringInteraction',
    '- (void) _flushDeferredEpisodeInteractionUpdate',
    '- (void) _endSwipeInteractionAndFlushDeferredUpdate',
    '- (void) _performPlayComboButtonUpdate',
))
source = r'''
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#define WEAK_SELF __weak typeof(self) weakSelf = self;
#define EPISODE_PAGE_SIZE 25
ENUM
@interface NSIndexPath (Row)
@property(readonly) NSInteger row;
@end
@implementation NSIndexPath (Row)
- (NSInteger)row { return [self indexAtPosition:0]; }
@end
@interface CDEpisode : NSObject
@property(copy) NSString* objectHash;
@end
@implementation CDEpisode
@end
@interface UIMenuElement : NSObject
@end
@implementation UIMenuElement
@end
@interface UIMenu : UIMenuElement
@property(copy) NSString* title;
+ (instancetype)menuWithTitle:(NSString*)title children:(NSArray*)children;
@end
@implementation UIMenu
+ (instancetype)menuWithTitle:(NSString*)title children:(NSArray*)children {
    UIMenu* menu = [self new]; menu.title = title; return menu;
}
@end
#define UIContextMenuConfigurationElementOrderFixed 1
@interface UIContextMenuConfiguration : NSObject
@property(copy) NSString* identifier;
@property(copy) UIMenu* (^actionProvider)(NSArray<UIMenuElement*>*);
@property NSInteger preferredMenuElementOrder;
+ (instancetype)configurationWithIdentifier:(NSString*)identifier previewProvider:(id)preview actionProvider:(UIMenu* (^)(NSArray<UIMenuElement*>*))provider;
@end
@implementation UIContextMenuConfiguration
+ (instancetype)configurationWithIdentifier:(NSString*)identifier previewProvider:(id)preview actionProvider:(UIMenu* (^)(NSArray<UIMenuElement*>*))provider {
    UIContextMenuConfiguration* config = [self new]; config.identifier = identifier;
    config.actionProvider = provider; return config;
}
@end
@protocol UIContextMenuInteractionAnimating
- (void)addCompletion:(void (^)(void))completion;
@end
@interface ProbeAnimator : NSObject <UIContextMenuInteractionAnimating>
@property(copy) void (^completion)(void);
@end
@implementation ProbeAnimator
- (void)addCompletion:(void (^)(void))completion { self.completion = completion; }
@end
@interface UITableView : NSObject
@property BOOL editing, dragging, decelerating;
@property(strong) id window;
@property CGPoint contentOffset;
@property NSInteger reloads, visibleCellReads;
- (void)reloadData;
- (NSArray*)visibleCells;
@end
@implementation UITableView
- (void)reloadData { self.reloads++; }
- (NSArray*)visibleCells { self.visibleCellReads++; return @[]; }
@end
@interface ProbeList : NSObject
@property(copy) NSString* name;
@end
@implementation ProbeList
@end
@interface ICDiagnosticLogger : NSObject
+ (instancetype)shared;
- (void)logEvent:(NSString*)event message:(NSString*)message metadata:(NSDictionary*)metadata;
@end
@implementation ICDiagnosticLogger
+ (instancetype)shared { return [self new]; }
- (void)logEvent:(NSString*)event message:(NSString*)message metadata:(NSDictionary*)metadata {}
@end
@interface EpisodesTableViewController : NSObject {
    BOOL _needsPlayComboButtonUpdate, _didRestoreScrollPosition;
}
@property(strong) UITableView* tableView;
@property(strong) NSArray<CDEpisode*>* episodes;
@property(strong) NSArray<CDEpisode*>* episodesAfterDownload;
@property(strong) NSArray* loadedEpisodes;
@property(strong) ProbeList* list;
@property BOOL swipeInteractionActive, contextMenuInteractionActive, suppressNextListReload, userAction;
@property ICEpisodeListDeferredUpdate deferredUpdateAfterInteraction;
@property NSInteger nextPageOffset, episodeReloads;
- (void)updateEpisodes;
- (void)_updateToolbarItemsAnimated:(BOOL)animated;
- (void)_updateToolbarLabels;
- (void)_updateVisiblePlaylistIndicators;
- (void)_transcriptionQueueChanged;
- (void)_storeScrollPosition;
- (void)reloadDataAndPreserveSelection;
- (void)coalescedPerformSelector:(SEL)selector afterDelay:(double)delay;
- (UIMenu*)_contextMenuForEpisode:(CDEpisode*)episode;
@end
@implementation EpisodesTableViewController
- (void)updateEpisodes {
    self.episodeReloads++;
    // The completed first download no longer matches the "new episodes" list.
    self.episodes = self.episodesAfterDownload;
    [self.tableView reloadData];
}
- (void)_updateToolbarItemsAnimated:(BOOL)animated {}
- (void)_updateToolbarLabels {}
- (void)_updateVisiblePlaylistIndicators { [self.tableView visibleCells]; }
- (void)_transcriptionQueueChanged { [self.tableView visibleCells]; }
- (void)_storeScrollPosition {}
- (void)reloadDataAndPreserveSelection { [self.tableView reloadData]; }
- (void)coalescedPerformSelector:(SEL)selector afterDelay:(double)delay { abort(); }
- (UIMenu*)_contextMenuForEpisode:(CDEpisode*)episode {
    return [UIMenu menuWithTitle:episode.objectHash children:@[]];
}
METHODS
COUNT_RELOAD
@end
static int failures;
static void require(BOOL ok, NSString* message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); failures++; }
}
int main() { @autoreleasepool {
    CDEpisode* download = [CDEpisode new]; download.objectHash = @"download";
    CDEpisode* selected = [CDEpisode new]; selected.objectHash = @"selected";
    CDEpisode* next = [CDEpisode new]; next.objectHash = @"next";
    for (int mode = 0; mode < 4; mode++) {
        EpisodesTableViewController* controller = [EpisodesTableViewController new];
        UITableView* table = [UITableView new]; controller.tableView = table;
        controller.episodes = @[download, selected, next];
        controller.episodesAfterDownload = @[selected, next];
        NSIndexPath* row = [NSIndexPath indexPathWithIndex:1];
        UIContextMenuConfiguration* config = [controller tableView:table contextMenuConfigurationForRowAtIndexPath:row point:CGPointZero];
        require([config.identifier isEqual:@"selected"], @"configuration lost the touched episode");

        // UIKit has requested the configuration but has NOT called willDisplay.
        // Both the queued button refresh and the list count change can arrive here.
        [controller _performPlayComboButtonUpdate];
        [controller _reloadListAfterCountChange];
        [controller _reloadListAfterCountChange];
        require(table.reloads == 0 && controller.episodeReloads == 0 && table.visibleCellReads == 0,
                @"download completion rewrites the table during the pre-display lift phase");
        require(controller.episodes.count == 3 && controller.episodes[1] == selected,
                @"the selected row changed before UIKit could finish lifting its cell");
        require([config.actionProvider(@[]).title isEqual:@"selected"], @"menu actions changed episode");
        if (mode == 0 || mode == 3) {
            [controller tableView:table willDisplayContextMenuWithConfiguration:config animator:nil];
        }
        // Modes 1/2 cancel the lift before a menu appears, with/without animation.
        controller.swipeInteractionActive = mode == 3;
        ProbeAnimator* animator = mode == 2 ? nil : [ProbeAnimator new];
        [controller tableView:table willEndContextMenuInteractionWithConfiguration:config animator:animator];
        if (animator) {
            require(table.reloads == 0, @"reload escaped before the dismissal animation completed");
            animator.completion();
        }
        if (mode == 3) {
            require(table.reloads == 0, @"menu dismissal released a still-active swipe");
            [controller _endSwipeInteractionAndFlushDeferredUpdate];
        }
        require(!controller.contextMenuInteractionActive && controller.episodeReloads == 1,
                @"dismissal/cancellation must apply the pending episode reload exactly once");
        require(controller.episodes.count == 2 && controller.episodes[0] == selected,
                @"completed download did not leave the list after the interaction ended");
        [controller _flushDeferredEpisodeInteractionUpdate];
        require(controller.episodeReloads == 1, @"pending reload was replayed twice");
    }
    EpisodesTableViewController* invalid = [EpisodesTableViewController new];
    invalid.tableView = [UITableView new]; invalid.episodes = @[selected];
    invalid.tableView.editing = YES;
    require([invalid tableView:invalid.tableView contextMenuConfigurationForRowAtIndexPath:[NSIndexPath indexPathWithIndex:0] point:CGPointZero] == nil && !invalid.contextMenuInteractionActive,
            @"editing rejection must not retain an interaction gate");
    invalid.tableView.editing = NO;
    require([invalid tableView:invalid.tableView contextMenuConfigurationForRowAtIndexPath:[NSIndexPath indexPathWithIndex:1] point:CGPointZero] == nil && !invalid.contextMenuInteractionActive,
            @"out-of-range rejection must not retain an interaction gate");
    if (!failures) puts("Context-menu download lifecycle runtime checks passed (opening, cancellation, dismissal, swipe overlap)");
    return failures ? 1 : 0;
} }
'''
source = source.replace('ENUM', episodes[enum_start:enum_end])
source = source.replace('METHODS', methods)
source = source.replace('COUNT_RELOAD', method(lists, '- (void) _reloadListAfterCountChange'))
with tempfile.TemporaryDirectory(prefix='instacast-context-menu-') as temp:
    path = Path(temp) / 'probe.m'
    binary = Path(temp) / 'probe'
    path.write_text(source)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation', '-framework', 'CoreGraphics',
                    str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
