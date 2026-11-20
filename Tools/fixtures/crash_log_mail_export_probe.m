// Exercise the real app's report exporter, without replacing any app method.
#import <UIKit/UIKit.h>
#include <stdio.h>

@interface NSObject (MailExportProbeAPI)
+ (id)shared;
- (NSArray*)crashLogMailAttachments;
- (void)clearCrashLogMailArtifacts;
@end

@interface ICMailExportProbe:NSObject @end
@implementation ICMailExportProbe
+ (void)load {
#if TARGET_OS_SIMULATOR
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"onboard_will_show"];
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
        __block BOOL done = NO;
        [NSTimer scheduledTimerWithTimeInterval:.1 repeats:YES block:^(NSTimer* timer) {
            if (done || ![(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"]) return;
            done = YES;
            NSString* directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:[@"MailExportProbe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
            Class type = NSClassFromString(@"ICDiagnosticLogger") ?: NSClassFromString(@"InstacastPlus.ICDiagnosticLogger");
            id logger = [type shared];
            NSMutableArray* files = [NSMutableArray array];
            for (NSString* name in @[@"normal.txt", @"after-clear.txt"]) {
#if TARGET_OS_SIMULATOR
                if ([name isEqual:@"after-clear.txt"]) [logger clearCrashLogMailArtifacts];
#else
                if ([name isEqual:@"after-clear.txt"]) break;
#endif
                id attachment = [logger crashLogMailAttachments].firstObject;
                NSData* data = [attachment valueForKey:@"data"];
                if (![data writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES]) abort();
                [files addObject:name];
            }
            NSDictionary* result = @{@"directory":directory, @"files":files};
            NSData* json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
            fprintf(stderr,"IC_MAIL_EXPORT_PROBE=%s\n",[[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] UTF8String]);
            fflush(stderr);
            [timer invalidate];
        }];
    });
}
@end
