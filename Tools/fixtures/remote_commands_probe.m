// Real app/Core Data/mini-player driver. Only the MediaPlayer service boundary is
// instrumented: original methods still run; an optional one-shot service stall
// makes the 1.09 s delay in the device report repeatable on the simulator.
#import <UIKit/UIKit.h>
#import <CoreData/CoreData.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <dlfcn.h>

@interface NSObject (RemoteProbeAPI)
+ (id)sharedDatabaseManager;
+ (id)sharedAudioSession;
+ (id)playbackManager;
- (void)save;
- (void)close;
- (void)reconstructObjectHash;
- (void)setInteger:(NSInteger)value forKey:(NSString*)key;
- (void)_setupRemotePlaybackCenterWithEpisode:(id)episode;
@end

static NSString *directory;
static id episode;
static NSMutableArray *serviceCalls;
static atomic_bool stallNext;
static NSUInteger playbackStateWrites;
static double actionMs;
static _Thread_local BOOL inspectingCenter;
static atomic_bool auditTransport;
static NSArray<MPRemoteCommand*>* transportCommands;
static NSMutableArray* transportLosses;
static BOOL remoteSendResult;

static void recordTransportLoss(MPRemoteCommand* command, NSString* operation) {
    if (!atomic_load(&auditTransport)) return;
    NSUInteger index = [transportCommands indexOfObjectIdenticalTo:command];
    if (index == NSNotFound) return;
    @synchronized(transportLosses) {
        [transportLosses addObject:@{@"command": @[@"play", @"pause", @"toggle"][index],
                                    @"operation": operation}];
    }
}

static UIViewController *root(void) {
    return [(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
}
static id manager(void) { return [NSClassFromString(@"PlaybackManager") playbackManager]; }
static void observe(NSString *operation, double start) {
    @synchronized(serviceCalls) {
        [serviceCalls addObject:@{@"operation":operation, @"main":@(NSThread.isMainThread),
            @"durationMs":@((CACurrentMediaTime()-start)*1000)}];
    }
}
static NSDictionary *snapshot(void) {
    NSArray *calls;
    @synchronized(serviceCalls) { calls = serviceCalls.copy; }
    NSArray *losses;
    @synchronized(transportLosses) { losses = transportLosses.copy; }
    inspectingCenter = YES;
    MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
    inspectingCenter = NO;
    return @{@"actionMs":@(actionMs), @"serviceCalls":calls, @"transportLosses": losses,
        @"remoteSendResult": @(remoteSendResult),
        @"playbackStateWrites":@(playbackStateWrites),
        @"presented":@(root().presentedViewController != nil),
        @"ready":[manager() valueForKey:@"ready"], @"paused":[manager() valueForKey:@"paused"],
        @"playEnabled":@(center.playCommand.enabled), @"pauseEnabled":@(center.pauseCommand.enabled),
        @"skipEnabled":@(center.skipForwardCommand.enabled), @"seekEnabled":@(center.seekForwardCommand.enabled),
        @"intervals":center.skipForwardCommand.preferredIntervals ?: @[]};
}

@interface ICRemoteCommandsProbe : NSObject @end
@implementation ICRemoteCommandsProbe
+ (void)load {
    serviceCalls = [NSMutableArray array];
    transportLosses = [NSMutableArray array];
    Method enabled = class_getInstanceMethod(MPRemoteCommand.class, @selector(setEnabled:));
    void (*originalEnabled)(id,SEL,BOOL) = (void*)method_getImplementation(enabled);
    method_setImplementation(enabled, imp_implementationWithBlock(^(MPRemoteCommand* command, BOOL value) {
        originalEnabled(command, @selector(setEnabled:), value);
        if (!value) recordTransportLoss(command, @"disabled");
    }));
    Method remove = class_getInstanceMethod(MPRemoteCommand.class, @selector(removeTarget:));
    void (*originalRemove)(id,SEL,id) = (void*)method_getImplementation(remove);
    method_setImplementation(remove, imp_implementationWithBlock(^(MPRemoteCommand* command, id target) {
        originalRemove(command, @selector(removeTarget:), target);
        recordTransportLoss(command, @"handler-removed");
    }));
    Method removeAction = class_getInstanceMethod(MPRemoteCommand.class, @selector(removeTarget:action:));
    void (*originalRemoveAction)(id,SEL,id,SEL) = (void*)method_getImplementation(removeAction);
    method_setImplementation(removeAction, imp_implementationWithBlock(^(MPRemoteCommand* command, id target, SEL action) {
        originalRemoveAction(command, @selector(removeTarget:action:), target, action);
        recordTransportLoss(command, @"handler-action-removed");
    }));
    Method shared = class_getClassMethod(MPRemoteCommandCenter.class, @selector(sharedCommandCenter));
    id (*originalShared)(id,SEL) = (void*)method_getImplementation(shared);
    method_setImplementation(shared, imp_implementationWithBlock(^id(id cls) {
        double start = CACurrentMediaTime();
        BOOL stall = !inspectingCenter && atomic_exchange(&stallNext, false);
        if (stall) [NSThread sleepForTimeInterval:1.1]; // Test fixture, never production.
        id result = originalShared(cls, @selector(sharedCommandCenter));
        // Ignore observation reads from snapshot; capture only the production caller.
        if (stall) observe(@"command-center-service", start);
        return result;
    }));
    Method state = class_getInstanceMethod(MPNowPlayingInfoCenter.class, @selector(setPlaybackState:));
    void (*originalState)(id,SEL,MPNowPlayingPlaybackState) = (void*)method_getImplementation(state);
    method_setImplementation(state, imp_implementationWithBlock(^(id center, MPNowPlayingPlaybackState value) {
        playbackStateWrites++;
        originalState(center, @selector(setPlaybackState:), value);
    }));
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onboard_will_show"];
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"RemoteCommandsProbe"];
        __block NSString *lastID;
        [NSTimer scheduledTimerWithTimeInterval:.05 repeats:YES block:^(NSTimer *timer) {
            if (!root()) return;
            NSDictionary *request = [NSJSONSerialization JSONObjectWithData:
                [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]] ?: NSData.data options:0 error:nil];
            if (!request || [lastID isEqual:request[@"id"]]) return;
            lastID = request[@"id"];
            NSMutableDictionary *reply = [@{@"id":lastID} mutableCopy];
            @try {
                NSString *action = request[@"action"];
                if ([action isEqual:@"seed"]) {
                    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                    [defaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                    [defaults setBool:NO forKey:@"ScreenTimerAlwaysActive"];
                    [defaults setBool:NO forKey:@"PlayerSilenceTrimEnabled"];
                    id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
                    NSManagedObjectContext *context = [database valueForKey:@"objectContext"];
                    id feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Remote command regression" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/remote.xml"] forKey:@"sourceURL"];
                    [feed setValue:@YES forKey:@"subscribed"];
                    [feed setInteger:2 forKey:@"PlayerControls"];
                    [feed setInteger:45 forKey:@"PlayerSkipForwardPeriod"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:feed forKey:@"feed"];
                    [episode setValue:@"Cold mini-player fixture" forKey:@"title"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@180 forKey:@"duration"];
                    [episode reconstructObjectHash];
                    id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    [database save];
                    // Same canonical persisted state that AudioSession restores on launch.
                    [defaults setObject:[episode valueForKey:@"objectHash"] forKey:@"PlaybackEpisode"];
                } else if ([action isEqual:@"tap"]) {
                    atomic_store(&stallNext, [request[@"stall"] boolValue]);
                    UIControl *control = [[root() valueForKey:@"activityViewController"] valueForKey:@"nowPlayingControl"];
                    double start = CACurrentMediaTime();
                    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
                    actionMs = (CACurrentMediaTime()-start)*1000;
                } else if ([action isEqual:@"configure"]) {
                    id selected = [manager() valueForKey:@"playingEpisode"];
                    [[selected valueForKey:@"feed"] setInteger:[request[@"mode"] integerValue] forKey:@"PlayerControls"];
                    atomic_store(&stallNext, [request[@"stall"] boolValue]);
                    [manager() _setupRemotePlaybackCenterWithEpisode:selected];
                } else if ([action isEqual:@"auditTransport"]) {
                    MPRemoteCommandCenter* center = MPRemoteCommandCenter.sharedCommandCenter;
                    transportCommands = @[center.playCommand, center.pauseCommand, center.togglePlayPauseCommand];
                    @synchronized(transportLosses) { [transportLosses removeAllObjects]; }
                    atomic_store(&auditTransport, true);
                } else if ([action isEqual:@"remote"]) {
                    // Route through the real system media service, not the app's handler.
                    void* framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
                    BOOL (*send)(unsigned int, CFDictionaryRef) = dlsym(framework, "MRMediaRemoteSendCommand");
                    if (!send) @throw [NSException exceptionWithName:@"MissingMediaRemote" reason:@"System command API unavailable" userInfo:nil];
                    remoteSendResult = send([request[@"command"] unsignedIntValue], NULL);
                } else if ([action isEqual:@"close"]) [manager() close];
                reply[@"state"] = snapshot();
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
