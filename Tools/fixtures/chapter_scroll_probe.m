// Drives the real player and observes UIKit geometry without replacing app methods.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

@interface NSObject (ChapterScrollCalls)
+ (id)sharedDatabaseManager;
+ (id)sharedAudioSession;
+ (id)playbackManager;
+ (id)playbackViewControllerWithEpisode:(id)episode;
- (void)presentFromParentViewController:(UIViewController*)parent autostart:(BOOL)autostart completion:(void(^)(void))completion;
- (void)playEpisode:(id)episode queueUpCurrent:(BOOL)queue at:(double)position autostart:(BOOL)autostart;
- (void)save;
- (void)play;
- (void)pause;
- (NSInteger)_chaptersSection;
@end

static NSString *directory;
static id episode;
static UINavigationController *player;
static UIViewController *root(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in scene.windows) if (window.isKeyWindow) return window.rootViewController;
    }
    return nil;
}
static NSDictionary *snapshot(void) {
    UIViewController *content = player.viewControllers.firstObject;
    UITableViewController *info = [content valueForKey:@"infoViewController"];
    UIViewController *controls = [content valueForKey:@"controller"];
    UITableView *table = info.tableView;
    NSInteger section = [(id)info _chaptersSection];
    NSInteger rows = (section >= 0 && section < table.numberOfSections) ? [table numberOfRowsInSection:section] : 0;
    CGRect last = rows ? [table convertRect:[table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:rows-1 inSection:section]] toView:nil] : CGRectZero;
    CGRect pane = [controls.view convertRect:controls.view.bounds toView:nil];
    CGPoint point = CGPointMake(CGRectGetMidX(last), CGRectGetMidY(last));
    UIView *hit = [table.window hitTest:point withEvent:nil];
    UITableViewCell *cell = rows ? [table cellForRowAtIndexPath:[NSIndexPath indexPathForRow:rows-1 inSection:section]] : nil;
    id pman = [NSClassFromString(@"PlaybackManager") playbackManager];
    return @{@"presented": @(player.view.window != nil && !player.isBeingPresented),
        @"playerTop": @(player.topViewController == content), @"transitioning": @(player.transitionCoordinator != nil),
        @"ready": [pman valueForKey:@"ready"] ?: @NO, @"loading": @([content valueForKey:@"loadingInfo"] != nil), @"rows": @(rows),
        @"offset": @(table.contentOffset.y), @"height": @(table.bounds.size.height),
        @"contentHeight": @(table.contentSize.height), @"insetTop": @(table.contentInset.top),
        @"insetBottom": @(table.contentInset.bottom), @"indicatorBottom": @(table.verticalScrollIndicatorInsets.bottom),
        @"requestedBottom": [info valueForKey:@"bottomScrollInset"] ?: @0,
        @"controlsTop": @(CGRectGetMinY(pane)), @"controlsHeight": @(pane.size.height),
        @"lastRowBottom": @(CGRectGetMaxY(last)), @"lastRowHit": @(cell && (hit == cell || [hit isDescendantOfView:cell])),
        @"willAppearFlag": [info valueForKey:@"didWillAppear"] ?: @NO,
        @"playbackTime": [pman valueForKey:@"time"] ?: @0};
}
@interface ICChapterScrollProbe : NSObject @end
@implementation ICChapterScrollProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ChapterScrollProbe"];
        __block NSString *lastID;
        [NSTimer scheduledTimerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer) {
            if (!root() || ![(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]];
            NSDictionary *request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (!request || [lastID isEqual:request[@"id"]]) return;
            lastID = request[@"id"];
            NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:lastID forKey:@"id"];
            @try {
                NSString *action = request[@"action"];
                if ([action isEqual:@"seed"]) {
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                    id db = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                    NSManagedObjectContext *context = [db valueForKey:@"objectContext"];
                    id feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Bits und so Plus" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/chapter-scroll.xml"] forKey:@"sourceURL"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"objectHash"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:@"1031 (PROLED) – Scroll Regression" forKey:@"title"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@180 forKey:@"duration"];
                    [episode setValue:feed forKey:@"feed"];
                    id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    NSArray *titles = @[@"Preshow", @"Intro", @"MacBook Pro PROLED XDR", @"Mac mit Touch", @"iPad mini OLED", @"iPhone Duo", @"Security", @"AI: Modelle und Prompting", @"FreeMilk + BitRig", @"SofaTime TV-Tracking", @"AntiNote Mehrzwecknotizen", @"Pixel 11 Rambler/Klartext-Diktat", @"Outro", @"Postshow"];
                    for (NSInteger i=0; i<titles.count; i++) {
                        id chapter = [NSEntityDescription insertNewObjectForEntityForName:@"Chapter" inManagedObjectContext:context];
                        [chapter setValue:episode forKey:@"episode"];
                        [chapter setValue:@(i) forKey:@"index"];
                        [chapter setValue:@(i*12) forKey:@"timecode"];
                        [chapter setValue:@12 forKey:@"duration"];
                        [chapter setValue:titles[i] forKey:@"title"];
                    }
                    [db save];
                } else if ([action isEqual:@"paneHeight"]) {
                    UIViewController *content = player.viewControllers.firstObject;
                    UIViewController *controls = [content valueForKey:@"controller"];
                    CGFloat height = [request[@"height"] doubleValue];
                    controls.view.frame = CGRectMake(0, content.view.bounds.size.height-height, content.view.bounds.size.width, height);
                    [[content valueForKey:@"infoViewController"] setValue:@(height) forKey:@"bottomScrollInset"];
                } else if ([action isEqual:@"pause"]) {
                    [[NSClassFromString(@"PlaybackManager") playbackManager] pause];
                } else if ([action isEqual:@"play"]) {
                    [[NSClassFromString(@"PlaybackManager") playbackManager] play];
                } else if ([action isEqual:@"preload"]) {
                    [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:0 autostart:NO];
                } else if ([action isEqual:@"open"]) {
                    player = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:episode];
                    [(id)player presentFromParentViewController:root() autostart:NO completion:nil];
                } else if ([action isEqual:@"middle"]) {
                    UITableViewController *info = [player.viewControllers.firstObject valueForKey:@"infoViewController"];
                    [info.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:[(id)info _chaptersSection]] atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
                } else if ([action isEqual:@"layout"]) {
                    UIViewController *info = [player.viewControllers.firstObject valueForKey:@"infoViewController"];
                    [info.view setNeedsLayout];
                    [info.view layoutIfNeeded];
                } else if ([action isEqual:@"bottom"]) {
                    UITableViewController *info = [player.viewControllers.firstObject valueForKey:@"infoViewController"];
                    NSInteger section = [(id)info _chaptersSection];
                    [info.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[info.tableView numberOfRowsInSection:section]-1 inSection:section] atScrollPosition:UITableViewScrollPositionBottom animated:NO];
                } else if ([action isEqual:@"selectLast"]) {
                    UITableViewController *info = [player.viewControllers.firstObject valueForKey:@"infoViewController"];
                    NSInteger section = [(id)info _chaptersSection];
                    [(id<UITableViewDelegate>)info tableView:info.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:[info.tableView numberOfRowsInSection:section]-1 inSection:section]];
                } else if ([action isEqual:@"notes"]) {
                    UIBarButtonItem *button = player.viewControllers.firstObject.navigationItem.rightBarButtonItem;
                    [UIApplication.sharedApplication sendAction:button.action to:button.target from:button forEvent:nil];
                } else if ([action isEqual:@"back"]) {
                    [player popViewControllerAnimated:YES];
                } else if ([action isEqual:@"close"]) {
                    UIBarButtonItem *button = player.viewControllers.firstObject.navigationItem.leftBarButtonItem;
                    [UIApplication.sharedApplication sendAction:button.action to:button.target from:button forEvent:nil];
                } else if ([action isEqual:@"capture"]) {
                    UIWindow *window = player.view.window;
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
                    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
                    }];
                    [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"screen.png"] atomically:YES];
                }
                reply[@"state"] = player ? snapshot() : @{};
            } @catch(NSException *e) { reply[@"error"] = e.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
