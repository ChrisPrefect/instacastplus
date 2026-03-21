//
//  EpisodesTableViewCell.h
//  Instacast
//
//  Created by Martin Hering on 29.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "IOS8FixedSeparatorTableViewCell.h"

@class EpisodePlayComboButton;
@class GradientProgressView;

@interface EpisodesTableViewCell : IOS8FixedSeparatorTableViewCell {
    GradientProgressView *progressView;
}

@property (nonatomic, strong) id objectValue;
@property (nonatomic, strong, readonly) EpisodePlayComboButton* playAccessoryButton;
@property (nonatomic, strong, readonly) UIImageView* iconView;

@property (nonatomic) BOOL canDelete;
@property (nonatomic, readonly) BOOL showsDeleteControl;

@property (nonatomic) BOOL embedded;
@property (nonatomic) BOOL upNextStyle; // feed title above episode title, with image
@property (nonatomic, strong, readonly) UIPanGestureRecognizer* panRecognizer;
@property (nonatomic) BOOL topSeparator;

- (void) updatePlayComboButtonState;
- (void) updatePlayedAndStarredState;
+ (CGFloat) proposedHeightWithObjectValue:(id)objectValue tableSize:(CGSize)tableSize imageSize:(CGSize)size embedded:(BOOL)embedded editing:(BOOL)editing;
+ (CGFloat) proposedHeightWithObjectValue:(id)objectValue tableSize:(CGSize)tableSize imageSize:(CGSize)size embedded:(BOOL)embedded editing:(BOOL)editing upNextStyle:(BOOL)upNextStyle;

@property (nonatomic, copy) void (^panDidBegin)(NSIndexPath* cellIndexPath);
@property (nonatomic, copy) void (^didPanRight)(NSIndexPath* cellIndexPath);
@property (nonatomic, copy) void (^didPanLeft)(NSIndexPath* cellIndexPath);
@property (nonatomic, copy) void (^shouldDelete)(NSIndexPath* cellIndexPath);
@property (nonatomic, copy) void (^shouldShowMore)(NSIndexPath* cellIndexPath);

@property (nonatomic, copy) UIImage* (^leftSwipeImageProvider)(void);
@property (nonatomic, copy) UIColor* (^leftSwipeTintProvider)(void);
@property (nonatomic, copy) UIImage* (^rightSwipeImageProvider)(void);
@property (nonatomic, copy) UIColor* (^rightSwipeTintProvider)(void);

- (void) cancelDelete:(id)sender;

@end
