//
//  AppleWatchEpisodeState.m
//  Instacast
//

#import "AppleWatchEpisodeState.h"

NSString* const ICAppleWatchSelectionSourceManual = @"manual";
NSString* const ICAppleWatchSelectionSourceLatestRule = @"latestRule";

NSString* const ICAppleWatchStatusSelected = @"selected";
NSString* const ICAppleWatchStatusManifestSent = @"manifestSent";
NSString* const ICAppleWatchStatusQueuedOnWatch = @"queuedOnWatch";
NSString* const ICAppleWatchStatusDownloading = @"downloading";
NSString* const ICAppleWatchStatusDownloaded = @"downloaded";
NSString* const ICAppleWatchStatusFailed = @"failed";
NSString* const ICAppleWatchStatusRemoving = @"removing";

@implementation AppleWatchEpisodeState

@dynamic episodeHash;
@dynamic feedIdentifier;
@dynamic selectionSource;
@dynamic watchStatus;
@dynamic watchAddedDate;
@dynamic watchDownloadedDate;
@dynamic watchLastSeenDate;
@dynamic watchLastError;
@dynamic watchActualDuration;
@dynamic watchActualFileSize;
@dynamic lastPhonePosition;
@dynamic lastPhonePositionDate;
@dynamic lastWatchPosition;
@dynamic lastWatchPositionDate;
@dynamic watchConsumed;
@dynamic watchConsumedDate;

- (BOOL)manuallySelected
{
    return [self.selectionSource isEqualToString:ICAppleWatchSelectionSourceManual];
}

- (BOOL)downloadedOnWatch
{
    return [self.watchStatus isEqualToString:ICAppleWatchStatusDownloaded];
}

- (BOOL)removingFromWatch
{
    return [self.watchStatus isEqualToString:ICAppleWatchStatusRemoving];
}

- (NSString*)localizedStatusText
{
    if ([self.watchStatus isEqualToString:ICAppleWatchStatusDownloaded]) {
        return @"Auf Apple Watch".ls;
    }
    if ([self.watchStatus isEqualToString:ICAppleWatchStatusDownloading]) {
        return @"Laedt auf Apple Watch".ls;
    }
    if ([self.watchStatus isEqualToString:ICAppleWatchStatusFailed]) {
        return @"Fehler beim Laden".ls;
    }
    if ([self.watchStatus isEqualToString:ICAppleWatchStatusRemoving]) {
        return @"Wird entfernt".ls;
    }
    return @"Wartet auf Apple Watch".ls;
}

@end
