//
//  ChaptersTableViewCell.h
//  Instacast
//
//  Created by Martin Hering on 31.05.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
@interface ChaptersTableViewCell : UITableViewCell {

}

@property (nonatomic, strong) CDChapter* objectValue;

@property (nonatomic, readonly, strong) UIProgressView* progressView;
@property (nonatomic, readonly, strong) UILabel* numLabel;
@property (nonatomic, readonly, strong) UILabel* timeLabel;
@property (nonatomic, readonly, strong) UIButton* linkButton;

+ (CGFloat) proposedHeightWithTitle:(NSString*)title tableBounds:(CGRect)tableBounds;

@end
