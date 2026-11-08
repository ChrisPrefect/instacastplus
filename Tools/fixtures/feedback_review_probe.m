// Test-only driver: real Core Data, playback, list selection and UIKit actions.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import "PlaybackManager.h"
@class CDEpisodeList;
#import "AudioSession.h"
#import "EpisodesTableViewController.h"
#import "ListEpisodesTableViewController.h"
#import "AppleWatchSyncManager.h"
#import "CacheManager.h"

@interface NSObject (FeedbackReviewAPI)
+ (id)sharedDatabaseManager;
- (void)reconstructObjectHash;
- (void)save;
- (void)_handleIncomingPayload:(NSDictionary*)payload;
@end

static NSString *directory;
static NSMutableArray *fixtures;
static ListEpisodesTableViewController *screen;
static NSString *operation;
static NSDictionary *snapshot(void) {
    PlaybackManager *player = [NSClassFromString(@"PlaybackManager") playbackManager];
    NSMutableArray *states = [NSMutableArray array];
    for (NSManagedObject *episode in fixtures) {
        CacheManager *cache = [NSClassFromString(@"CacheManager") sharedCacheManager];
        NSURL *url = [cache URLForCachedEpisode:(id)episode];
        [states addObject:@{@"hash": [episode valueForKey:@"objectHash"] ?: @"",
            @"archived": [episode valueForKey:@"archived"] ?: @NO,
            @"consumed": [episode valueForKey:@"consumed"] ?: @NO,
            @"position": [episode valueForKey:@"position"] ?: @0,
            @"starred": [episode valueForKey:@"starred"] ?: @NO,
            @"cached": @([cache episodeIsCached:(id)episode]),
            @"fileExists": @(url && [[NSFileManager defaultManager] fileExistsAtPath:url.path]),
            @"cachePath": url.path ?: @""}];
    }
    UIAlertController *alert = [screen.presentedViewController isKindOfClass:UIAlertController.class]
        ? (id)screen.presentedViewController : nil;
    return @{@"time": @(player.time), @"ready": @(player.ready), @"paused": @(player.paused),
        @"restoredEpisodeHash": [(id)[NSClassFromString(@"AudioSession") sharedAudioSession].episode valueForKey:@"objectHash"] ?: @"",
        @"restoredEpisodePosition": [(id)[NSClassFromString(@"AudioSession") sharedAudioSession].episode valueForKey:@"position"] ?: @0,
        @"episodes": states, @"loadedHashes": [screen.episodes valueForKey:@"objectHash"] ?: @[],
        @"actions": [alert.actions valueForKey:@"title"] ?: @[], @"operation": operation ?: @"idle",
        @"editing": @(screen.editing), @"selectedCount": @(screen.tableView.indexPathsForSelectedRows.count)};
}

@interface ICFeedbackReviewProbe : NSObject @end
@implementation ICFeedbackReviewProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"FeedbackReviewProbe"];
        [NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer *timer) {
            NSString *path = [directory stringByAppendingPathComponent:@"command.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data || ![(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            NSMutableDictionary *reply = [NSMutableDictionary dictionary];
            PlaybackManager *player = [NSClassFromString(@"PlaybackManager") playbackManager];
            id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
            NSManagedObjectContext *context = [database valueForKey:@"objectContext"];
            NSString *action = command[@"action"];
            @try {
                if ([action isEqual:@"fixture"]) {
                    [player close];
                    for (NSString *entity in @[@"Episode", @"AppleWatchEpisodeState"]) {
                        NSFetchRequest *cleanup = [NSFetchRequest fetchRequestWithEntityName:entity];
                        cleanup.predicate = [NSPredicate predicateWithFormat:([entity isEqual:@"Episode"] ? @"objectHash == %@" : @"episodeHash == %@"), @"position-probe"];
                        for (NSManagedObject *object in [context executeFetchRequest:cleanup error:nil]) [context deleteObject:object];
                    }
                    [database save];
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"PlayerReplayAfterPause"];
                    NSManagedObject *feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Feedbackprüfung" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/feedback-review.xml"] forKey:@"sourceURL"];
                    [feed setValue:@YES forKey:@"subscribed"];
                    fixtures = [NSMutableArray array];
                    for (NSInteger i = 0; i < 4; i++) {
                        NSManagedObject *episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                        [episode setValue:feed forKey:@"feed"];
                        [episode setValue:[NSString stringWithFormat:@"Prüffolge %ld", (long)i] forKey:@"title"];
                        [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                        [episode setValue:[NSDate dateWithTimeIntervalSinceNow:-i] forKey:@"pubDate"];
                        [episode setValue:@4800 forKey:@"duration"];
                        [episode setValue:@YES forKey:@"consumed"];
                        [episode setValue:@NO forKey:@"archived"];
                        [episode reconstructObjectHash];
                        if (i == 0) [episode setValue:@"position-probe" forKey:@"objectHash"];
                        NSManagedObject *medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                        [medium setValue:episode forKey:@"episode"];
                        [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                        [medium setValue:@"audio/wav" forKey:@"mimeType"];
                        [fixtures addObject:episode];
                    }
                    [database save];
                    NSManagedObject *list = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:context];
                    [list setValue:NSUUID.UUID.UUIDString forKey:@"uid"];
                    [list setValue:@"gehörte Episoden" forKey:@"name"];
                    [list setValue:@YES forKey:@"played"];
                    [list setValue:@YES forKey:@"unplayed"];
                    [list setValue:@"pubDate" forKey:@"orderBy"];
                    [list setValue:@YES forKey:@"descending"];
                    [database save];
                    screen = [NSClassFromString(@"ListEpisodesTableViewController") viewControllerWithList:(id)list];
                    UIViewController *root = UIApplication.sharedApplication.delegate.window.rootViewController;
                    [root dismissViewControllerAnimated:NO completion:^{
                        [root presentViewController:[[UINavigationController alloc] initWithRootViewController:screen] animated:NO completion:nil];
                    }];
                } else if ([action isEqual:@"cacheFixture"]) {
                    operation = @"importing";
                    NSArray *indices = @[@0, @1, @2];
                    __block NSUInteger remaining = indices.count;
                    for (NSNumber *index in indices) {
                        NSURL *url = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"import-%@.wav", index]]];
                        [[NSFileManager defaultManager] copyItemAtPath:[directory stringByAppendingPathComponent:@"download.wav"] toPath:url.path error:nil];
                        [[NSClassFromString(@"CacheManager") sharedCacheManager] importFileAtURL:url forEpisode:fixtures[index.unsignedIntegerValue] completion:^(BOOL success, NSError *error) {
                            if (!success) operation = [@"import-error: " stringByAppendingString:error.description ?: @""];
                            remaining--;
                            if (remaining == 0 && [operation isEqual:@"importing"]) {
                                [fixtures[0] setValue:@YES forKey:@"starred"];
                                [fixtures[2] setValue:@NO forKey:@"consumed"];
                                [fixtures[2] setValue:@2147 forKey:@"position"];
                                [database save];
                                operation = @"imported";
                            }
                        }];
                    }
                } else if ([action isEqual:@"menu"]) {
                    screen.editingStyle = EpisodesTableViewEditingStyleDownload;
                    [screen setEditing:YES animated:NO];
                    for (NSNumber *index in command[@"indices"]) {
                        NSUInteger row = [screen.episodes indexOfObject:fixtures[index.unsignedIntegerValue]];
                        if (row == NSNotFound) @throw [NSException exceptionWithName:@"MissingFixtureRow" reason:index.description userInfo:nil];
                        [screen.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                            animated:NO scrollPosition:UITableViewScrollPositionNone];
                    }
                    [screen showEditingOptionsForSelection:nil];
                } else if ([action isEqual:@"invokeDelete"]) {
                    UIAlertController *alert = (id)screen.presentedViewController;
                    UIAlertAction *chosen = nil;
                    for (UIAlertAction *item in alert.actions) if (item.style == UIAlertActionStyleDestructive) { chosen = item; break; }
                    if (!chosen) @throw [NSException exceptionWithName:@"MissingDelete" reason:@"Selection sheet has no destructive action" userInfo:nil];
                    void (^handler)(UIAlertAction*) = [chosen valueForKey:@"handler"];
                    [screen dismissViewControllerAnimated:NO completion:^{ handler(chosen); }];
                } else if ([action isEqual:@"watchFixture"]) {
                    NSManagedObject *episode = fixtures[0];
                    [episode setValue:@NO forKey:@"consumed"];
                    NSManagedObject *state = [NSEntityDescription insertNewObjectForEntityForName:@"AppleWatchEpisodeState" inManagedObjectContext:context];
                    [state setValue:[episode valueForKey:@"objectHash"] forKey:@"episodeHash"];
                    [state setValue:@"position-probe" forKey:@"uid"];
                    [state setValue:@"manual" forKey:@"selectionSource"];
                    [state setValue:@"downloaded" forKey:@"watchStatus"];
                    [state setValue:NSDate.date forKey:@"watchAddedDate"];
                    [database save];
                    [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:(id)episode queueUpCurrent:NO at:4200 autostart:NO];
                } else if ([action isEqual:@"watch"]) {
                    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[command[@"timestamp"] doubleValue]];
                    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
                    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
                    NSDictionary *payload = @{@"type": command[@"finished"] ? @"playback.watchFinished" : @"playback.watchPosition",
                        @"episodeHash": [fixtures[0] valueForKey:@"objectHash"], @"selectionIdentifier": @"position-probe",
                        @"position": command[@"position"], @"consumed": command[@"finished"] ?: @NO,
                        @"timestamp": [formatter stringFromDate:date]};
                    [[NSClassFromString(@"AppleWatchSyncManager") sharedManager] _handleIncomingPayload:payload];
                } else if ([action isEqual:@"watchPayload"]) {
                    [[NSClassFromString(@"AppleWatchSyncManager") sharedManager] _handleIncomingPayload:command[@"payload"]];
                } else if ([action isEqual:@"play"]) [player play];
                else if ([action isEqual:@"resume"]) [[NSClassFromString(@"AudioSession") sharedAudioSession] togglePlay];
                else if ([action isEqual:@"pause"]) [player pause];
                else if ([action isEqual:@"seek"]) [player seekToTime:[command[@"position"] doubleValue] tolerance:NO];
                else if ([action isEqual:@"reload"]) [screen updateEpisodes];
                else if ([action isEqual:@"capture"]) {
                    UIWindow *window = screen.view.window;
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
                    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
                    }];
                    [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"screen.png"] atomically:YES];
                }
                [reply addEntriesFromDictionary:snapshot()];
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            reply[@"id"] = command[@"id"];
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
