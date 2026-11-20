// Test driver injected into the real app for Tools/silence_trim_simulator_test.py.
// It only calls production entry points (Core Data model, CacheManager, AudioSession,
// PlaybackManager, PlaybackViewController, the menu's storage helper) and reports state.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreData/CoreData.h>
#import <MediaPlayer/MediaPlayer.h>
#import "PlaybackManager.h"
#import "PlaybackViewController.h"
@class CDEpisodeList;
#import "AudioSession.h"
#import "InstacastBackupImporter.h"
#import "InstacastBackupParser.h"

@interface NSObject (ICSilenceTrimProbeAPI)
- (id)newExportBackgroundContext;
- (NSURL*)createEverythingBackupWithContext:(NSManagedObjectContext*)context cachedEpisodeHashes:(NSSet*)hashes upNextSnapshots:(NSArray*)upNext nowPlayingSnapshot:(NSDictionary*)nowPlaying credentialValues:(NSDictionary*)credentials alternateIconName:(NSString*)icon deviceName:(NSString*)device error:(NSError**)error;
- (void)removeCacheForEpisode:(id)episode automatic:(BOOL)automatic;
- (id)propertyForKey:(NSString*)key insertOnDemand:(BOOL)insert;
+ (id)feedSettingsViewControllerWithFeed:(id)feed;
+ (id)viewController;
+ (id)sharedDatabaseManager;
+ (id)sharedCacheManager;
+ (id)shared;
- (BOOL)cacheEpisode:(id)episode overwriteCellularLock:(BOOL)overwrite;
- (BOOL)episodeIsCached:(id)episode;
- (double)cacheProgressForEpisode:(id)episode;
- (NSArray*)crashLogMailAttachments;
- (void)reconstructObjectHash;
- (void)setInteger:(NSInteger)value forKey:(NSString*)key;
- (void)resetValueForKey:(NSString*)key;
- (void)save;
@end

static UIView* ICFindView(UIView* view, Class cls) {
    if ([view isKindOfClass:cls]) return view;
    for (UIView* sub in view.subviews) {
        UIView* found = ICFindView(sub, cls);
        if (found) return found;
    }
    return nil;
}

@interface ICSilenceTrimProbe : NSObject @end
@implementation ICSilenceTrimProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"SilenceTrimProbe"];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary<NSString*, NSManagedObject*> *episodes = [NSMutableDictionary dictionary];
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            NSString *path = [directory stringByAppendingPathComponent:@"command.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data || ![(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            PlaybackManager *manager = [NSClassFromString(@"PlaybackManager") playbackManager];
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            id cacheManager = [NSClassFromString(@"CacheManager") sharedCacheManager];
            NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:command[@"id"] forKey:@"id"];
            static NSManagedObject *lastSeeded;
            NSManagedObject *episode = command[@"name"] ? episodes[command[@"name"]] : ((NSManagedObject*)manager.playingEpisode ?: lastSeeded);
            @try {
                NSString *action = command[@"action"];
                if ([action isEqual:@"seed"]) {
                    NSManagedObjectContext *context = [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] valueForKey:@"objectContext"];
                    NSManagedObject *feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:command[@"feedTitle"] forKey:@"title"];
                    if ([command[@"subscribed"] boolValue]) [feed setValue:@YES forKey:@"subscribed"];
                    [feed setValue:[NSURL URLWithString:[NSString stringWithFormat:@"https://example.invalid/%@.xml", NSUUID.UUID.UUIDString]] forKey:@"sourceURL"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:feed forKey:@"feed"];
                    [episode setValue:command[@"title"] forKey:@"title"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@([command[@"duration"] intValue]) forKey:@"duration"];
                    // The model default is consumed = YES; the feed parser sets NO for new episodes.
                    [episode setValue:@NO forKey:@"consumed"];
                    [episode reconstructObjectHash];
                    NSManagedObject *medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL URLWithString:command[@"url"]] forKey:@"fileURL"];
                    [medium setValue:command[@"mime"] ?: @"audio/mpeg" forKey:@"mimeType"];
                    [medium setValue:@([command[@"byteSize"] longLongValue]) forKey:@"byteSize"];
                    NSError *error;
                    if (![context save:&error]) @throw [NSException exceptionWithName:@"FixtureSave" reason:error.description userInfo:nil];
                    episodes[command[@"name"]] = episode;
                    lastSeeded = episode;
                } else if ([action isEqual:@"cache"]) {
                    reply[@"started"] = @([cacheManager cacheEpisode:episode overwriteCellularLock:YES]);
                } else if ([action isEqual:@"present"]) {
                    UIViewController *root = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    [episode setValue:@([command[@"at"] intValue]) forKey:@"position"];
                    if (!root.presentedViewController) {
                        PlaybackViewController *controller = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:(id)episode];
                        [controller presentFromParentViewController:root autostart:[command[@"autostart"] boolValue] completion:nil];
                    } else {
                        [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:(id)episode
                            queueUpCurrent:NO at:[command[@"at"] doubleValue] autostart:[command[@"autostart"] boolValue]];
                    }
                } else if ([action isEqual:@"dismissPlayer"]) {
                    UIViewController *root = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    [root dismissViewControllerAnimated:NO completion:nil];
                } else if ([action isEqual:@"play"]) [manager play];
                else if ([action isEqual:@"pause"]) [manager pause];
                else if ([action isEqual:@"close"]) [manager close];
                else if ([action isEqual:@"seek"]) [manager seekToTime:[command[@"time"] doubleValue]];
                else if ([action isEqual:@"speed"]) manager.speedControl = [command[@"control"] integerValue];
                else if ([action isEqual:@"defaults"]) {
                    for (NSString *key in command[@"values"]) [defaults setObject:command[@"values"][key] forKey:key];
                } else if ([action isEqual:@"settings"]) {
                    if (command[@"enabled"]) [defaults setBool:[command[@"enabled"] boolValue] forKey:@"PlayerSilenceTrimEnabled"];
                    if (command[@"level"]) [defaults setInteger:[command[@"level"] integerValue] forKey:@"PlayerSilenceTrimLevel"];
                    [manager silenceTrimSettingsDidChange];
                } else if ([action isEqual:@"feedLevel"]) {
                    id feed = [episode valueForKey:@"feed"];
                    if ([command[@"level"] isKindOfClass:NSNumber.class]) [feed setInteger:[command[@"level"] integerValue] forKey:@"PlayerSilenceTrimLevel"];
                    else [feed resetValueForKey:@"PlayerSilenceTrimLevel"];
                    [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] save];
                    [manager silenceTrimSettingsDidChange];
                } else if ([action isEqual:@"menuLevel"]) {
                    // Exactly what the speed menu's action does.
                    [(Class)NSClassFromString(@"PlaybackManager") storeSilenceTrimLevel:[command[@"level"] integerValue] forFeed:(id)[(NSObject*)manager.playingEpisode valueForKey:@"feed"]];
                    [manager silenceTrimSettingsDidChange];
                } else if ([action isEqual:@"interruption"]) {
                    BOOL began = [command[@"type"] isEqual:@"began"];
                    NSDictionary *info = began
                        ? @{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)}
                        : @{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeEnded),
                            AVAudioSessionInterruptionOptionKey: @(AVAudioSessionInterruptionOptionShouldResume)};
                    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance] userInfo:info];
                } else if ([action isEqual:@"showSettings"]) {
                    // Real settings screens, presented in a navigation controller for screenshots.
                    UIViewController *top = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    while (top.presentedViewController) top = top.presentedViewController;
                    UIViewController *settings = [command[@"screen"] isEqual:@"feed"]
                        ? [NSClassFromString(@"FeedSettingsViewController") feedSettingsViewControllerWithFeed:[episode valueForKey:@"feed"]]
                        : [NSClassFromString(@"PlaybackSettingsViewController") viewController];
                    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
                    [top presentViewController:navigation animated:NO completion:nil];
                } else if ([action isEqual:@"dismissTop"]) {
                    UIViewController *top = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    while (top.presentedViewController.presentedViewController) top = top.presentedViewController;
                    [top dismissViewControllerAnimated:NO completion:nil];
                } else if ([action isEqual:@"feedLevelRaw"]) {
                    // What a remote feed-property apply does: write the property and save, nothing else.
                    id feed = [episode valueForKey:@"feed"];
                    if ([command[@"level"] isKindOfClass:NSNumber.class]) [feed setInteger:[command[@"level"] integerValue] forKey:@"PlayerSilenceTrimLevel"];
                    else [feed resetValueForKey:@"PlayerSilenceTrimLevel"];
                    [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] save];
                } else if ([action isEqual:@"removeCache"]) {
                    [cacheManager removeCacheForEpisode:episode automatic:NO];
                } else if ([action isEqual:@"exportBackup"]) {
                    // The app's own full-backup generator on its export context.
                    id exporter = [NSClassFromString(@"ImportExportSettingsViewController") viewController];
                    NSManagedObjectContext *context = [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] newExportBackgroundContext];
                    __block NSURL *url = nil;
                    __block NSError *error = nil;
                    [context performBlockAndWait:^{
                        [context setQueryGenerationFromToken:[NSQueryGenerationToken currentQueryGenerationToken] error:nil];
                        url = [exporter createEverythingBackupWithContext:context cachedEpisodeHashes:[NSSet set] upNextSnapshots:@[] nowPlayingSnapshot:nil
                                                         credentialValues:@{} alternateIconName:nil deviceName:@"E2E" error:&error];
                    }];
                    if (!url) @throw [NSException exceptionWithName:@"BackupExport" reason:error.description ?: @"no url" userInfo:nil];
                    NSString *target = [directory stringByAppendingPathComponent:@"backup.xml"];
                    [[NSFileManager defaultManager] removeItemAtPath:target error:nil];
                    [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:target error:nil];
                    reply[@"backupPath"] = target;
                } else if ([action isEqual:@"importBackup"]) {
                    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"backup.xml"]];
                    NSString *done = [directory stringByAppendingPathComponent:@"import-done.json"];
                    [[NSFileManager defaultManager] removeItemAtPath:done error:nil];
                    NSUInteger categories = [command[@"categories"] unsignedIntegerValue];
                    [(Class)NSClassFromString(@"InstacastBackupParser") parseData:data completion:^(InstacastBackupData *backup, NSError *parseError) {
                        if (!backup) {
                            [[NSJSONSerialization dataWithJSONObject:@{@"error": parseError.description ?: @"parse"} options:0 error:nil] writeToFile:done atomically:YES];
                            return;
                        }
                        ICBackupImportCallbacks callbacks = {0};
                        [(Class)NSClassFromString(@"InstacastBackupImporter") importBackup:backup categories:categories callbacks:callbacks
                                                                         completion:^(NSInteger imported, NSInteger queued, NSError *importError) {
                            [[NSJSONSerialization dataWithJSONObject:@{@"imported": @(imported), @"error": importError.description ?: @""} options:0 error:nil] writeToFile:done atomically:YES];
                        }];
                    }];
                } else if ([action isEqual:@"exportLogs"]) {
                    Class loggerClass = NSClassFromString(@"ICDiagnosticLogger") ?: NSClassFromString(@"InstacastPlus.ICDiagnosticLogger");
                    NSArray *attachments = [[loggerClass shared] crashLogMailAttachments];
                    NSData *export = [attachments.firstObject valueForKey:@"data"];
                    [export writeToFile:[directory stringByAppendingPathComponent:@"export.txt"] atomically:YES];
                }

                id trim = [manager valueForKey:@"silenceTrimPlayer"];
                AVPlayer *player = [manager valueForKey:@"player"];
                reply[@"engine"] = trim ? @"silence-trim" : (player ? @"avplayer" : @"none");
                reply[@"ready"] = @(manager.ready);
                reply[@"paused"] = @(manager.paused);
                reply[@"playing"] = @(manager.isPodcastPlaying);
                reply[@"state"] = [manager valueForKey:@"state"];
                reply[@"time"] = @(manager.time);
                reply[@"duration"] = @(manager.duration);
                reply[@"speedControl"] = @(manager.speedControl);
                reply[@"avplayerRate"] = @(player.rate);
                reply[@"assetURL"] = [[manager valueForKey:@"mediaAsset"] valueForKeyPath:@"URL.absoluteString"] ?: @"";
                reply[@"error"] = manager.playbackError.localizedDescription ?: @"";
                if (trim) {
                    reply[@"trimTime"] = [trim valueForKey:@"currentTime"];
                    reply[@"trimSaved"] = [trim valueForKey:@"savedSeconds"];
                    reply[@"trimFactor"] = [trim valueForKey:@"pauseSpeedupFactor"];
                    reply[@"trimLevel"] = [trim valueForKey:@"level"];
                    reply[@"trimRequestedRate"] = [trim valueForKey:@"requestedRate"];
                    reply[@"trimRate"] = [trim valueForKey:@"rate"];
                    reply[@"trimVolume"] = [trim valueForKey:@"volume"];
                }
                id playing = manager.playingEpisode;
                if (playing) {
                    reply[@"levelForEpisode"] = @([manager silenceTrimLevelForEpisode:playing]);
                    reply[@"statusText"] = [manager silenceTrimStatusText] ?: @"";
                }
                if (episode) {
                    reply[@"episodeHash"] = [episode valueForKey:@"objectHash"] ?: @"";
                    reply[@"episodePosition"] = [episode valueForKey:@"position"] ?: @0;
                    reply[@"episodeDuration"] = [episode valueForKey:@"duration"] ?: @0;
                    reply[@"episodeConsumed"] = [episode valueForKey:@"consumed"] ?: @NO;
                    reply[@"cached"] = @([cacheManager episodeIsCached:episode]);
                    reply[@"cacheProgress"] = @([cacheManager cacheProgressForEpisode:episode]);
                    reply[@"feedURL"] = [episode valueForKeyPath:@"feed.sourceURL.absoluteString"] ?: @"";
                }
                NSDictionary *nowPlaying = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
                reply[@"nowPlayingElapsed"] = nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?: @(-1);
                reply[@"nowPlayingRate"] = nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] ?: @(-1);
                UIWindow *window = UIApplication.sharedApplication.connectedScenes.allObjects.firstObject
                    ? [[(UIWindowScene*)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject windows] firstObject] : nil;
                UIButton *speedButton = (UIButton*)ICFindView(window, NSClassFromString(@"PlayerSpeedButton"));
                NSMutableArray *presented = [NSMutableArray array];
                UIViewController *presenter = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                while (presenter.presentedViewController) {
                    presenter = presenter.presentedViewController;
                    UIViewController *shown = [presenter isKindOfClass:UINavigationController.class] ? [(UINavigationController*)presenter viewControllers].firstObject : presenter;
                    [presented addObject:NSStringFromClass(shown.class) ?: @""];
                }
                reply[@"presented"] = presented;
                reply[@"speedButtonFound"] = @(speedButton != nil);
                reply[@"speedButtonMenu"] = @(speedButton.menu != nil);
                reply[@"speedButtonMenuPrimary"] = @(speedButton.showsMenuAsPrimaryAction);
                reply[@"defaultsEnabled"] = @([defaults boolForKey:@"PlayerSilenceTrimEnabled"]);
                reply[@"defaultsLevel"] = @([defaults integerForKey:@"PlayerSilenceTrimLevel"]);
                id playingFeed = [(NSObject*)episode valueForKey:@"feed"];
                id feedProperty = [playingFeed respondsToSelector:@selector(propertyForKey:insertOnDemand:)] ? [playingFeed propertyForKey:@"PlayerSilenceTrimLevel" insertOnDemand:NO] : nil;
                reply[@"feedOverride"] = feedProperty ? [feedProperty valueForKey:@"int32Value"] : [NSNull null];
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
