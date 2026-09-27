// Test-only driver loaded into the real Simulator app; no production methods are replaced.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreData/CoreData.h>
#import "PlaybackManager.h"
@class CDEpisodeList;
#import "AudioSession.h"
#import "PlayerInfoViewController_v5.h"

@interface NSObject (ChapterResumeProbeAPI)
+ (id)sharedDatabaseManager;
- (void)reconstructObjectHash;
- (void)setDouble:(double)value forKey:(NSString*)key;
- (void)setInteger:(NSInteger)value forKey:(NSString*)key;
- (void)setString:(NSString*)value forKey:(NSString*)key;
- (NSInteger)_chaptersSection;
@end

static NSString *directory;
static NSManagedObject *episode;
static PlayerInfoViewController_v5 *screen;

static NSDictionary *snapshot(PlaybackManager *player) {
    NSString *hash = [episode valueForKey:@"objectHash"] ?: @"";
    return @{@"time": @(player.time), @"position": @(player.position * player.duration),
             @"duration": @(player.duration), @"ready": @(player.ready), @"paused": @(player.paused),
             @"chapterCount": @(player.chapters.count), @"currentChapter": @(player.currentChapter),
             @"loaded": @(player.playingEpisode != nil), @"consumed": [episode valueForKey:@"consumed"] ?: @NO,
             @"screenVisible": @(screen.isViewLoaded && screen.view.window != nil),
             @"episodeHash": hash,
             @"saved": [NSUserDefaults.standardUserDefaults dictionaryForKey:@"ChapterPlaybackPositions"][hash] ?: @{},
             @"markers": [player valueForKey:@"autoSkipMarkers"] ?: @[]};
}

@interface ICChapterResumeProbe : NSObject @end
@implementation ICChapterResumeProbe
+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"ChapterResumeProbe"];
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            NSString *path = [directory stringByAppendingPathComponent:@"command.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data || ![(NSObject*)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            NSDictionary *command = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            PlaybackManager *player = [NSClassFromString(@"PlaybackManager") playbackManager];
            NSString *action = command[@"action"];
            NSMutableDictionary *reply = [NSMutableDictionary dictionary];
            @try {
                if ([action isEqual:@"fixture"]) {
                    [player close];
                    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
                    [defaults setBool:YES forKey:@"RememberChapterPosition"];
                    [defaults setBool:NO forKey:@"AutoDownloadWhileStreaming"];
                    [defaults setBool:NO forKey:@"AutoSkipSponsors"];
                    [defaults setDouble:0 forKey:@"PlayerAutoSkipEndPeriod"];
                    [defaults setBool:NO forKey:@"PlayerReplayAfterPause"];
                    NSManagedObjectContext *context = [[NSClassFromString(@"DatabaseManager") sharedDatabaseManager] valueForKey:@"objectContext"];
                    NSManagedObject *feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
                    [feed setValue:@"Kapitelposition Regression" forKey:@"title"];
                    [feed setValue:[NSURL URLWithString:@"https://example.invalid/chapter-resume.xml"] forKey:@"sourceURL"];
                    [feed setInteger:0 forKey:@"ContinuousPlayFromFeed"];
                    episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
                    [episode setValue:feed forKey:@"feed"];
                    [episode setValue:command[@"name"] forKey:@"title"];
                    [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
                    [episode setValue:NSDate.date forKey:@"pubDate"];
                    [episode setValue:@24 forKey:@"duration"];
                    [episode setValue:@NO forKey:@"consumed"];
                    [episode reconstructObjectHash];
                    NSManagedObject *medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
                    [medium setValue:episode forKey:@"episode"];
                    [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
                    [medium setValue:@"audio/wav" forKey:@"mimeType"];
                    NSArray *titles = command[@"titles"] ?: @[@"Erstes Kapitel", @"Werbung", @"Letztes Kapitel"];
                    for (NSInteger index = 0; index < 3; index++) {
                        NSManagedObject *chapter = [NSEntityDescription insertNewObjectForEntityForName:@"Chapter" inManagedObjectContext:context];
                        [chapter setValue:episode forKey:@"episode"];
                        [chapter setValue:@(index) forKey:@"index"];
                        [chapter setValue:@(index * 8) forKey:@"timecode"];
                        [chapter setValue:@8 forKey:@"duration"];
                        [chapter setValue:titles[index] forKey:@"title"];
                    }
                    NSError *error = nil;
                    if (![context save:&error]) @throw [NSException exceptionWithName:@"FixtureSave" reason:error.description userInfo:nil];
                    [screen reload];
                } else if ([action isEqual:@"open"]) {
                    [[NSClassFromString(@"AudioSession") sharedAudioSession] playEpisode:(id)episode queueUpCurrent:NO
                        at:[command[@"time"] doubleValue] autostart:NO];
                } else if ([action isEqual:@"show"]) {
                    if (!screen) {
                        screen = [NSClassFromString(@"PlayerInfoViewController_v5") viewController];
                        UIViewController *root = UIApplication.sharedApplication.delegate.window.rootViewController;
                        void (^present)(void) = ^{
                            [root presentViewController:[[UINavigationController alloc] initWithRootViewController:screen] animated:NO completion:nil];
                        };
                        if (root.presentedViewController) [root dismissViewControllerAnimated:NO completion:present];
                        else present();
                    }
                    [screen reload];
                } else if ([action isEqual:@"capture"]) {
                    UIWindow *window = screen.view.window;
                    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds];
                    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
                    }];
                    [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"screen.png"] atomically:YES];
                } else if ([action isEqual:@"select"]) {
                    [screen reload];
                    NSIndexPath *index = [NSIndexPath indexPathForRow:[command[@"index"] integerValue] inSection:[screen _chaptersSection]];
                    [screen tableView:screen.tableView didSelectRowAtIndexPath:index];
                } else if ([action isEqual:@"seek"]) {
                    [player seekToTime:[command[@"time"] doubleValue] tolerance:NO];
                } else if ([action isEqual:@"play"]) [player play];
                else if ([action isEqual:@"pause"]) [player pause];
                else if ([action isEqual:@"next"]) [player nextChapter];
                else if ([action isEqual:@"previous"]) [player previousChapter];
                else if ([action isEqual:@"forward"]) [player seekForward];
                else if ([action isEqual:@"configure"]) {
                    id feed = [episode valueForKey:@"feed"];
                    NSString *uid = [feed valueForKey:@"uid"];
                    [feed setString:command[@"skipName"] ?: @"" forKey:[uid stringByAppendingString:@"_auto_skip_chapter_name"]];
                    if (command[@"skipName"]) [feed setDouble:[command[@"offset"] doubleValue]
                        forKey:[NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", uid, command[@"skipName"]]];
                    [NSUserDefaults.standardUserDefaults setDouble:[command[@"skipEnd"] doubleValue] forKey:@"PlayerAutoSkipEndPeriod"];
                    [feed setInteger:[command[@"nearMode"] integerValue] forKey:@"PlayerNearChapterEndForwardSkipMode"];
                    [feed setInteger:5 forKey:@"PlayerNearChapterEndForwardSkipWindow"];
                }
                [reply addEntriesFromDictionary:snapshot(player)];
            } @catch (NSException *exception) { reply[@"error"] = exception.description; }
            reply[@"id"] = command[@"id"];
            [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
        }];
    });
}
@end
