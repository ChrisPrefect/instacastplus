// E2E fixture/state probe: real Core Data, AudioSession and PlaybackManager.
// No production method is replaced. Only install on the disposable test simulator.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>

@interface NSObject (ShortcutsProbe)
+ (id)sharedDatabaseManager;
+ (id)sharedAudioSession;
+ (id)playbackManager;
- (void)save;
- (void)addList:(id)list;
- (void)clear;
- (void)seekToTime:(double)time;
- (NSDictionary*)sleepTimerDiagnosticsMetadata;
@end

@interface ICShortcutsControlsProbe : NSObject @end
@implementation ICShortcutsControlsProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                              stringByAppendingPathComponent:@"ShortcutsControlsProbe"];
        __block NSString *lastID;
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
            NSManagedObjectContext *context = [database valueForKey:@"objectContext"];
            if (!context) return;
            NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]];
            if (!data) return;
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!request || [lastID isEqual:request[@"id"]]) return;
            lastID = request[@"id"];
            id session = [NSClassFromString(@"AudioSession") sharedAudioSession];
            id player = [NSClassFromString(@"PlaybackManager") playbackManager];
            @try {
                if ([request[@"action"] isEqual:@"seed"]) {
                    NSFetchRequest *feeds = [NSFetchRequest fetchRequestWithEntityName:@"Feed"];
                    NSCAssert([context countForFetchRequest:feeds error:nil] == 0, @"Use a fresh disposable simulator");
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"ScreenTimerAlwaysActive"];
                    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"IntelligentSleepTimerAlwaysActive"];
                    [NSUserDefaults.standardUserDefaults setInteger:5 forKey:@"DefaultIntelligentSleepTimer"];
                    id feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Shortcuts Fixture Podcast" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/shortcuts-fixture"] forKey:@"sourceURL"];
                    [feed setValue:@YES forKey:@"subscribed"];
                    NSMutableArray *episodes = [NSMutableArray array];
                    for (NSInteger index = 1; index <= 2; index++) {
                        id episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                        NSString *identifier = [NSString stringWithFormat:@"shortcuts-fixture-%ld", (long)index];
                        [episode setValue:identifier forKey:@"objectHash"];
                        [episode setValue:identifier forKey:@"guid"];
                        [episode setValue:[NSString stringWithFormat:@"Fixture Episode %ld", (long)index] forKey:@"title"];
                        [episode setValue:[NSDate dateWithTimeIntervalSince1970:1700000000 + index * 1000] forKey:@"pubDate"];
                        [episode setValue:@300 forKey:@"duration"];
                        [episode setValue:@NO forKey:@"consumed"];
                        [episode setValue:feed forKey:@"feed"];
                        id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                        [medium setValue:episode forKey:@"episode"];
                        [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                        [medium setValue:@"audio/wav" forKey:@"mimeType"];
                        [episodes addObject:episode];
                    }
                    for (NSString *name in @[@"Shortcuts Test List", @"Shortcuts Empty List"]) {
                        BOOL empty = [name containsString:@"Empty"];
                        id list = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:context];
                        [list setValue:name forKey:@"name"];
                        [list setValue:empty ? @"shortcuts.empty" : @"shortcuts.list" forKey:@"uid"];
                        [list setValue:@"pubDate" forKey:@"orderBy"];
                        [list setValue:@NO forKey:@"descending"];
                        [list setValue:@YES forKey:@"continuousPlayback"];
                        if (empty) [list setValue:@"zzzzshortcutsnomatchzzzz" forKey:@"query"];
                        else [list setValue:[NSSet setWithArray:episodes] forKey:@"episodes"];
                        [database addList:list];
                    }
                    [database save];
                } else if ([request[@"action"] isEqual:@"seek"]) {
                    [player seekToTime:[request[@"seconds"] doubleValue]];
                } else if ([request[@"action"] isEqual:@"clear"]) {
                    [session clear];
                }
                id episode = [player valueForKey:@"playingEpisode"];
                NSDictionary *state = @{
                    @"episode": [episode valueForKey:@"objectHash"] ?: @"",
                    @"time": [player valueForKey:@"time"], @"ready": [player valueForKey:@"ready"],
                    @"paused": [player valueForKey:@"paused"],
                    @"sourceList": [session valueForKey:@"sourceEpisodeListUID"] ?: @"",
                    @"timer": [session sleepTimerDiagnosticsMetadata],
                    @"automatic": @([NSUserDefaults.standardUserDefaults boolForKey:@"ScreenTimerAlwaysActive"]),
                    @"smart": @([NSUserDefaults.standardUserDefaults boolForKey:@"IntelligentSleepTimerAlwaysActive"])
                };
                NSDictionary *reply = @{@"id":lastID, @"state":state};
                [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                    writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
            } @catch (NSException *exception) {
                NSDictionary *reply = @{@"id":lastID, @"error":exception.reason ?: exception.name};
                [[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil]
                    writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
            }
        }];
    });
}
@end
