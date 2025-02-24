//
//  GradientProgressView.m
//  GradientProgressView
//
//  Created by Nick Jensen on 11/22/13.
//  Copyright (c) 2013 Nick Jensen. All rights reserved.
//

#import "GradientProgressView.h"

@implementation GradientProgressView

@synthesize animating, progress;

- (id)initWithFrame:(CGRect)frame {
    
    if ((self = [super initWithFrame:frame])) {
        CAGradientLayer *layer = (id)[self layer];
        [layer setStartPoint:CGPointMake(0.0, 0.5)];
        [layer setEndPoint:CGPointMake(1.0, 0.5)];
       
        [layer setColors:[NSArray arrayWithArray:[NSArray arrayWithObjects:(id)[ICTintColor CGColor], (id)[ICTintColor CGColor], nil]]];
        maskLayer = [CALayer layer];
        [maskLayer setFrame:CGRectMake(0, 0, 0, frame.size.height)];
        [maskLayer setBackgroundColor:[[UIColor lightGrayColor] CGColor]];
        [layer setMask:maskLayer];
    }
    return self;
}

+ (Class)layerClass {
    // Tells UIView to use CAGradientLayer as our backing layer
    return [CAGradientLayer class];
}

- (void)setProgress:(CGFloat)value {
    if (progress != value) {
        // progress values go from 0.0 to 1.0
        progress = MIN(1.0, fabs(value));
        [self setNeedsLayout];
    }
}

- (void)layoutSubviews {
    // Disable implicit animations by wrapping the frame update in a CATransaction
    [CATransaction begin];
    [CATransaction setDisableActions:YES];  // Disable animation
    CGRect maskRect = [maskLayer frame];
    maskRect.size.width = CGRectGetWidth([self bounds]) * progress;
    [maskLayer setFrame:maskRect];
    [CATransaction commit];

}


@end
