// Drives the real player and observes UIKit geometry without replacing app methods.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <QuartzCore/QuartzCore.h>
#import <MediaPlayer/MPVolumeView.h>

@interface NSObject (PlayerReturnCalls)
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
- (void)playNow:(id)sender;
- (void)showChapterList:(id)sender;
- (void)closeAction:(id)sender;
@end

static NSString *directory;
static id episode;
static UINavigationController *player;
static CADisplayLink *monitor;
static NSMutableArray *frames;
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
    NSMutableDictionary *geometry = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"playButton", @"backButton", @"forwardButton", @"volumeMinButton", @"volumeMaxButton"]) {
        UIButton *button = [controls valueForKey:key];
        CGRect box = [button convertRect:button.bounds toView:nil];
        CGRect icon = [button.imageView convertRect:button.imageView.bounds toView:nil];
        geometry[key] = @{@"box": NSStringFromCGRect(box), @"icon": NSStringFromCGRect(icon),
            @"boxY": @(CGRectGetMidY(box)), @"iconY": @(CGRectGetMidY(icon)),
            @"configuration": @(button.configuration != nil)};
    }
    UIButton *play = [controls valueForKey:@"playButton"];
    play.accessibilityIdentifier = @"player-play";
    CGRect playBox = [play convertRect:play.bounds toView:nil];
    NSMutableArray *hits = [NSMutableArray array];
    for (NSNumber *dy in @[@(-48), @0, @48]) {
        CGPoint point = CGPointMake(CGRectGetMidX(playBox), CGRectGetMidY(playBox) + dy.doubleValue);
        UIView *hit = [controls.view.window hitTest:point withEvent:nil];
        [hits addObject:@{ @"dy": dy, @"play": @(hit == play || [hit isDescendantOfView:play]), @"class": NSStringFromClass(hit.class) ?: @"nil" }];
    }
    UIView *volume = [controls valueForKey:@"volumeView"];
    NSMutableArray *tracks = [NSMutableArray array];
    for (UIView *child in volume.subviews) if ([child isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider*)child;
        CGRect track = [slider convertRect:[slider trackRectForBounds:slider.bounds] toView:nil];
        [tracks addObject:@{ @"y": @(CGRectGetMidY(track)), @"width": @(track.size.width), @"value": @(slider.value), @"hidden": @(slider.hidden) }];
    }
    NSMutableArray *visible = [NSMutableArray array];
    for (NSIndexPath *path in table.indexPathsForVisibleRows) if (path.section == section) {
        CGRect row = [table convertRect:[table rectForRowAtIndexPath:path] toView:nil];
        if (CGRectGetMinY(row) < CGRectGetMinY(pane) && CGRectGetMaxY(row) > info.view.safeAreaInsets.top)
            [visible addObject:@{ @"row": @(path.row), @"y": @(CGRectGetMinY(row)) }];
    }
    return @{@"geometry": geometry, @"playHits": hits, @"tracks": tracks, @"visibleRows": visible,
        @"nativeSliderClassAvailable": @(NSClassFromString(@"MPVolumeSlider") != nil),
        @"nativeSliderRect": NSStringFromCGRect([(MPVolumeView*)volume volumeSliderRectForBounds:volume.bounds]),
        @"web": @(player.presentedViewController != nil), @"top": NSStringFromClass(player.topViewController.class) ?: @"",
        @"presented": @(player.view.window != nil && !player.isBeingPresented),
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
@interface ICPlayerReturnProbe : NSObject @end
@implementation ICPlayerReturnProbe
+ (void)sample:(CADisplayLink*)link { if (player) [frames addObject:snapshot()]; }
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"PlayerReturnProbe"];
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
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/player-return.xml"] forKey:@"sourceURL"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"objectHash"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:@"1031 (PROLED) – Scroll Regression" forKey:@"title"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@180 forKey:@"duration"];
                    [episode setValue:@NO forKey:@"consumed"];
                    [episode setValue:@"<p>Player return fixture</p>" forKey:@"summary"];
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"OpenLinksInExternalBrowser"];
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
                        [chapter setValue:[NSURL URLWithString:@"http://127.0.0.1:18765/chapter"] forKey:@"linkURL"];
                    }
                    [db save];
                } else if ([action isEqual:@"monitor"]) {
                    frames = [NSMutableArray array];
                    [monitor invalidate];
                    monitor = [CADisplayLink displayLinkWithTarget:self selector:@selector(sample:)];
                    [monitor addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
                } else if ([action isEqual:@"stop"]) {
                    [monitor invalidate]; monitor = nil;
                    [[NSJSONSerialization dataWithJSONObject:frames options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"frames.json"] atomically:YES];
                } else if ([action isEqual:@"mini"]) {
                    id main = [(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    [main playNow:nil];
                    player = (id)root().presentedViewController;
                } else if ([action isEqual:@"chapters"]) {
                    [(id)[player.viewControllers.firstObject valueForKey:@"infoViewController"] showChapterList:nil];
                } else if ([action isEqual:@"chapterLink"]) {
                    UITableViewController *info = [player.viewControllers.firstObject valueForKey:@"infoViewController"];
                    NSInteger section = [(id)info _chaptersSection];
                    UITableViewCell *cell = [info.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:section]];
                    UIButton *link = [cell valueForKey:@"linkButton"];
                    if (!link || link.hidden) [NSException raise:@"MissingLink" format:@"No visible chapter link"];
                    [link sendActionsForControlEvents:UIControlEventTouchUpInside];
                } else if ([action isEqual:@"webBack"]) {
                    [(id)[(UINavigationController*)player.presentedViewController topViewController] closeAction:nil];
                } else if ([action isEqual:@"lateNativeVolumeSlider"]) {
                    // The Simulator does not connect MPVolumeView to a hardware
                    // route. Supply the actual iOS framework slider after the
                    // player has appeared, at the boundary where it is missing.
                    MPVolumeView *volume = [[player.viewControllers.firstObject valueForKey:@"controller"] valueForKey:@"volumeView"];
                    Class sliderClass = NSClassFromString(@"MPVolumeSlider");
                    if (!sliderClass) [NSException raise:@"MissingNativeSlider" format:@"iOS MPVolumeSlider class unavailable"];
                    UISlider *slider = [[sliderClass alloc] initWithFrame:volume.bounds];
                    slider.tag = 18756;
                    [slider setThumbImage:[UIImage imageNamed:@"Video Slider Thumb"] forState:UIControlStateNormal];
                    [slider layoutIfNeeded];
                    // Boundary input from the reported iPhone rendering: the
                    // native track is 9 pt below the 44 pt volume row's top.
                    CGRect track = [slider trackRectForBounds:slider.bounds];
                    slider.frame = CGRectOffset(slider.frame, 0, [request[@"trackCenterY"] doubleValue] - CGRectGetMidY(track));
                    [volume addSubview:slider];
                    [volume setNeedsLayout];
                    [volume layoutIfNeeded];
                } else if ([action isEqual:@"layoutPlayerControls"]) {
                    UIViewController *controls = [player.viewControllers.firstObject valueForKey:@"controller"];
                    [controls.view setNeedsLayout];
                    [controls.view layoutIfNeeded];
                } else if ([action isEqual:@"volumeStep"]) {
                    [[player.viewControllers.firstObject valueForKey:@"controller"] valueForKey:@"volumeMinButton"];
                    UIButton *button = [[player.viewControllers.firstObject valueForKey:@"controller"] valueForKey:@"volumeMinButton"];
                    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
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
