// Injected into the real simulator app; does not replace production methods.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <CoreData/CoreData.h>
#import "PlaybackManager.h"
#import "PlaybackViewController.h"
@class CDEpisodeList;
#import "AudioSession.h"

@interface NSObject (ICSleepActivityProbeAPI)
+ (id)sharedDatabaseManager;
- (void)reconstructObjectHash;
@end

// Only adapter coverage uses synthetic events. The E2E uses Control Center.
@interface ICSleepProbeEvent : NSObject
@property MPSeekCommandEventType type;
@property NSTimeInterval positionTime;
@end
@implementation ICSleepProbeEvent @end

static UIButton *timerButton(UIView *view) {
    if ([view isKindOfClass:NSClassFromString(@"PlayerTimerButton")]) return (id)view;
    for (UIView *child in view.subviews) {
        UIButton *found = timerButton(child);
        if (found) return found;
    }
    return nil;
}

@interface ICSleepActivityProbe : NSObject @end
@implementation ICSleepActivityProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"SleepActivityProbe"];
        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *timer) {
            NSString *path = [directory stringByAppendingPathComponent:@"command.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            id delegate = UIApplication.sharedApplication.delegate;
            if (!data || ![delegate valueForKey:@"mainViewController"]) return;
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            PlaybackManager *manager = [NSClassFromString(@"PlaybackManager") playbackManager];
            AudioSession *session = [NSClassFromString(@"AudioSession") sharedAudioSession];
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            NSMutableDictionary *reply = [@{@"id":command[@"id"]} mutableCopy];
            @try {
                NSString *action = command[@"action"];
                if ([action isEqual:@"open"]) {
                    [defaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                    [defaults setBool:YES forKey:@"ScreenTimerAlwaysActive"];
                    [defaults setBool:YES forKey:@"IntelligentSleepTimerAlwaysActive"];
                    [defaults setBool:NO forKey:@"DeviceMovementIntelligentSleep"];
                    [defaults setBool:NO forKey:@"VolumeChangeIntelligentSleep"];
                    [defaults setBool:YES forKey:@"ScreenTouchIntelligentSleep"];
                    [defaults setInteger:30 forKey:@"DefaultIntelligentSleepTimer"];
                    [defaults setInteger:30 forKey:@"LastSelectedSleepTimer"];
                    [defaults setInteger:30 forKey:@"PlayerSkipForwardPeriod"];
                    [defaults setInteger:15 forKey:@"PlayerSkipBackPeriod"];
                    [defaults setInteger:2 forKey:@"PlayerControls"];
                    NSManagedObjectContext *context = [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] valueForKey:@"objectContext"];
                    NSManagedObject *feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Sleep activity regression" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/sleep-activity.xml"] forKey:@"sourceURL"];
                    NSManagedObject *episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:feed forKey:@"feed"];
                    [episode setValue:@"Sleep activity fixture" forKey:@"title"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@2400 forKey:@"duration"];
                    [episode reconstructObjectHash];
                    NSManagedObject *medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    NSError *error;
                    if (![context save:&error]) @throw [NSException exceptionWithName:@"FixtureSave" reason:error.description userInfo:nil];
                    UIViewController *root = [delegate valueForKey:@"mainViewController"];
                    PlaybackViewController *controller = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:(id)episode];
                    [controller presentFromParentViewController:root autostart:YES completion:nil];
                } else if ([action isEqual:@"arm"]) {
                    [defaults setBool:command[@"smart"] ? [command[@"smart"] boolValue] : YES forKey:@"IntelligentSleepTimerAlwaysActive"];
                    [defaults setBool:command[@"touch"] ? [command[@"touch"] boolValue] : NO forKey:@"ScreenTouchIntelligentSleep"];
                    [manager play];
                    [session setTimerWithDuration:[command[@"seconds"] doubleValue]];
                } else if ([action isEqual:@"cancel"]) session.timerValue = 0;
                else if ([action isEqual:@"pause"]) [manager pause];
                else if ([action isEqual:@"play"]) [manager play];
                else if ([action isEqual:@"remote"]) {
                    SEL selector = NSSelectorFromString(command[@"selector"]);
                    ICSleepProbeEvent *event = [ICSleepProbeEvent new];
                    event.type = [command[@"type"] integerValue];
                    event.positionTime = 120;
                    MPRemoteCommandHandlerStatus (*invoke)(id, SEL, id) = (void *)[manager methodForSelector:selector];
                    reply[@"handlerStatus"] = @(invoke(manager, selector, event));
                }
                UIButton *button = nil;
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if (![scene isKindOfClass:UIWindowScene.class]) continue;
                    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                        button = timerButton(window);
                        if (button) break;
                    }
                    if (button) break;
                }
                [reply addEntriesFromDictionary:session.sleepTimerDiagnosticsMetadata];
                reply[@"remaining"] = @(session.timerRemainingTime);
                reply[@"title"] = button.currentTitle ?: @"";
                reply[@"accessibilityValue"] = button.accessibilityValue ?: @"";
                reply[@"ready"] = @(manager.ready);
                reply[@"paused"] = @(manager.paused);
                reply[@"rate"] = @([(AVPlayer *)[manager valueForKey:@"player"] rate]);
                reply[@"time"] = @(manager.time);
                reply[@"applicationState"] = @(UIApplication.sharedApplication.applicationState);
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
