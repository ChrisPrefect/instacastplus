//
//  ICBackupImportProgressView.h
//  Instacast
//

#import <UIKit/UIKit.h>
#import "InstacastBackupImporter.h"

NS_ASSUME_NONNULL_BEGIN

@interface ICBackupImportProgressView : UIView

/// Create a progress view for the given categories.
/// @param categories Bitmask of selected import categories
/// @param descriptions Dictionary mapping category number → detail string (e.g. "5 new podcasts")
- (instancetype)initWithCategories:(ICBackupImportCategory)categories
                      descriptions:(NSDictionary<NSNumber *, NSString *> *)descriptions;

- (void)show;
- (void)close;
- (void)closeWithCompletion:(void(^)(void))completion;

/// Mark a category as currently active (shows spinner)
- (void)setCategoryActive:(ICBackupImportCategory)category;

/// Mark a category as completed with a result detail string
- (void)setCategoryCompleted:(ICBackupImportCategory)category detail:(NSString *)detail;

/// Update the subscription sub-progress (e.g. "3/10")
- (void)setCategory:(ICBackupImportCategory)category detail:(NSString *)detail;

/// Update title text (e.g. for "Import Complete")
- (void)setTitleText:(NSString *)title;

@end

NS_ASSUME_NONNULL_END
