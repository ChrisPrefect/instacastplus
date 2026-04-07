//
//  DirectoryFeedTableViewCell.h
//  Instacast
//
//  Created by Martin Hering on 04.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
@interface DirectoryFeedTableViewCell : UITableViewCell {
@protected
	UIImageView*	_videoIndicator;
}

@property (nonatomic, assign) BOOL video;
@property (nonatomic, weak) NSDictionary* podcast;
@end
