//
//  ICCloudSyncDeviceInfo.h
//  Instacast
//

#import <Foundation/Foundation.h>
#import <CloudKit/CloudKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ICCloudSyncDeviceInfo : NSObject

@property (nonatomic, copy) NSString *deviceID;
@property (nonatomic, copy) NSString *deviceName;
@property (nonatomic, copy) NSString *deviceModel;
@property (nonatomic, copy) NSString *systemVersion;
@property (nonatomic, strong, nullable) NSDate *lastSyncDate;
@property (nonatomic, strong, nullable) NSArray<NSString *> *activeCategories;

+ (ICCloudSyncDeviceInfo *)currentDevice;
- (CKRecord *)toCKRecordInZone:(CKRecordZoneID *)zoneID;
+ (ICCloudSyncDeviceInfo *)fromCKRecord:(CKRecord *)record;

@end

NS_ASSUME_NONNULL_END
