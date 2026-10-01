// Test-only driver for the real simulator app. No production method is replaced.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <QuartzCore/QuartzCore.h>

@interface NSObject (ListRefreshScrollProbeAPI)
+ (id)sharedDatabaseManager;
+ (id)sharedSubscriptionManager;
- (void)subscribeFeedWithURL:(NSURL*)url options:(NSInteger)options completion:(void (^)(id, NSError*))completion;
- (void)unsubscribeFeed:(id)feed completion:(void (^)(NSError*))completion;
- (void)refreshFeeds:(NSArray*)feeds etagHandling:(BOOL)etagHandling completion:(void (^)(BOOL, NSArray*, NSError*))completion;
- (BOOL)_selectMainSidebarListWithUID:(NSString*)uid;
- (void)closeTapped;
- (void)tapGesture:(id)sender;
- (UIContextualAction*)_contextualSwipeActionForSwipeAction:(NSInteger)action atIndexPath:(NSIndexPath*)indexPath;
- (NSArray*)sortedEpisodes;
@end

static NSString *directory;
static id fixtureFeed;
static UIViewController *screen;
static NSString *operation = @"idle";
static NSString *operationError;
static NSInteger completionCount, finishCount, countChangeCount;
static NSMutableArray *events, *samples;
static NSString *anchorHash;
static BOOL monitoring;
static BOOL refreshDuringDrag;
static BOOL observingReplacement, mutationArmed, mutationTriggered;
static id mutationEpisode;
static NSDictionary *mutationResult;

static UIViewController *findList(UIViewController *controller) {
    if ([controller isKindOfClass:NSClassFromString(@"ListEpisodesTableViewController")]) return controller;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = findList(child);
        if (found) return found;
    }
    return nil;
}

static NSArray *episodes(void) { return [screen valueForKey:@"episodes"] ?: @[]; }
static UITableView *table(void) { return [screen valueForKey:@"tableView"]; }

static UIViewController *presentedController(void) {
    UIViewController *root = UIApplication.sharedApplication.delegate.window.rootViewController;
    UIViewController *presented = root.presentedViewController;
    while (presented.presentedViewController) presented = presented.presentedViewController;
    if ([presented isKindOfClass:UINavigationController.class]) presented = ((UINavigationController*)presented).topViewController;
    return presented;
}

static NSDictionary *geometry(void) {
    UITableView *view = table();
    NSArray *loaded = episodes();
    NSMutableDictionary *state = [@{
        @"clock": @(CACurrentMediaTime()), @"loaded": @(loaded.count),
        @"offsetY": @(view.contentOffset.y), @"contentHeight": @(view.contentSize.height),
        @"dragging": @(view.dragging), @"decelerating": @(view.decelerating),
        @"reloadPending": @([screen respondsToSelector:NSSelectorFromString(@"episodeReloadPending")] && [[screen valueForKey:@"episodeReloadPending"] boolValue]),
        @"anchorHash": anchorHash ?: @"", @"anchorPresent": @NO,
        @"loadingPage": [screen valueForKey:@"loadingPage"] ?: @NO,
        @"generation": [screen valueForKey:@"episodesLoadGeneration"] ?: @0,
        @"screenVisible": @(screen.isViewLoaded && screen.view.window != nil),
        @"mutationTriggered": @(mutationTriggered),
        @"mutationPresent": @(mutationEpisode && [loaded containsObject:mutationEpisode])
    } mutableCopy];
    for (NSIndexPath *path in view.indexPathsForVisibleRows) {
        if (path.section != 0 || path.row >= loaded.count) continue;
        CGRect rect = [view rectForRowAtIndexPath:path];
        if (CGRectGetMaxY(rect) <= view.contentOffset.y + view.adjustedContentInset.top + 1) continue;
        state[@"topVisibleHash"] = [loaded[path.row] valueForKey:@"objectHash"];
        state[@"topVisibleY"] = @([view convertRect:rect toView:view.window].origin.y);
        break;
    }
    NSUInteger index = [loaded indexOfObjectPassingTest:^BOOL(id episode, NSUInteger idx, BOOL *stop) {
        return anchorHash && [[episode valueForKey:@"objectHash"] isEqual:anchorHash];
    }];
    if (index != NSNotFound && index < [view numberOfRowsInSection:0]) {
        CGRect rect = [view rectForRowAtIndexPath:[NSIndexPath indexPathForRow:index inSection:0]];
        state[@"anchorPresent"] = @YES;
        state[@"anchorRow"] = @(index);
        state[@"anchorRelativeY"] = @(rect.origin.y - view.contentOffset.y);
        state[@"anchorScreenY"] = @([view convertRect:rect toView:view.window].origin.y);
    }
    return state;
}

static NSDictionary *snapshot(void) {
    NSMutableDictionary *state = [geometry() mutableCopy];
    id manager = [NSClassFromString(@"SubscriptionManager") sharedSubscriptionManager];
    id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
    state[@"operation"] = operation;
    state[@"operationError"] = operationError ?: @"";
    state[@"refreshing"] = [manager valueForKey:@"refreshing"] ?: @NO;
    state[@"completionCount"] = @(completionCount);
    state[@"finishCount"] = @(finishCount);
    state[@"countChangeCount"] = @(countChangeCount);
    state[@"feedEpisodes"] = @([[fixtureFeed valueForKey:@"episodes"] count]);
    state[@"subscribedFeeds"] = @([[database valueForKey:@"feeds"] count]);
    state[@"listCount"] = [[screen valueForKey:@"list"] valueForKey:@"numberOfEpisodes"] ?: @0;
    state[@"statisticsLoaded"] = [screen valueForKey:@"statisticsLoaded"] ?: @NO;
    state[@"pageError"] = [[screen valueForKey:@"pageError"] description] ?: @"";
    state[@"reachedListEnd"] = [screen valueForKey:@"reachedListEnd"] ?: @NO;
    state[@"loadedHashes"] = [episodes() valueForKey:@"objectHash"] ?: @[];
    state[@"presentedController"] = presentedController() ? NSStringFromClass(presentedController().class) : @"";
    state[@"mutationTriggered"] = @(mutationTriggered);
    state[@"mutationConsumed"] = [mutationEpisode valueForKey:@"consumed"] ?: @NO;
    state[@"mutationHash"] = [mutationEpisode valueForKey:@"objectHash"] ?: @"";
    state[@"mutationResult"] = mutationResult ?: @{};
    return state;
}

static void startMonitoring(void) {
    UITableView *view = table();
    NSArray *loaded = episodes();
    CGFloat top = view.contentOffset.y + view.adjustedContentInset.top;
    anchorHash = nil;
    for (NSIndexPath *index in view.indexPathsForVisibleRows) {
        if (index.section != 0 || index.row >= loaded.count) continue;
        if (CGRectGetMaxY([view rectForRowAtIndexPath:index]) > top + 1) {
            anchorHash = [loaded[index.row] valueForKey:@"objectHash"];
            break;
        }
    }
    if (!anchorHash) @throw [NSException exceptionWithName:@"NoVisibleEpisode" reason:@"No visible episode to anchor" userInfo:nil];
    samples = [NSMutableArray array];
    monitoring = YES;
    [samples addObject:geometry()];
}

static void scrollToRow(NSUInteger row) {
    UITableView *view = table();
    if (row >= episodes().count) @throw [NSException exceptionWithName:@"RowNotLoaded" reason:@(row).stringValue userInfo:nil];
    CGRect rect = [view rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
    // UIKit calls the real scroll delegate, including production page prefetch.
    CGFloat offset = rect.origin.y - view.adjustedContentInset.top + 17;
    offset = MIN(offset, MAX(-view.adjustedContentInset.top, view.contentSize.height - view.bounds.size.height + view.adjustedContentInset.bottom));
    [view setContentOffset:CGPointMake(0, offset) animated:NO];
    [view layoutIfNeeded];
}

@interface ICListRefreshScrollProbe : NSObject @end
@implementation ICListRefreshScrollProbe
- (void)refreshFeed {
    operation = @"refresh-pending";
    operationError = nil;
    [[NSClassFromString(@"SubscriptionManager") sharedSubscriptionManager] refreshFeeds:@[fixtureFeed] etagHandling:NO completion:^(BOOL success, NSArray *newEpisodes, NSError *error) {
        completionCount++;
        operation = @"refresh-done";
        operationError = success ? nil : (error.description ?: @"Refresh failed");
        [events addObject:@{@"event": @"refresh-completion", @"clock": @(CACurrentMediaTime()), @"newEpisodes": @(newEpisodes.count), @"success": @(success)}];
    }];
}
- (void)displayFrame:(CADisplayLink*)link {
    if (monitoring) [samples addObject:geometry()];
    if (refreshDuringDrag && table().dragging) {
        refreshDuringDrag = NO;
        [events addObject:@{@"event": @"native-refresh-start", @"state": geometry()}];
        [self refreshFeed];
    }
}
- (void)observeValueForKeyPath:(NSString*)path ofObject:(id)object change:(NSDictionary*)change context:(void*)context {
    if ([path isEqual:@"reloadedPageOffset"]) {
        if (!mutationArmed || [[object valueForKey:path] unsignedIntegerValue] < 25) return;
        mutationArmed = NO;
        // Queue a real user action after this completed page, outside its KVO
        // setter. The next asynchronous page has not been submitted yet.
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                NSArray *replacement = [screen valueForKey:@"reloadedEpisodes"];
                NSUInteger index = [episodes() indexOfObject:mutationEpisode];
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:index inSection:0];
                UITableViewCell *cell = index != NSNotFound ? [table() cellForRowAtIndexPath:indexPath] : nil;
                NSMutableDictionary *result = [@{
                    @"clock": @(CACurrentMediaTime()), @"stagedCount": @(replacement.count),
                    @"stagedContainsEpisode": @([replacement containsObject:mutationEpisode]),
                    @"visibleCell": @(cell != nil), @"loadedBefore": @(episodes().count),
                    @"hash": [mutationEpisode valueForKey:@"objectHash"] ?: @""
                } mutableCopy];
                if (!replacement || ![replacement containsObject:mutationEpisode] || !cell)
                    @throw [NSException exceptionWithName:@"MutationTiming" reason:result.description userInfo:nil];
                // ICEpisodeSwipeActionTogglePlayed = 0 in Defines.h. Exercise the
                // same contextual action handler UIKit invokes after a row swipe.
                UIContextualAction *action = [(id)screen _contextualSwipeActionForSwipeAction:0 atIndexPath:indexPath];
                if (!action) @throw [NSException exceptionWithName:@"MissingSwipeAction" reason:@"Toggle played action is unavailable" userInfo:nil];
                action.handler(action, cell, ^(BOOL completed) { result[@"actionCompleted"] = @(completed); });
                result[@"removedImmediately"] = @(![episodes() containsObject:mutationEpisode]);
                result[@"consumed"] = [mutationEpisode valueForKey:@"consumed"] ?: @NO;
                mutationResult = result;
                mutationTriggered = YES;
                [events addObject:@{@"event": @"mark-played-during-replacement", @"result": result}];
            } @catch (NSException *exception) {
                operationError = exception.description;
            }
        });
        return;
    }
    countChangeCount++;
    [events addObject:@{@"event": @"list-count", @"clock": @(CACurrentMediaTime()), @"count": [object valueForKey:@"numberOfEpisodes"] ?: @0}];
}
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        ICListRefreshScrollProbe *driver = [ICListRefreshScrollProbe new];
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ListRefreshScrollProbe"];
        events = [NSMutableArray array];
        CADisplayLink *display = [CADisplayLink displayLinkWithTarget:driver selector:@selector(displayFrame:)];
        [display addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [NSNotificationCenter.defaultCenter addObserverForName:@"SubscriptionManagerDidFinishRefreshingFeedsNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            finishCount++;
            [events addObject:@{@"event": @"refresh-finished", @"clock": @(CACurrentMediaTime())}];
        }];
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            NSString *path = [directory stringByAppendingPathComponent:@"command.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            id main = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
            if (!data || !main) return;
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            NSMutableDictionary *reply = [NSMutableDictionary dictionary];
            @try {
                NSString *action = request[@"action"];
                id manager = [NSClassFromString(@"SubscriptionManager") sharedSubscriptionManager];
                if ([action isEqual:@"dismissOnboarding"]) {
                    UIViewController *presented = presentedController();
                    if ([presented isKindOfClass:NSClassFromString(@"ChangeLogViewController")]) [(id)presented closeTapped];
                    else if ([presented isKindOfClass:NSClassFromString(@"OnboardScreenVC")]) [(id)presented tapGesture:nil];
                } else if ([action isEqual:@"cleanup"]) {
                    monitoring = NO;
                    mutationArmed = NO;
                    mutationTriggered = NO;
                    mutationEpisode = nil;
                    mutationResult = nil;
                    fixtureFeed = nil;
                    operationError = nil;
                    NSArray *feeds = [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] valueForKey:@"feeds"];
                    for (id feed in feeds) {
                        if (![[feed valueForKey:@"title"] isEqual:@"Scroll Refresh Regression"])
                            @throw [NSException exceptionWithName:@"NotDisposable" reason:@"Simulator contains a non-fixture subscription" userInfo:nil];
                    }
                    operation = feeds.count ? @"cleanup-pending" : @"cleanup-done";
                    __block NSUInteger remaining = feeds.count;
                    for (id feed in [feeds copy]) {
                        [manager unsubscribeFeed:feed completion:^(NSError *error) {
                            if (error) operationError = error.description;
                            if (--remaining == 0) operation = @"cleanup-done";
                        }];
                    }
                } else if ([action isEqual:@"subscribe"]) {
                    operation = @"subscribe-pending";
                    operationError = nil;
                    // Normal subscriptions mark new episodes unplayed.
                    [manager subscribeFeedWithURL:[NSURL URLWithString:request[@"url"]] options:0 completion:^(id feed, NSError *error) {
                        fixtureFeed = feed;
                        operationError = error.description;
                        operation = @"subscribe-done";
                    }];
                } else if ([action isEqual:@"open"]) {
                    if (screen) [[screen valueForKey:@"list"] removeObserver:driver forKeyPath:@"numberOfEpisodes"];
                    if (observingReplacement) {
                        [screen removeObserver:driver forKeyPath:@"reloadedPageOffset"];
                        observingReplacement = NO;
                    }
                    if (![main _selectMainSidebarListWithUID:@"default.unplayed"])
                        @throw [NSException exceptionWithName:@"OpenList" reason:@"Sidebar did not open Ungespielt" userInfo:nil];
                    screen = findList(main);
                    if (!screen) @throw [NSException exceptionWithName:@"NoList" reason:@"List controller missing from actual hierarchy" userInfo:nil];
                    [[screen valueForKey:@"list"] addObserver:driver forKeyPath:@"numberOfEpisodes" options:0 context:NULL];
                } else if ([action isEqual:@"scroll"]) {
                    scrollToRow([request[@"row"] unsignedIntegerValue]);
                } else if ([action isEqual:@"monitor"]) {
                    startMonitoring();
                } else if ([action isEqual:@"armMutation"]) {
                    NSUInteger row = [request[@"row"] unsignedIntegerValue];
                    if (row >= episodes().count || ![screen respondsToSelector:NSSelectorFromString(@"reloadedPageOffset")])
                        @throw [NSException exceptionWithName:@"MutationSetup" reason:@"Replacement paging or target row unavailable" userInfo:nil];
                    mutationEpisode = episodes()[row];
                    mutationArmed = YES;
                    mutationTriggered = NO;
                    mutationResult = nil;
                    if (!observingReplacement) {
                        [screen addObserver:driver forKeyPath:@"reloadedPageOffset" options:0 context:NULL];
                        observingReplacement = YES;
                    }
                } else if ([action isEqual:@"membership"]) {
                    reply[@"expectedHashes"] = [[(id)[screen valueForKey:@"list"] sortedEpisodes] valueForKey:@"objectHash"] ?: @[];
                } else if ([action isEqual:@"refreshDuringDrag"]) {
                    refreshDuringDrag = YES;
                } else if ([action isEqual:@"refresh"]) {
                    if (request[@"row"]) {
                        scrollToRow([request[@"row"] unsignedIntegerValue]);
                        startMonitoring();
                        reply[@"pagingInFlightAtRefresh"] = [screen valueForKey:@"loadingPage"] ?: @NO;
                    }
                    [driver refreshFeed];
                } else if ([action isEqual:@"capture"]) {
                    UIWindow *window = screen.view.window;
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
                    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
                    }];
                    [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"screen.png"] atomically:YES];
                } else if ([action isEqual:@"stop"]) {
                    if (monitoring) [samples addObject:geometry()];
                    monitoring = NO;
                    [[NSJSONSerialization dataWithJSONObject:samples ?: @[] options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"frames.json"] atomically:YES];
                    [[NSJSONSerialization dataWithJSONObject:events options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"events.json"] atomically:YES];
                }
                [reply addEntriesFromDictionary:snapshot()];
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            reply[@"id"] = request[@"id"];
            [[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
