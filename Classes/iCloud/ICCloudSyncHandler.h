//
//  ICCloudSyncHandler.h
//  Instacast
//

#import <Foundation/Foundation.h>
#import <CloudKit/CloudKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ICCloudSyncHandler <NSObject>

@required
- (NSString *)recordType;
- (void)pushChangesWithCompletion:(void(^)(NSError * _Nullable error))completion;
- (void)handleReceivedRecords:(NSArray<CKRecord *> *)records completion:(void(^)(NSError * _Nullable error))completion;
- (void)handleDeletedRecordIDs:(NSArray<CKRecordID *> *)recordIDs completion:(void(^)(NSError * _Nullable error))completion;

@optional
- (void)pushAllDataWithCompletion:(void(^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
