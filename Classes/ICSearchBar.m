//
//  ICSearchBar.m
//  Instacast
//
//  Created by Martin Hering on 28.08.14.
//
//

#import "ICSearchBar.h"
#import "ImageFunctions.h"

@implementation ICSearchBar

- (void) appearanceDidChange
{
    // search style update
    self.tintColor = ICTableSeparatorColor;
    [self setScopeBarButtonTitleTextAttributes:@{NSForegroundColorAttributeName : [UIColor colorWithWhite:0.58f alpha:1.f]} forState:UIControlStateNormal];
    [self setScopeBarButtonTitleTextAttributes:@{NSForegroundColorAttributeName : ICTintColor} forState:UIControlStateSelected];
    
    UIImage* backgroundImage = ICImageFromByDrawingInContextWithScale(CGSizeMake(28, 28), NO, self.window.screen.scale, ^{
        
        UIBezierPath* rectanglePath = [UIBezierPath bezierPathWithRoundedRect: CGRectMake(0, 0, 28, 28) cornerRadius:6];
        [ICGroupCellBackgroundColor setFill];
        [rectanglePath fill];
    });
    backgroundImage = [backgroundImage resizableImageWithCapInsets:UIEdgeInsetsMake(6, 6, 6, 6)];
    
    [self setSearchFieldBackgroundImage:backgroundImage forState:UIControlStateNormal];
    
    for (UIView *subView in self.subviews)
    {
        for (UIView *secondLevelSubview in subView.subviews){
            if ([secondLevelSubview isKindOfClass:[UITextField class]])
            {
                UITextField *searchBarTextField = (UITextField *)secondLevelSubview;
                searchBarTextField.textColor = ICTextColor;
                searchBarTextField.tintColor = ICTintColor;
                searchBarTextField.font = [UIFont systemFontOfSize:ICFontSize(14)];
                break;
            }
        }
    }
    
    self.searchTextPositionAdjustment = UIOffsetMake(5, 0);
}

// The search finishes too quickly for an activity indicator to be useful; since the circle
// became visible again (CircleProgressView fix, 16.11.2026) it only flickered. Decision
// 17.11.2026: no indicator in the search field. The flag is kept for the callers.
- (void) setShowsActivity:(BOOL)showsActivity
{
    _showsActivity = showsActivity;
}
@end
