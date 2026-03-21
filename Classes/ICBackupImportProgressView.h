//
//  ICBackupImportProgressView.h
//  Instacast
//

#import <UIKit/UIKit.h>
#import "InstacastBackupImporter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ICBackupImportProgressView : UIView

/// Create a progress view for backup import with feed list and metadata categories.
/// @param feedTitles Ordered list of feed titles to display
/// @param categories Bitmask of selected metadata import categories (Phase C)
- (instancetype)initWithFeedTitles:(NSArray<NSString *> *)feedTitles
                        categories:(ICBackupImportCategory)categories;

- (void)show;
- (void)close;
- (void)closeWithCompletion:(void (^ _Nullable)(void))completion;

#pragma mark - Phase A+B: Feed Progress

/// Mark a feed as currently loading (shows spinner)
- (void)setCurrentFeedAtIndex:(NSInteger)index;

/// Update feed progress (0.0–1.0) with detail text (e.g. "50/200 Episodes")
- (void)setFeedProgress:(float)progress detail:(NSString *)detail atIndex:(NSInteger)index;

/// Mark a feed as completed with episode count
- (void)setFeedCompletedAtIndex:(NSInteger)index episodeCount:(NSInteger)count;

/// Mark a feed as failed with error message
- (void)setFeedErrorAtIndex:(NSInteger)index message:(NSString *)message;

/// Mark a feed as skipped (user cancelled this feed)
- (void)setFeedSkippedAtIndex:(NSInteger)index;

#pragma mark - Total Progress

/// Set overall progress (0.0–1.0)
- (void)setTotalProgress:(float)progress;

/// Set status text below title (e.g. "Subscribing podcasts…")
- (void)setStatusText:(NSString *)text;

#pragma mark - Phase C: Metadata Categories

/// Mark a metadata category as currently active (shows spinner)
- (void)setMetadataCategoryActive:(ICBackupImportCategory)category;

/// Mark a metadata category as completed with detail
- (void)setMetadataCategoryCompleted:(ICBackupImportCategory)category detail:(NSString *)detail;

#pragma mark - Completion

/// Show completion state with summary text
- (void)showCompletionWithSummary:(NSString *)summary;

#pragma mark - Cancel

/// Called when user taps "Cancel". Presents action sheet with skip/cancel/back options.
@property (nonatomic, copy, nullable) void (^onCancelCurrentFeed)(void);
@property (nonatomic, copy, nullable) void (^onCancelImport)(void);

@end

NS_ASSUME_NONNULL_END
