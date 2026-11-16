// Seeds the real app store before the UI test.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>

@interface NSObject (MarkUnplayedFixture)
+ (id)sharedDatabaseManager;
- (void)save;
@end

static void SeedEpisodes(NSTimer *timer)
{
    id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
    NSManagedObjectContext *context = [database valueForKey:@"objectContext"];
    if (!context.persistentStoreCoordinator.persistentStores.count) return;

    [timer invalidate];
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
    request.predicate = [NSPredicate predicateWithFormat:@"guid == %@", @"mark-unplayed-test-1"];
    if ([context countForFetchRequest:request error:NULL] != 0) return;

    NSManagedObject *feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
    [feed setValue:@"Mark Unplayed Fixture" forKey:@"title"];
    [feed setValue:[NSURL URLWithString:@"https://example.invalid/mark-unplayed.xml"] forKey:@"sourceURL"];
    [feed setValue:@YES forKey:@"subscribed"];
    for (NSInteger index = 1; index <= 3; index++) {
        NSManagedObject *episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
        NSString *guid = [NSString stringWithFormat:@"mark-unplayed-test-%ld", (long)index];
        [episode setValue:guid forKey:@"guid"];
        [episode setValue:guid forKey:@"objectHash"];
        [episode setValue:[NSString stringWithFormat:@"Testfolge %ld", (long)index] forKey:@"title"];
        [episode setValue:[NSDate dateWithTimeIntervalSinceNow:-index * 60] forKey:@"pubDate"];
        [episode setValue:[NSDate dateWithTimeIntervalSinceNow:-index * 60] forKey:@"lastPlayed"];
        [episode setValue:@180 forKey:@"duration"];
        [episode setValue:@NO forKey:@"consumed"];
        [episode setValue:@(index * 30) forKey:@"position"];
        [episode setValue:feed forKey:@"feed"];
    }
    [database save];
    [NSUserDefaults.standardUserDefaults setObject:@{
        @"mark-unplayed-test-1": @31,
        @"mark-unplayed-test-2": @62,
        @"mark-unplayed-test-3": @93,
    } forKey:@"TemporaryPlaybackPositions"];
}

__attribute__((constructor))
static void InstallFixture(void)
{
    if (getenv("IC_TEST_BYPASS_SIMULATOR_PUSH")) {
        // The simulator's push service can leave UIKit's synchronous query blocked.
        // Keep that service out of this local list test when explicitly requested.
        Class application = UIApplication.class;
        SEL query = @selector(isRegisteredForRemoteNotifications);
        SEL registration = @selector(registerForRemoteNotifications);
        method_setImplementation(class_getInstanceMethod(application, query),
            imp_implementationWithBlock(^BOOL(__unused UIApplication *app) { return NO; }));
        method_setImplementation(class_getInstanceMethod(application, registration),
            imp_implementationWithBlock(^(__unused UIApplication *app) {}));
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
            SeedEpisodes(timer);
        }];
    });
}
