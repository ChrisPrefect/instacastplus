// Real-app refresh driver and timing observations. Original methods always run.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface NSObject (RefreshProbeAPI)
+ (id)sharedDatabaseManager;
+ (id)sharedSubscriptionManager;
- (BOOL)_selectMainSidebarListWithUID:(NSString*)uid;
@end
static NSString *directory;
static NSMutableArray *timings, *frames;
static BOOL recording;
static double handlerMs;
static NSUInteger finished;
static double lastHeartbeat, maximumHeartbeatGap;
static NSDictionary *pendingChanges;
static NSUInteger redundantEpisodeUpdates, persistentEpisodeUpdates;
static NSArray *playbackRow(NSManagedObject *episode) {
    NSDate *date=[episode valueForKey:@"lastPlayed"];
    return @[[episode valueForKey:@"objectHash"], [episode valueForKey:@"consumed"],
        [episode valueForKey:@"starred"], [episode valueForKey:@"position"],
        date ? @(date.timeIntervalSinceReferenceDate) : NSNull.null];
}
static UIViewController *root(void) { return [(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]; }
static UIViewController *list(UIViewController *parent) {
    if ([parent isKindOfClass:NSClassFromString(@"ListEpisodesTableViewController")]) return parent;
    for (UIViewController *child in parent.childViewControllers) { UIViewController *found=list(child); if (found) return found; }
    return nil;
}
@interface ICRefreshResponsivenessProbe : NSObject @end
@implementation ICRefreshResponsivenessProbe
- (void)frame:(CADisplayLink*)link { if (recording) [frames addObject:@(CACurrentMediaTime())]; }
+ (void)load {
    timings=[NSMutableArray array]; frames=[NSMutableArray array];
    Method fetch=class_getInstanceMethod(NSManagedObjectContext.class,@selector(executeFetchRequest:error:));
    id (*original)(id,SEL,NSFetchRequest*,NSError**)= (void*)method_getImplementation(fetch);
    method_setImplementation(fetch,imp_implementationWithBlock(^id(NSManagedObjectContext *context, NSFetchRequest *request, NSError **error) {
        // Stage real unsaved edits and a permanent-ID insertion immediately before
        // the first fault-prefetch. This tests Core Data's pending-state contract.
        if (recording && !pendingChanges && NSThread.isMainThread &&
            [NSUserDefaults.standardUserDefaults boolForKey:@"RefreshProbePendingChanges"] &&
            [request.predicate isKindOfClass:NSComparisonPredicate.class]) {
            NSComparisonPredicate *predicate=(id)request.predicate;
            id ids=predicate.rightExpression.constantValue;
            if (predicate.predicateOperatorType==NSInPredicateOperatorType &&
                predicate.leftExpression.expressionType==NSEvaluatedObjectExpressionType && [ids count]>0) {
                NSManagedObjectID *identity=[ids isKindOfClass:NSSet.class] ? [(NSSet*)ids anyObject] : [(NSArray*)ids firstObject];
                NSManagedObject *edited=[context objectWithID:identity];
                [edited setValue:@(![[edited valueForKey:@"starred"] boolValue]) forKey:@"starred"];
                [edited setValue:@([[edited valueForKey:@"position"] intValue]+17) forKey:@"position"];
                NSManagedObject *inserted=[NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                [inserted setValue:[edited valueForKey:@"feed"] forKey:@"feed"];
                [inserted setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                [inserted setValue:NSUUID.UUID.UUIDString forKey:@"objectHash"];
                [inserted setValue:@"Pending refresh fixture" forKey:@"title"];
                [inserted setValue:[NSDate dateWithTimeIntervalSince1970:1000] forKey:@"pubDate"];
                [inserted setValue:@120 forKey:@"duration"];
                [context obtainPermanentIDsForObjects:@[inserted] error:nil];
                pendingChanges=@{@"edited":playbackRow(edited),@"inserted":playbackRow(inserted),
                    @"wasUnsaved":@(edited.hasChanges && inserted.isInserted && !inserted.objectID.isTemporaryID)};
            }
        }
        double start=CACurrentMediaTime();
        id result=original(context,@selector(executeFetchRequest:error:),request,error);
        double duration=(CACurrentMediaTime()-start)*1000;
        if (recording && duration>20) @synchronized(timings) {
            [timings addObject:@{@"entity":request.entityName ?: @"",@"durationMs":@(duration),
                @"main":@(NSThread.isMainThread),@"count":@([result count]),@"stack":NSThread.callStackSymbols}];
        }
        return result;
    }));
    Method save=class_getInstanceMethod(NSManagedObjectContext.class,@selector(save:));
    BOOL (*originalSave)(id,SEL,NSError**)=(void*)method_getImplementation(save);
    method_setImplementation(save,imp_implementationWithBlock(^BOOL(id context,NSError **error) {
        double start=CACurrentMediaTime();
        BOOL success=originalSave(context,@selector(save:),error);
        double duration=(CACurrentMediaTime()-start)*1000;
        if (recording && duration>20) @synchronized(timings) {
            [timings addObject:@{@"operation":@"save",@"durationMs":@(duration),
                @"main":@(NSThread.isMainThread),@"stack":NSThread.callStackSymbols}];
        }
        return success;
    }));
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:@"onboard_will_show"];
    [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:@"LastRefreshSubscriptionDate"];
    [defaults setBool:NO forKey:@"AutoCacheNewAudioEpisodes"];
    [defaults setBool:NO forKey:@"AutoCacheNewVideoEpisodes"];
    dispatch_async(dispatch_get_main_queue(), ^{
        directory=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"RefreshResponsivenessProbe"];
        ICRefreshResponsivenessProbe *probe=[ICRefreshResponsivenessProbe new];
        NSTimer *heartbeat=[NSTimer timerWithTimeInterval:.01 repeats:YES block:^(NSTimer *timer) {
            double now=CACurrentMediaTime();
            if (recording) maximumHeartbeatGap=MAX(maximumHeartbeatGap,(now-lastHeartbeat)*1000);
            lastHeartbeat=now;
        }];
        [NSRunLoop.mainRunLoop addTimer:heartbeat forMode:NSRunLoopCommonModes];
        CADisplayLink *display=[CADisplayLink displayLinkWithTarget:probe selector:@selector(frame:)];
        [display addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [NSNotificationCenter.defaultCenter addObserverForName:@"SubscriptionManagerDidFinishRefreshingFeedsNotification" object:nil queue:nil usingBlock:^(NSNotification *note){ finished++; }];
        [NSNotificationCenter.defaultCenter addObserverForName:NSManagedObjectContextWillSaveNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            if (!recording || !NSThread.isMainThread) return;
            NSManagedObjectContext *context=note.object;
            for (NSManagedObject *object in context.updatedObjects) {
                if (![object.entity.name isEqual:@"Episode"]) continue;
                if (object.hasPersistentChangedValues) persistentEpisodeUpdates++;
                else redundantEpisodeUpdates++;
            }
        }];
        __block NSString *lastID;
        NSTimer *poll=[NSTimer timerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer){
            if (!root()) return;
            NSDictionary *request=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]] ?: NSData.data options:0 error:nil];
            if (!request || [lastID isEqual:request[@"id"]]) return;
            lastID=request[@"id"];
            NSMutableDictionary *reply=[@{@"id":lastID} mutableCopy];
            @try {
                NSString *action=request[@"action"];
                if ([action isEqual:@"open"]) [root() _selectMainSidebarListWithUID:@"default.unplayed"];
                else if ([action isEqual:@"refresh"]) {
                    [timings removeAllObjects]; [frames removeAllObjects]; recording=YES;
                    maximumHeartbeatGap=0;lastHeartbeat=CACurrentMediaTime();
                    [frames addObject:@(CACurrentMediaTime())];
                    UIRefreshControl *control=[list(root()) valueForKey:@"refreshControl"];
                    if (!control) @throw [NSException exceptionWithName:@"NoRefresh" reason:@"No visible production refresh control" userInfo:nil];
                    double start=CACurrentMediaTime();
                    [control sendActionsForControlEvents:UIControlEventValueChanged];
                    handlerMs=(CACurrentMediaTime()-start)*1000;
                } else if ([action isEqual:@"stop"]) {
                    [frames addObject:@(CACurrentMediaTime())]; recording=NO;
                    [[NSJSONSerialization dataWithJSONObject:frames options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"frames.json"] atomically:YES];
                    @synchronized(timings) { [[NSJSONSerialization dataWithJSONObject:timings options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"fetches.json"] atomically:YES]; }
                }
                double maxGap=0;
                for (NSUInteger i=1;i<frames.count;i++) maxGap=MAX(maxGap,([frames[i] doubleValue]-[frames[i-1] doubleValue])*1000);
                reply[@"handlerMs"]=@(handlerMs); reply[@"maximumFrameGapMs"]=@(maxGap);
                reply[@"maximumHeartbeatGapMs"]=@(maximumHeartbeatGap);
                reply[@"finished"]=@(finished);
                reply[@"pendingChanges"]=pendingChanges ?: @{};
                reply[@"redundantEpisodeUpdates"]=@(redundantEpisodeUpdates);
                reply[@"persistentEpisodeUpdates"]=@(persistentEpisodeUpdates);
                reply[@"expectedRequests"]=[[NSClassFromString(@"SubscriptionManager") sharedSubscriptionManager] valueForKey:@"numTotalRefreshFeeds"] ?: @0;
                reply[@"refreshing"]=[[NSClassFromString(@"SubscriptionManager") sharedSubscriptionManager] valueForKey:@"refreshing"] ?: @NO;
                reply[@"listVisible"]=@(list(root()).view.window != nil);
            } @catch(NSException *exception){reply[@"error"]=exception.description;}
            [[NSJSONSerialization dataWithJSONObject:reply options:0 error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
        [NSRunLoop.mainRunLoop addTimer:poll forMode:NSRunLoopCommonModes];
    });
}
@end
