//
//  ICMonospaceTextField.m
//  Instacast
//
//  Created by Martin Hering on 11.02.16.
//  Copyright © 2016 Vemedio. All rights reserved.
//

#import "ICMonospaceLabel.h"

@implementation ICMonospaceLabel

- (void) awakeFromNib
{
    [super awakeFromNib];

    self.font = [UIFont monospacedDigitSystemFontOfSize:ICFontSize(self.font.pointSize) weight:UIFontWeightRegular];
}

- (void) updateFontScale
{
    // Re-apply font scaling (call after font size preference changes)
    CGFloat baseSize = self.font.pointSize / [ICAppearanceManager sharedManager].fontSizeScale;
    self.font = [UIFont monospacedDigitSystemFontOfSize:ICFontSize(baseSize) weight:UIFontWeightRegular];
}
@end
