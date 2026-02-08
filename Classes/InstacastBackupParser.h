//
//  InstacastBackupParser.h
//  Instacast
//

#import <Foundation/Foundation.h>

@class InstacastBackupData;

NS_ASSUME_NONNULL_BEGIN

@interface InstacastBackupParser : NSObject

/// Quick-check if the data starts with an <instacast> root element
+ (BOOL)isInstacastBackupData:(NSData *)data;

/// Parse backup XML data on a background queue, deliver result on main queue
+ (void)parseData:(NSData *)data completion:(void(^)(InstacastBackupData * _Nullable data, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
