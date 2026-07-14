//
//  AppleWatchEpisodeState.h
//  Instacast
//

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>
#import "CDBase.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const ICAppleWatchSelectionSourceManual;
FOUNDATION_EXPORT NSString* const ICAppleWatchSelectionSourceLatestRule;

FOUNDATION_EXPORT NSString* const ICAppleWatchStatusSelected;
FOUNDATION_EXPORT NSString* const ICAppleWatchStatusManifestSent;
FOUNDATION_EXPORT NSString* const ICAppleWatchStatusQueuedOnWatch;
FOUNDATION_EXPORT NSString* const ICAppleWatchStatusDownloading;
FOUNDATION_EXPORT NSString* const ICAppleWatchStatusDownloaded;
FOUNDATION_EXPORT NSString* const ICAppleWatchStatusFailed;
FOUNDATION_EXPORT NSString* const ICAppleWatchStatusEvicted;
FOUNDATION_EXPORT NSString* const ICAppleWatchStatusRemoving;

@interface AppleWatchEpisodeState : CDBase

@property (nonatomic, strong, nullable) NSString* episodeHash;
@property (nonatomic, strong, nullable) NSString* feedIdentifier;
@property (nonatomic, strong, nullable) NSString* selectionSource;
@property (nonatomic, strong, nullable) NSString* watchStatus;
@property (nonatomic, strong, nullable) NSDate* watchAddedDate;
@property (nonatomic, strong, nullable) NSDate* watchDownloadedDate;
@property (nonatomic) int64_t watchLastEventRevision;
@property (nonatomic, strong, nullable) NSDate* watchLastSeenDate;
@property (nonatomic, strong, nullable) NSString* watchLastError;
@property (nonatomic) int32_t watchActualDuration;
@property (nonatomic) int64_t watchActualFileSize;
@property (nonatomic) int32_t lastPhonePosition;
@property (nonatomic, strong, nullable) NSDate* lastPhonePositionDate;
@property (nonatomic) int32_t lastWatchPosition;
@property (nonatomic, strong, nullable) NSDate* lastWatchPositionDate;
@property (nonatomic) BOOL watchConsumed;
@property (nonatomic, strong, nullable) NSDate* watchConsumedDate;

@property (nonatomic, readonly) BOOL manuallySelected;
@property (nonatomic, readonly) BOOL downloadedOnWatch;
@property (nonatomic, readonly) BOOL removingFromWatch;

- (NSString*)localizedStatusText;

@end

NS_ASSUME_NONNULL_END
