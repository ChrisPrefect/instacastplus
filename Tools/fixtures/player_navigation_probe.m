// Drives production navigation in the real app; no method replacement.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <QuartzCore/QuartzCore.h>

@interface NSObject (NavigationProbeAPI)
+ (id)sharedDatabaseManager;
+ (id)playbackViewControllerWithEpisode:(id)episode;
- (void)presentFromParentViewController:(UIViewController*)parent autostart:(BOOL)autostart completion:(void(^)(void))completion;
- (void)showEpisodeListOfEpisode:(id)episode animated:(BOOL)animated;
- (void)_openCurrentPodcastFromPlayerTitle;
- (void)save;
@end

static NSString *directory;
static id fixtureEpisode;
static UINavigationController *player;
static NSMutableArray *frames;
static BOOL monitoring;

static UIViewController *mainController(void) {
    return [(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
}
static UINavigationController *contentNavigation(void) {
    return [[mainController() valueForKey:@"contentViewController"] childViewControllers].firstObject;
}
static NSDictionary *tableState(UIViewController *controller) {
    UITableView *table = [controller valueForKey:@"tableView"];
    NSMutableDictionary *state = [@{@"class": NSStringFromClass(controller.class),
        @"offset": @(table.contentOffset.y), @"height": @(table.contentSize.height),
        @"inWindow": @(table.window != nil), @"rows": @([table numberOfRowsInSection:0]),
        @"topInset": @(table.adjustedContentInset.top)} mutableCopy];
    NSIndexPath *first = table.indexPathsForVisibleRows.firstObject;
    if (first) {
        state[@"firstRow"] = @(first.row);
        state[@"firstRowY"] = @([table rectForRowAtIndexPath:first].origin.y - table.contentOffset.y);
    }
    return state;
}
static NSDictionary *snapshot(void) {
    UINavigationController *nav = contentNavigation();
    NSMutableDictionary *state = [@{@"time": @(CACurrentMediaTime()),
        @"top": nav.topViewController ? NSStringFromClass(nav.topViewController.class) : @"",
        @"playerPresented": @(player.presentingViewController != nil),
        @"playerTransition": @(player.isBeingPresented || player.isBeingDismissed),
        @"playerY": @((player.view.layer.presentationLayer ?: player.view.layer).frame.origin.y)} mutableCopy];
    for (UIViewController *controller in nav.viewControllers) {
        if ([controller isKindOfClass:NSClassFromString(@"SubscriptionsTableViewController")] && controller.isViewLoaded)
            state[@"subscriptions"] = tableState(controller);
        if ([controller isKindOfClass:NSClassFromString(@"FeedEpisodesTableViewController")] && controller.isViewLoaded)
            state[@"episodes"] = tableState(controller);
    }
    return state;
}
static void seed(void) {
    id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
    NSManagedObjectContext *context = [database valueForKey:@"objectContext"];
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Feed"];
    request.predicate = [NSPredicate predicateWithFormat:@"title BEGINSWITH %@", @"Navigation Fixture"];
    for (NSManagedObject *old in [context executeFetchRequest:request error:nil]) [context deleteObject:old];
    [database save];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
    [NSUserDefaults.standardUserDefaults setObject:@"manual" forKey:@"FeedListSortMode"];
    for (NSInteger f = 0; f < 45; f++) {
        id feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
        [feed setValue:[NSString stringWithFormat:@"Navigation Fixture %02ld", (long)f] forKey:@"title"];
        [feed setValue:[NSURL URLWithString:[NSString stringWithFormat:@"https://example.invalid/navigation/%ld", (long)f]] forKey:@"sourceURL"];
        [feed setValue:@YES forKey:@"subscribed"];
        [feed setValue:@(f) forKey:@"rank"];
        for (NSInteger e = 0; e < (f == 25 ? 100 : 1); e++) {
            id episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
            [episode setValue:[NSString stringWithFormat:@"navigation-%ld-%ld", (long)f, (long)e] forKey:@"guid"];
            [episode setValue:[NSString stringWithFormat:@"Folge %03ld", (long)e] forKey:@"title"];
            [episode setValue:[NSDate dateWithTimeIntervalSince1970:1700000000 + e * 3600] forKey:@"pubDate"];
            [episode setValue:@180 forKey:@"duration"];
            [episode setValue:feed forKey:@"feed"];
            id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
            [medium setValue:episode forKey:@"episode"];
            [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
            [medium setValue:@"audio/wav" forKey:@"mimeType"];
            if (f == 25 && e == 60) fixtureEpisode = episode;
        }
    }
    [database save];
}

@interface ICPlayerNavigationProbe : NSObject @end
@implementation ICPlayerNavigationProbe
- (void)frame:(CADisplayLink*)link {
    if (monitoring) [frames addObject:snapshot()];
}
+ (void)load {
    // Fixture preference only, before the app starts its onboarding lifecycle.
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onboard_will_show"];
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"PlayerNavigationProbe"];
        ICPlayerNavigationProbe *driver = [ICPlayerNavigationProbe new];
        CADisplayLink *link = [CADisplayLink displayLinkWithTarget:driver selector:@selector(frame:)];
        [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        __block NSString *lastID;
        [NSTimer scheduledTimerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer) {
            if (!mainController()) return;
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]] ?: NSData.data options:0 error:nil];
            if (!request || [lastID isEqual:request[@"id"]]) return;
            lastID = request[@"id"];
            NSMutableDictionary *reply = [@{@"id": lastID} mutableCopy];
            @try {
                NSString *action = request[@"action"];
                if ([action isEqual:@"seed"]) {
                    seed();
                    [(id)mainController() showEpisodeListOfEpisode:fixtureEpisode animated:NO];
                    [contentNavigation() popViewControllerAnimated:NO];
                } else if ([action isEqual:@"scroll"]) {
                    UITableView *table = [contentNavigation().topViewController valueForKey:@"tableView"];
                    [table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[request[@"row"] integerValue] inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
                } else if ([action isEqual:@"selectFeed"]) {
                    id controller = contentNavigation().topViewController;
                    UITableView *table = [controller valueForKey:@"tableView"];
                    NSFetchedResultsController *fetch = [controller valueForKey:@"fetchController"];
                    NSIndexPath *path = [fetch indexPathForObject:[fixtureEpisode valueForKey:@"feed"]];
                    [table.delegate tableView:table didSelectRowAtIndexPath:path];
                } else if ([action isEqual:@"player"]) {
                    player = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:fixtureEpisode];
                    [(id)player presentFromParentViewController:mainController() autostart:NO completion:nil];
                } else if ([action isEqual:@"closePlayer"]) {
                    UIBarButtonItem *button = player.viewControllers.firstObject.navigationItem.leftBarButtonItem;
                    [UIApplication.sharedApplication sendAction:button.action to:button.target from:button forEvent:nil];
                } else if ([action isEqual:@"title"]) {
                    [(id)player.viewControllers.firstObject _openCurrentPodcastFromPlayerTitle];
                } else if ([action isEqual:@"back"]) {
                    [contentNavigation() popViewControllerAnimated:YES];
                } else if ([action isEqual:@"monitor"]) {
                    frames = [NSMutableArray array]; monitoring = YES;
                } else if ([action isEqual:@"stop"]) {
                    monitoring = NO;
                    [[NSJSONSerialization dataWithJSONObject:frames options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"frames.json"] atomically:YES];
                } else if ([action isEqual:@"capture"]) {
                    UIWindow *window = mainController().view.window;
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
                    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
                    }];
                    [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"app.png"] atomically:YES];
                }
                reply[@"state"] = snapshot();
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
