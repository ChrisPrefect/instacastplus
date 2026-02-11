//
//  ICCloudSyncUpNextHandler.h
//  Instacast
//

#import <Foundation/Foundation.h>
#import "ICCloudSyncHandler.h"

NS_ASSUME_NONNULL_BEGIN

@interface ICCloudSyncUpNextHandler : NSObject <ICCloudSyncHandler>

@property (nonatomic, strong) CKDatabase *database;
@property (nonatomic, strong) CKRecordZoneID *zoneID;

- (void)startObserving;
- (void)stopObserving;

@end

NS_ASSUME_NONNULL_END
