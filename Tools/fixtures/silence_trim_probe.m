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

@interface NSObject (ICSilenceTrimProbeAPI)
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
                    [feed setValue:[NSURL URLWithString:[NSString stringWithFormat:@"https://example.invalid/%@.xml", NSUUID.UUID.UUIDString]] forKey:@"sourceURL"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:feed forKey:@"feed"];
                    [episode setValue:command[@"title"] forKey:@"title"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@([command[@"duration"] intValue]) forKey:@"duration"];
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
                }
                NSDictionary *nowPlaying = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
                reply[@"nowPlayingElapsed"] = nowPlaying[MPNowPlayingInfoPropertyElapsedPlaybackTime] ?: @(-1);
                reply[@"nowPlayingRate"] = nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] ?: @(-1);
                UIWindow *window = UIApplication.sharedApplication.connectedScenes.allObjects.firstObject
                    ? [[(UIWindowScene*)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject windows] firstObject] : nil;
                UIButton *speedButton = (UIButton*)ICFindView(window, NSClassFromString(@"PlayerSpeedButton"));
                reply[@"speedButtonFound"] = @(speedButton != nil);
                reply[@"speedButtonMenu"] = @(speedButton.menu != nil);
                reply[@"speedButtonMenuPrimary"] = @(speedButton.showsMenuAsPrimaryAction);
                reply[@"defaultsEnabled"] = @([defaults boolForKey:@"PlayerSilenceTrimEnabled"]);
                reply[@"defaultsLevel"] = @([defaults integerForKey:@"PlayerSilenceTrimLevel"]);
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
