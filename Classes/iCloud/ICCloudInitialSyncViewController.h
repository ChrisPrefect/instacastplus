//
//  ICCloudInitialSyncViewController.h
//  Instacast
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, ICInitialSyncAction) {
    ICInitialSyncActionCancel = 0,
    ICInitialSyncActionUpload,
    ICInitialSyncActionDownload,
    ICInitialSyncActionMerge,
};

@interface ICCloudInitialSyncViewController : UITableViewController

@property (nonatomic) BOOL cloudDataExists;

// Local statistics (set before push)
@property (nonatomic) NSInteger localPodcastCount;
@property (nonatomic) NSInteger localEpisodeCount;
@property (nonatomic) NSInteger localListCount;

// Completion block called when user selects an action
@property (nonatomic, copy) void (^completionBlock)(ICInitialSyncAction action);

+ (instancetype)viewController;

@end
