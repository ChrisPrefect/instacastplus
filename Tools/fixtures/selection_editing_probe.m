// E2E driver: real smart list, UIKit editing/selection, scrolling and row reuse.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>

@interface NSObject (SelectionProbeAPI)
+ (id)sharedDatabaseManager;
+ (id)sharedAudioSession;
+ (id)playbackManager;
+ (id)viewControllerWithList:(id)list;
- (void)save;
- (void)reconstructObjectHash;
- (void)editForCachingAction:(id)sender;
- (void)updateEpisodes;
- (void)reloadDataAndPreserveSelection;
- (BOOL)_selectMainSidebarListWithUID:(NSString*)uid;
- (void)playEpisode:(id)episode queueUpCurrent:(BOOL)queue at:(double)position autostart:(BOOL)autostart;
- (void)pause;
@end

static NSString* directory;
static UITableViewController* screen;

static UITableViewController* findList(UIViewController* controller) {
    if ([controller isKindOfClass:NSClassFromString(@"ListEpisodesTableViewController")]) return (id)controller;
    for (UIViewController* child in controller.childViewControllers) {
        UITableViewController* found = findList(child);
        if (found) return found;
    }
    return nil;
}

static NSDictionary* snapshot(void) {
    NSMutableArray* cells = [NSMutableArray array];
    for (UITableViewCell* cell in screen.tableView.visibleCells) {
        NSIndexPath* path = [screen.tableView indexPathForCell:cell];
        UIView* play = [cell valueForKey:@"playAccessoryButton"];
        UIImageView* artwork = [cell valueForKey:@"iconView"];
        CGRect imageRect = [artwork convertRect:artwork.bounds toView:cell];
        [cells addObject:@{@"row": @(path.row), @"editing": @(cell.editing), @"selected": @(cell.selected),
            @"playHidden": @(play.hidden), @"imageX": @(imageRect.origin.x), @"imageWidth": @(imageRect.size.width),
            @"contentX": @(cell.contentView.frame.origin.x), @"editControl": [cell valueForKey:@"showsEditControl"] ?: @NO}];
    }
    return @{@"rows": @([screen.tableView numberOfRowsInSection:0]), @"editing": @(screen.editing),
        @"tableEditing": @(screen.tableView.editing), @"selectedRows": [screen.tableView.indexPathsForSelectedRows valueForKey:@"row"] ?: @[],
        @"loading": [screen valueForKey:@"loadingPage"] ?: @NO,
        @"replacing": @([screen valueForKey:@"reloadedEpisodes"] != nil),
        @"playerReady": [[NSClassFromString(@"PlaybackManager") playbackManager] valueForKey:@"ready"] ?: @NO,
        @"visible": cells,
        @"UIKitHasEditControlGetter": @(class_getInstanceMethod(UITableViewCell.class, NSSelectorFromString(@"showsEditControl")) != NULL),
        @"UIKitHasEditControlSetter": @(class_getInstanceMethod(UITableViewCell.class, NSSelectorFromString(@"setShowsEditControl:")) != NULL)};
}

@interface ICSelectionEditingProbe : NSObject @end
@implementation ICSelectionEditingProbe
+ (void)load {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onboard_will_show"];
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"SelectionEditingProbe"];
        __block NSString* lastID;
        [NSTimer scheduledTimerWithTimeInterval:.05 repeats:YES block:^(NSTimer* timer) {
            UIViewController* root = [(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
            if (!root) return;
            NSDictionary* request = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]] ?: NSData.data options:0 error:nil];
            if (!request || [lastID isEqual:request[@"id"]]) return;
            lastID = request[@"id"];
            NSMutableDictionary* reply = [@{@"id":lastID} mutableCopy];
            @try {
                NSString* action = request[@"action"];
                if ([action isEqual:@"seed"]) {
                    id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                    NSManagedObjectContext* context = [database valueForKey:@"objectContext"];
                    NSManagedObject* feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Auswahlprüfung" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/selection.xml"] forKey:@"sourceURL"];
                    [feed setValue:@YES forKey:@"subscribed"];
                    for (NSInteger i=0; i<80; i++) {
                        NSManagedObject* episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                        [episode setValue:feed forKey:@"feed"];
                        NSString* title = i%3 == 0
                            ? @"Eine lange Episodenüberschrift mit mehreren Zeilen beim Wechsel zwischen normaler Ansicht und Auswahl"
                            : @"Auswahlfolge";
                        [episode setValue:[NSString stringWithFormat:@"%@ %02ld",title,(long)i] forKey:@"title"];
                        [episode setValue:i%3 == 1 ? @"Kurzbeschreibung."
                            : @"Eine längere Beschreibung für die Prüfung von Auswahl, Zeilenlayout und wiederverwendeten Podcast-Covern. Der Text belegt mehrere Zeilen und erzeugt zusammen mit den unterschiedlich langen Titeln verschiedene Zeilenhöhen."
                                   forKey:@"subtitle"];
                        [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                        [episode setValue:[NSDate dateWithTimeIntervalSinceNow:-i] forKey:@"pubDate"];
                        [episode setValue:@NO forKey:@"consumed"];
                        [episode setValue:@NO forKey:@"archived"];
                        [episode setValue:@1800 forKey:@"duration"];
                        [episode reconstructObjectHash];
                    }
                    NSManagedObject* playing = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [playing setValue:feed forKey:@"feed"];
                    [playing setValue:@"Pausierter Player" forKey:@"title"];
                    [playing setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [playing setValue:NSDate.date forKey:@"pubDate"];
                    [playing setValue:@YES forKey:@"consumed"];
                    [playing setValue:@60 forKey:@"duration"];
                    [playing reconstructObjectHash];
                    NSManagedObject* medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:playing forKey:@"episode"];
                    [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    NSManagedObject* list = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:context];
                    [list setValue:NSUUID.UUID.UUIDString forKey:@"uid"];
                    [list setValue:@"neue Episoden" forKey:@"name"];
                    [list setValue:@NO forKey:@"played"]; [list setValue:@YES forKey:@"unplayed"];
                    [list setValue:@"pubDate" forKey:@"orderBy"]; [list setValue:@YES forKey:@"descending"];
                    [database save];
                    if (![(id)root _selectMainSidebarListWithUID:[list valueForKey:@"uid"]])
                        @throw [NSException exceptionWithName:@"MissingFixtureList" reason:nil userInfo:nil];
                    screen = findList(root);
                    [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:playing queueUpCurrent:NO at:10 autostart:NO];
                } else if ([action isEqual:@"toggle"]) {
                    [(id)screen editForCachingAction:nil];
                } else if ([action isEqual:@"select"]) {
                    NSIndexPath* path = [NSIndexPath indexPathForRow:[request[@"row"] integerValue] inSection:0];
                    [screen.tableView selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
                    [screen.tableView.delegate tableView:screen.tableView didSelectRowAtIndexPath:path];
                } else if ([action isEqual:@"scroll"]) {
                    [screen.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:[request[@"row"] integerValue] inSection:0] atScrollPosition:UITableViewScrollPositionTop animated:NO];
                    [screen.tableView layoutIfNeeded];
                } else if ([action isEqual:@"reload"]) {
                    [(id)screen reloadDataAndPreserveSelection];
                    [screen.tableView layoutIfNeeded];
                } else if ([action isEqual:@"refresh"]) {
                    [(id)screen updateEpisodes];
                } else if ([action isEqual:@"arrivals"]) {
                    id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                    NSManagedObjectContext* context = [database valueForKey:@"objectContext"];
                    NSManagedObject* feed = [[[screen valueForKey:@"episodes"] firstObject] valueForKey:@"feed"];
                    for (NSInteger i=0; i<3; i++) {
                        NSManagedObject* episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                        [episode setValue:feed forKey:@"feed"];
                        [episode setValue:[NSString stringWithFormat:@"Neue Auswahlfolge %ld",(long)i] forKey:@"title"];
                        [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                        [episode setValue:[NSDate dateWithTimeIntervalSinceNow:i] forKey:@"pubDate"];
                        [episode setValue:@NO forKey:@"consumed"];
                        [episode setValue:@NO forKey:@"archived"];
                        [episode reconstructObjectHash];
                    }
                    [database save];
                    [(id)screen updateEpisodes];
                }
                [reply addEntriesFromDictionary:snapshot()];
            } @catch (NSException* exception) { reply[@"error"] = exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
