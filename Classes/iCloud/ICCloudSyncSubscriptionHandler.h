//
//  ICCloudSyncSubscriptionHandler.h
//  Instacast
//

#import <Foundation/Foundation.h>
#import "ICCloudSyncHandler.h"

NS_ASSUME_NONNULL_BEGIN

@interface ICCloudSyncSubscriptionHandler : NSObject <ICCloudSyncHandler>

@property (nonatomic, strong) CKDatabase *database;
@property (nonatomic, strong) CKRecordZoneID *zoneID;

@end

NS_ASSUME_NONNULL_END
