//
//  UIViewController+VMFoundation.m
//  Instacast
//
//  Created by Martin Hering on 01/06/14.
//
//

#import "UIViewController+VMFoundation.h"
#import "NSObject+VMFoundation.h"

@implementation UIViewController (VMFoundation)

- (BOOL) isBeingTransitioned {
    return [[self associatedObjectForKey:@"beingTransitioned"] boolValue];
}

- (void) setBeingTransitioned:(BOOL)beingTransitioned
{
    [self setAssociatedObject:@(beingTransitioned) forKey:@"beingTransitioned"];
}

- (void) extendedBeginAppearanceTransition:(BOOL)isAppearing animated:(BOOL)animated
{
    self.beingTransitioned = YES;
    [self beginAppearanceTransition:isAppearing animated:animated];
}

- (void) extendedEndAppearanceTransition
{
    [self endAppearanceTransition];
    self.beingTransitioned = NO;
}

- (void) setScrollView:(UIScrollView*)scrollView contentInsets:(UIEdgeInsets)edgeInsets byAdjustingForStandardBars:(BOOL)adjustStandardBars
{
    // No-op: iOS 11+ uses safe area insets automatically
}
@end
