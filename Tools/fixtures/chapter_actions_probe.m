// Drives the real player and observes UIKit geometry without replacing app methods.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import "InstacastBackupImporter.h"

@interface NSObject (ChapterActionsCalls)
+ (id)sharedDatabaseManager;
+ (id)sharedAudioSession;
+ (id)playbackManager;
+ (id)playbackViewControllerWithEpisode:(id)episode;
- (void)presentFromParentViewController:(UIViewController*)parent autostart:(BOOL)autostart completion:(void(^)(void))completion;
- (void)playEpisode:(id)episode queueUpCurrent:(BOOL)queue at:(double)position autostart:(BOOL)autostart;
- (void)save;
- (void)play;
- (void)pause;
- (void)seekToTime:(double)time;
- (NSString*)stringForKey:(NSString*)key;
- (void)resetValueForKey:(NSString*)key;
- (NSArray*)propertyKeys;
- (NSURL*)createEverythingBackupWithContext:(id)context cachedEpisodeHashes:(id)hashes upNextSnapshots:(id)next nowPlayingSnapshot:(id)now credentialValues:(id)credentials alternateIconName:(id)icon deviceName:(id)name error:(NSError**)error;
+ (void)parseData:(NSData*)data completion:(void(^)(id, NSError*))completion;
- (NSInteger)_chaptersSection;
@end

static NSString *directory;
static id episode;
static id firstEpisode;
static id secondEpisode;
static NSString *backupStatus = @"idle";
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
    NSMutableDictionary *strikes = [NSMutableDictionary dictionary];
    BOOL lastStrike = NO;
    for (NSIndexPath *path in table.indexPathsForVisibleRows) {
        if (path.section != section) continue;
        UITableViewCell *row = [table cellForRowAtIndexPath:path];
        NSAttributedString *text = row.textLabel.attributedText;
        BOOL strike = text.length && [[text attribute:NSStrikethroughStyleAttributeName atIndex:0 effectiveRange:nil] integerValue] != 0;
        if (path.row == 5) lastStrike = strike;
        else if (text.string) strikes[text.string] = @(strike);
    }
    id feed = [episode valueForKey:@"feed"];
    NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", [feed valueForKey:@"uid"]];
    UIViewController *presented = player;
    while (presented.presentedViewController) presented = presented.presentedViewController;
    UIAlertController *menu = [presented isKindOfClass:UIAlertController.class] ? (id)presented : nil;
    UITextField *field = menu.textFields.firstObject;
    UITextRange *selection = field.selectedTextRange;
    return @{@"editorSelectionStart": @(selection ? [field offsetFromPosition:field.beginningOfDocument toPosition:selection.start] : -1), @"editorSelectionLength": @(selection ? [field offsetFromPosition:selection.start toPosition:selection.end] : 0), @"menuTitle": menu.title ?: @"", @"menuMessage": menu.message ?: @"", @"backupStatus": backupStatus, @"episodeHash": [pman valueForKeyPath:@"playingEpisode.objectHash"] ?: @"", @"targetEpisodeHash": [episode valueForKey:@"objectHash"] ?: @"", @"strikes": strikes, @"lastStrike": @(lastStrike), @"rule": [feed stringForKey:key] ?: @"", @"presented": @(player.view.window != nil && !player.isBeingPresented),
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
@interface ICChapterActionsProbe : NSObject @end
@implementation ICChapterActionsProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"ChapterActionsProbe"];
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
                    [feed setValue:@"Chapter Actions" forKey:@"title"];
                    [feed setValue:@YES forKey:@"subscribed"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/chapter-scroll.xml"] forKey:@"sourceURL"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:@"chapter-actions-first" forKey:@"objectHash"];
                    [episode setValue:@NO forKey:@"consumed"];
                    [episode setValue:@"chapter-actions-first" forKey:@"guid"];
                    [episode setValue:@"1031 (PROLED) – Scroll Regression" forKey:@"title"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@96 forKey:@"duration"];
                    [episode setValue:feed forKey:@"feed"];
                    id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    NSArray *titles = @[@"Start", @"Intro", @"Main", @"Sponsor Special", @"Discussion", @"Intro", @"End", @"Postshow"];
                    for (NSInteger i=0; i<titles.count; i++) {
                        id chapter = [NSEntityDescription insertNewObjectForEntityForName:@"Chapter" inManagedObjectContext:context];
                        [chapter setValue:episode forKey:@"episode"];
                        [chapter setValue:@(i) forKey:@"index"];
                        [chapter setValue:@(i*12) forKey:@"timecode"];
                        [chapter setValue:@12 forKey:@"duration"];
                        [chapter setValue:titles[i] forKey:@"title"];
                    }
                    firstEpisode = episode;
                    secondEpisode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    for (NSString *key in @[@"title", @"pubDate", @"duration", @"feed"]) [secondEpisode setValue:[episode valueForKey:key] forKey:key];
                    [secondEpisode setValue:@"chapter-actions-second" forKey:@"objectHash"];
                    [secondEpisode setValue:@"chapter-actions-second" forKey:@"guid"];
                    [secondEpisode setValue:@NO forKey:@"consumed"];
                    id otherMedium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    for (NSString *key in @[@"fileURL", @"mimeType"]) [otherMedium setValue:[medium valueForKey:key] forKey:key];
                    [otherMedium setValue:secondEpisode forKey:@"episode"];
                    for (id chapter in [episode valueForKey:@"chapters"]) {
                        id other = [NSEntityDescription insertNewObjectForEntityForName:@"Chapter" inManagedObjectContext:context];
                        for (NSString *key in @[@"index", @"timecode", @"duration", @"title"]) [other setValue:[chapter valueForKey:key] forKey:key];
                        [other setValue:secondEpisode forKey:@"episode"];
                    }
                    [db save];
                } else if ([action isEqual:@"restore"]) {
                    id db = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                    NSManagedObjectContext *context = [db valueForKey:@"objectContext"];
                    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
                    fetch.predicate = [NSPredicate predicateWithFormat:@"guid BEGINSWITH %@", @"chapter-actions-"];
                    for (id item in [context executeFetchRequest:fetch error:nil]) {
                        if ([[item valueForKey:@"guid"] isEqual:@"chapter-actions-first"]) firstEpisode = item;
                        else secondEpisode = item;
                    }
                    episode = firstEpisode;
                } else if ([action isEqual:@"roundtrip"]) {
                    id db = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                    id feed = [episode valueForKey:@"feed"];
                    NSError *error;
                    id exporter = [NSClassFromString(@"ImportExportSettingsViewController") new];
                    NSURL *url = [exporter createEverythingBackupWithContext:[db valueForKey:@"objectContext"] cachedEpisodeHashes:NSSet.set upNextSnapshots:@[] nowPlayingSnapshot:nil credentialValues:@{} alternateIconName:nil deviceName:@"Chapter Actions E2E" error:&error];
                    if (!url || error) [NSException raise:@"BackupExport" format:@"%@", error];
                    NSData *xml = [NSData dataWithContentsOfURL:url];
                    [xml writeToFile:[directory stringByAppendingPathComponent:@"backup.xml"] atomically:YES];
                    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
                    for (NSString *key in [[feed propertyKeys] copy]) {
                        if ([key hasPrefix:@"EpisodeChapterSkipOverrides_"] || [key hasSuffix:@"_auto_skip_chapter_name"]) [feed resetValueForKey:key];
                    }
                    [db save];
                    backupStatus = @"parsing";
                    [NSClassFromString(@"InstacastBackupParser") parseData:xml completion:^(id backup, NSError *parseError) {
                        if (parseError) { backupStatus = parseError.description; return; }
                        backupStatus = @"importing";
                        ICBackupImportCallbacks callbacks = {0};
                        [(id)NSClassFromString(@"InstacastBackupImporter") importBackup:backup categories:ICBackupImportFeedSettings callbacks:callbacks completion:^(NSInteger count, NSInteger queued, NSError *importError) {
                            backupStatus = importError ? importError.description : @"complete";
                            [[player.viewControllers.firstObject valueForKey:@"infoViewController"] performSelector:@selector(reload)];
                        }];
                    }];
                } else if ([action isEqual:@"other"] || [action isEqual:@"first"]) {
                    episode = [action isEqual:@"first"] ? firstEpisode : secondEpisode;
                    [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:episode queueUpCurrent:NO at:0 autostart:NO];
                } else if ([action isEqual:@"seek"]) {
                    [[NSClassFromString(@"PlaybackManager") playbackManager] seekToTime:[request[@"time"] doubleValue]];
                } else if ([action isEqual:@"showFirst"] || [action isEqual:@"showLast"]) {
                    UITableViewController *info = [player.viewControllers.firstObject valueForKey:@"infoViewController"];
                    [info.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[action isEqual:@"showFirst"] ? 1 : 5 inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
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
                    [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:[(request[@"name"] ?: @"screen") stringByAppendingString:@".png"]] atomically:YES];
                }
                NSDictionary *state = player ? snapshot() : @{};
                reply[@"state"] = state;
                NSData *line = [NSJSONSerialization dataWithJSONObject:@{@"request":request, @"observed":state} options:0 error:nil];
                NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:[directory stringByAppendingPathComponent:@"observations.jsonl"]];
                if (!log) { [NSData.data writeToFile:[directory stringByAppendingPathComponent:@"observations.jsonl"] atomically:YES]; log = [NSFileHandle fileHandleForWritingAtPath:[directory stringByAppendingPathComponent:@"observations.jsonl"]]; }
                [log seekToEndOfFile]; [log writeData:line]; [log writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [log closeFile];
            } @catch(NSException *e) { reply[@"error"] = e.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
