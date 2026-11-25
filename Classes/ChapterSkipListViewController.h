//
//  ChapterSkipListViewController.h
//  Instacast
//
//  Created by Chris on 11/02/26.
//  Copyright © 2026 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>

@class CDFeed;

NS_ASSUME_NONNULL_BEGIN

@interface ChapterSkipListViewController : UITableViewController

@property (nonatomic, strong) CDFeed *feed;
@property (nonatomic, copy, nullable) NSString *initialKeyword;
@property (nonatomic, copy, nullable) void (^keywordAdded)(NSString *keyword);

+ (instancetype)controllerWithFeed:(CDFeed *)feed;

@end

NS_ASSUME_NONNULL_END
