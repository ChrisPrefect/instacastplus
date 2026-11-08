// Test driver injected into the real app. Production methods and callbacks are unchanged.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreData/CoreData.h>
#import <mach-o/dyld.h>
#import "PlaybackManager.h"
#import "PlaybackViewController.h"
@class CDEpisodeList;
#import "AudioSession.h"

@interface NSObject (ICPlaybackTransitionProbeAPI)
+ (id)sharedDatabaseManager;
+ (id)shared;
- (NSArray*)crashLogMailAttachments;
- (void)reconstructObjectHash;
@end

@interface ICPlaybackTransitionProbe : NSObject @end
@implementation ICPlaybackTransitionProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"PlaybackTransitionProbe"];
        __block NSManagedObject *episode;
        NSMutableArray *closingStacks = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserverForName:@"MPPlaybackManagerDidEndNotification" object:nil queue:nil usingBlock:^(NSNotification *notification) {
            [closingStacks addObject:@{@"timestamp":@(NSDate.date.timeIntervalSince1970),
                @"image0LoadAddress":[NSString stringWithFormat:@"%p",_dyld_get_image_header(0)],
                @"stack":NSThread.callStackSymbols}];
            [[NSJSONSerialization dataWithJSONObject:closingStacks options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"closing-stacks.json"] atomically:YES];
        }];
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            NSString *path = [directory stringByAppendingPathComponent:@"command.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data || ![(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            PlaybackManager *manager = [NSClassFromString(@"PlaybackManager") playbackManager];
            NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:command[@"id"] forKey:@"id"];
            @try {
                NSString *action = command[@"action"];
                if ([action isEqual:@"open"]) {
                    [manager close];
                    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                    [defaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                    [defaults setBool:NO forKey:@"ScreenTimerAlwaysActive"];
                    [defaults setBool:YES forKey:@"EnableStreamingOver3G"];
                    NSManagedObjectContext *context = [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] valueForKey:@"objectContext"];
                    NSManagedObject *feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Transition regression" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/state-transitions.xml"] forKey:@"sourceURL"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:feed forKey:@"feed"];
                    [episode setValue:@"Delayed audio" forKey:@"title"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@120 forKey:@"duration"];
                    [episode reconstructObjectHash];
                    NSManagedObject *medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL URLWithString:command[@"url"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    NSError *error;
                    if (![context save:&error]) @throw [NSException exceptionWithName:@"FixtureSave" reason:error.description userInfo:nil];
                    UIViewController *root = [(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
                    if (!root.presentedViewController) {
                        PlaybackViewController *controller = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:(id)episode];
                        [controller presentFromParentViewController:root autostart:[command[@"autostart"] boolValue] completion:nil];
                    } else {
                        [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:(id)episode
                            queueUpCurrent:NO at:0 autostart:[command[@"autostart"] boolValue]];
                    }
                } else if ([action isEqual:@"play"]) [manager play];
                else if ([action isEqual:@"pause"]) [manager pause];
                else if ([action isEqual:@"close"]) [manager close];
                else if ([action isEqual:@"exportLogs"]) {
                    Class loggerClass = NSClassFromString(@"ICDiagnosticLogger") ?: NSClassFromString(@"InstacastPlus.ICDiagnosticLogger");
                    NSArray *attachments = [[loggerClass shared] crashLogMailAttachments];
                    NSData *export = [attachments.firstObject valueForKey:@"data"];
                    if (!export) @throw [NSException exceptionWithName:@"MissingLogExport" reason:@"No diagnostic mail attachment returned" userInfo:nil];
                    [export writeToFile:[directory stringByAppendingPathComponent:@"export.txt"] atomically:YES];
                }
                AVPlayer *player = [manager valueForKey:@"player"];
                reply[@"ready"] = @(manager.ready);
                reply[@"failed"] = @(manager.failed);
                reply[@"paused"] = @(manager.paused);
                reply[@"waiting"] = @(manager.waitingForLoad);
                reply[@"selected"] = @(manager.playingEpisode != nil);
                reply[@"episodeHash"] = [(id)manager.playingEpisode valueForKey:@"objectHash"] ?: @"";
                reply[@"rate"] = @(player.rate);
                reply[@"volume"] = @(player.volume);
                reply[@"itemStatus"] = @(player.currentItem.status);
                reply[@"state"] = [manager valueForKey:@"state"];
                reply[@"time"] = @(manager.time);
                reply[@"error"] = manager.playbackError.localizedDescription ?: @"";
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
