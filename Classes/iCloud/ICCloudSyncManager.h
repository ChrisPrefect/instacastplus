//
//  ICCloudSyncManager.h
//  Instacast
//

#import <Foundation/Foundation.h>
#import <CloudKit/CloudKit.h>
#import "ICCloudSyncHandler.h"
#import "ICCloudSyncDeviceInfo.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString *ICCloudSyncManagerDidSyncNotification;
extern NSString *ICCloudSyncManagerDidUpdateDevicesNotification;
extern NSString *ICCloudSyncManagerDidUpdateProgressNotification;
extern NSString *ICCloudSyncManagerShouldStartNotification;
extern NSString *ICCloudSyncManagerShouldStopNotification;
extern NSString *ICCloudSyncManagerSyncNowNotification;
extern NSString *ICCloudSyncManagerResetNotification;
extern NSString *ICDatabaseDidSaveWithSyncNotification;

@interface ICCloudSyncManager : NSObject

+ (ICCloudSyncManager *)sharedManager;

- (void)start;
- (void)stop;
- (void)syncNow;
- (void)handleRemoteNotificationWithUserInfo:(NSDictionary *)userInfo;
- (void)checkAccountStatus:(void(^)(BOOL available))completion;
- (void)checkCloudDataExists:(void(^)(BOOL exists))completion;
- (void)pushAllDataWithCompletion:(void(^)(NSError * _Nullable error))completion;
- (void)fetchAllDataWithCompletion:(void(^)(NSError * _Nullable error))completion;
- (void)fetchDeviceList;
- (void)fetchCloudRecordCounts:(void(^)(NSDictionary<NSString *, NSNumber *> * _Nullable counts, NSError * _Nullable error))completion;

@property (nonatomic, readonly) CKContainer *container;
@property (nonatomic, readonly) CKDatabase *privateDatabase;
@property (nonatomic, readonly) CKRecordZoneID *syncZoneID;
@property (nonatomic, readonly) BOOL isStarted;
@property (nonatomic, readonly) BOOL isSyncing;
@property (nonatomic, readonly) NSInteger syncProgressCompleted;
@property (nonatomic, readonly) NSInteger syncProgressTotal;
@property (nonatomic, readonly) NSArray<ICCloudSyncDeviceInfo *> *devices;

- (void)registerHandler:(id<ICCloudSyncHandler>)handler;

@end

NS_ASSUME_NONNULL_END
