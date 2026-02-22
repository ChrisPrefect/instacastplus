//
//  ICDailyBackupManager.h
//  Instacast
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString* const ICDailyBackupManagerStatusDidChangeNotification;

@interface ICDailyBackupManager : NSObject

+ (instancetype)sharedManager;

+ (void)applyPendingRestoreIfNeededAtLaunch;

- (NSDictionary<NSString*, id>*)statusSnapshot;
- (NSArray<NSDictionary*>*)availableBackups;

- (void)scheduleDailyBackupIfNeededWithReason:(NSString*)reason;
- (void)createBackupNowWithReason:(NSString*)reason
                       completion:(void (^ _Nullable)(BOOL success, NSError* _Nullable error))completion;

- (void)prepareRestoreForBackupWithIdentifier:(NSString*)identifier
                                   completion:(void (^ _Nullable)(BOOL success, NSError* _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
