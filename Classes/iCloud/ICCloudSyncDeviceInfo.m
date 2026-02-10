//
//  ICCloudSyncDeviceInfo.m
//  Instacast
//

#import "ICCloudSyncDeviceInfo.h"
#include <sys/sysctl.h>

@implementation ICCloudSyncDeviceInfo

+ (ICCloudSyncDeviceInfo *)currentDevice
{
    ICCloudSyncDeviceInfo *info = [[ICCloudSyncDeviceInfo alloc] init];

    // Generate or retrieve persistent device ID
    NSString *deviceID = [USER_DEFAULTS stringForKey:iCloudSyncDeviceID];
    if (!deviceID) {
        deviceID = [[NSUUID UUID] UUIDString];
        [USER_DEFAULTS setObject:deviceID forKey:iCloudSyncDeviceID];
        [USER_DEFAULTS synchronize];
    }
    info.deviceID = deviceID;
    info.deviceName = [[UIDevice currentDevice] name];
    info.deviceModel = [self machineModel];
    info.systemVersion = [[UIDevice currentDevice] systemVersion];
    info.lastSyncDate = [NSDate date];

    NSMutableArray *categories = [NSMutableArray array];
    if ([USER_DEFAULTS boolForKey:iCloudSyncPlaybackStatus]) [categories addObject:@"playback"];
    if ([USER_DEFAULTS boolForKey:iCloudSyncNowPlaying]) [categories addObject:@"nowplaying"];
    if ([USER_DEFAULTS boolForKey:iCloudSyncSubscriptions]) [categories addObject:@"subscriptions"];
    if ([USER_DEFAULTS boolForKey:iCloudSyncFeedSettings]) [categories addObject:@"feedsettings"];
    if ([USER_DEFAULTS boolForKey:iCloudSyncAppSettings]) [categories addObject:@"appsettings"];
    if ([USER_DEFAULTS boolForKey:iCloudSyncDownloadStatus]) [categories addObject:@"downloads"];
    info.activeCategories = categories;

    return info;
}

+ (NSString *)machineModel
{
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char *model = malloc(size);
    sysctlbyname("hw.machine", model, &size, NULL, 0);
    NSString *identifier = [NSString stringWithCString:model encoding:NSUTF8StringEncoding];
    free(model);
    return identifier;
}

- (CKRecord *)toCKRecordInZone:(CKRecordZoneID *)zoneID
{
    CKRecordID *recordID = [[CKRecordID alloc] initWithRecordName:[NSString stringWithFormat:@"device_%@", self.deviceID] zoneID:zoneID];
    CKRecord *record = [[CKRecord alloc] initWithRecordType:@"SyncDevice" recordID:recordID];
    record[@"deviceID"] = self.deviceID;
    record[@"deviceName"] = self.deviceName;
    record[@"deviceModel"] = self.deviceModel;
    record[@"systemVersion"] = self.systemVersion;
    record[@"lastSyncDate"] = self.lastSyncDate ?: [NSDate date];
    record[@"activeCategories"] = self.activeCategories ?: @[];
    record[@"lastModified"] = [NSDate date];
    return record;
}

+ (ICCloudSyncDeviceInfo *)fromCKRecord:(CKRecord *)record
{
    ICCloudSyncDeviceInfo *info = [[ICCloudSyncDeviceInfo alloc] init];
    info.deviceID = record[@"deviceID"];
    info.deviceName = record[@"deviceName"];
    info.deviceModel = record[@"deviceModel"];
    info.systemVersion = record[@"systemVersion"];
    info.lastSyncDate = record[@"lastSyncDate"];
    info.activeCategories = record[@"activeCategories"];
    return info;
}

@end
