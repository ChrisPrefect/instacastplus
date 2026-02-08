//
//  InstacastBackupImportViewController.h
//  Instacast
//

#import <UIKit/UIKit.h>

@class InstacastBackupData;

NS_ASSUME_NONNULL_BEGIN

@interface InstacastBackupImportViewController : UITableViewController

@property (nonatomic, strong) InstacastBackupData *backupData;

+ (instancetype)viewControllerWithBackupData:(InstacastBackupData *)backupData;

@end

NS_ASSUME_NONNULL_END
