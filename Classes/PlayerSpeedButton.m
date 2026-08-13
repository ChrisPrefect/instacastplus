//
//  PlayerSpeedButton.m
//  Instacast
//
//  Created by Martin Hering on 10.01.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import "PlayerSpeedButton.h"
#import "VDModalInfo.h"

@implementation PlayerSpeedButton {
    BOOL        _observing;
    NSDate*     _trackingDate;
    NSTimer*    _longTrackingTimer;
}

- (void) _updateImage
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    NSString* title = [PlayerSpeedButton titleForSpeedControl:pman.speedControl];
    
    if (pman.speedControl == PlaybackSpeedControlNormalSpeed) {
        UIImageSymbolConfiguration* configuration = [UIImageSymbolConfiguration configurationWithPointSize:28.5f
                                                                                                      weight:UIImageSymbolWeightRegular];
        UIImage* image = [[UIImage systemImageNamed:@"gauge.with.dots.needle.50percent" withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        [self setImage:image
              forState:UIControlStateNormal];
        [self setTitle:nil forState:UIControlStateNormal];
        [self setTitleColor:self.tintColor forState:UIControlStateNormal];
        [self setTitleColor:self.tintColor forState:UIControlStateHighlighted];
    }
    else {
        [self setImage:[[UIImage imageNamed:@"Player Speed Fill"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
              forState:UIControlStateNormal];
        [self setTitle:title forState:UIControlStateNormal];
        [self setTitleColor:ICBackgroundColor forState:UIControlStateNormal];
        [self setTitleColor:ICBackgroundColor forState:UIControlStateHighlighted];
    }

    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.font = [UIFont boldSystemFontOfSize:ICFontSize(18)];

    self.accessibilityLabel = @"Playback Speed".ls;
    self.accessibilityValue = title;
}

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    if (newWindow)
    {
        [self _updateImage];

        if (!_observing) {
            _observing = YES;
            [[PlaybackManager playbackManager] addTaskObserver:self forKeyPath:@"speedControl" task:^(id obj, NSDictionary *change) {
                [self _updateImage];
            }];
        }
    }
    else
    {
        if (_observing) {
            [[PlaybackManager playbackManager] removeTaskObserver:self forKeyPath:@"speedControl"];
            _observing = NO;
        }
    }
}

- (void) tintColorDidChange
{
    if ([PlaybackManager playbackManager].speedControl == PlaybackSpeedControlNormalSpeed) {
        [self setTitleColor:self.tintColor forState:UIControlStateNormal];
        [self setTitleColor:self.tintColor forState:UIControlStateHighlighted];
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _trackingDate = [NSDate date];
    
    _longTrackingTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(_longTrackingTimerAction:) userInfo:nil repeats:NO];

    return [super beginTrackingWithTouch:touch withEvent:event];
}

- (void) _longTrackingTimerAction:(NSTimer*)timer
{
    [PlaybackManager playbackManager].speedControl = PlaybackSpeedControlNormalSpeed;
    PlayHapticFeedback(ICHapticFeedbackMedium);
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Playback set to original speed.".ls);
    
    VDModalInfo* modalInfo = [VDModalInfo modalInfo];
    modalInfo.closableByTap = NO;
    modalInfo.animation = VDModalInfoAnimationMoveDown;
    modalInfo.alignment = VDModalInfoAlignmentPhonePlayer;
    modalInfo.size = CGSizeMake(280, 44);
    
    modalInfo.textLabel.text = @"Playback speed: original.".ls;
    [modalInfo show];
    
    [self perform:^(id sender) {
        [modalInfo close];
    } afterDelay:1];
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
    [super endTrackingWithTouch:touch withEvent:event];
    
    if (CGRectContainsPoint(self.bounds,  [touch locationInView:self]))
    {
        if ([_trackingDate timeIntervalSinceNow] >= -0.5)
        {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            PlaybackSpeedControl nextSpeed = [PlayerSpeedButton nextEnabledSpeedAfter:pman.speedControl];
            pman.speedControl = nextSpeed;
            PlayHapticFeedback(ICHapticFeedbackLight);
            NSString* title = [PlayerSpeedButton titleForSpeedControl:nextSpeed];
            NSString* announcement = [NSString stringWithFormat:@"Playback set to %@ speed.".ls, title];
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, announcement);
        }
        
    }
    
    [_longTrackingTimer invalidate];
    _longTrackingTimer = nil;
    
    _trackingDate = nil;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (CGRect)titleRectForContentRect:(CGRect)contentRect
{
    if ([PlaybackManager playbackManager].speedControl == PlaybackSpeedControlNormalSpeed) {
        return CGRectZero;
    }

    CGFloat scale = [ICAppearanceManager sharedManager].fontSizeScale;
    CGFloat w = 53 * scale;
    CGFloat h = 22 * scale;
    return CGRectMake(contentRect.origin.x + (contentRect.size.width - w) / 2,
                      contentRect.origin.y + (contentRect.size.height - h) / 2,
                      w, h);
}

- (CGRect)imageRectForContentRect:(CGRect)contentRect
{
    if ([PlaybackManager playbackManager].speedControl == PlaybackSpeedControlNormalSpeed) {
        CGFloat size = 28.5f;
        return CGRectMake(contentRect.origin.x + (contentRect.size.width - size) / 2,
                          contentRect.origin.y + (contentRect.size.height - size) / 2,
                          size, size);
    }

    CGFloat scale = [ICAppearanceManager sharedManager].fontSizeScale;
    CGFloat w = 53 * scale;
    CGFloat h = 22 * scale;
    return CGRectMake(contentRect.origin.x + (contentRect.size.width - w) / 2,
                      contentRect.origin.y + (contentRect.size.height - h) / 2,
                      w, h);
}
#pragma clang diagnostic pop

#pragma mark - Speed cycling helpers

// Ordered list of all speeds from slowest to fastest
// Ascending order (slowest to fastest) — used for cycling and sorting
+ (NSArray<NSNumber*>*) allSpeedControlsOrdered
{
    return @[
        @(PlaybackSpeedControlMinusHalfSpeed),     // 0.5x
        @(PlaybackSpeedControlThreeQuarterSpeed),   // 0.75x
        @(PlaybackSpeedControlNormalSpeed),          // 1x
        @(PlaybackSpeedControlFaster11),             // 1.1x
        @(PlaybackSpeedControlFaster12),             // 1.2x
        @(PlaybackSpeedControlFaster125),            // 1.25x
        @(PlaybackSpeedControlFaster13),             // 1.3x
        @(PlaybackSpeedControlPlusHalfSpeed),        // 1.5x
        @(PlaybackSpeedControlDoubleSpeed),          // 2x
        @(PlaybackSpeedControlTripleSpeed),          // 3x
    ];
}

// Descending order (fastest to slowest) — used for settings UI
+ (NSArray<NSNumber*>*) allSpeedControlsDescending
{
    return @[
        @(PlaybackSpeedControlTripleSpeed),          // 3x
        @(PlaybackSpeedControlDoubleSpeed),          // 2x
        @(PlaybackSpeedControlPlusHalfSpeed),        // 1.5x
        @(PlaybackSpeedControlFaster13),             // 1.3x
        @(PlaybackSpeedControlFaster125),            // 1.25x
        @(PlaybackSpeedControlFaster12),             // 1.2x
        @(PlaybackSpeedControlFaster11),             // 1.1x
        @(PlaybackSpeedControlNormalSpeed),          // 1x
        @(PlaybackSpeedControlThreeQuarterSpeed),   // 0.75x
        @(PlaybackSpeedControlMinusHalfSpeed),     // 0.5x
    ];
}

+ (NSArray<NSNumber*>*) enabledSpeedControls
{
    NSArray* enabled = [USER_DEFAULTS arrayForKey:EnabledPlaybackSpeedsKey];
    if (!enabled) {
        // Default: 0.75x, 1x, 1.2x, 1.5x
        return @[
            @(PlaybackSpeedControlThreeQuarterSpeed),
            @(PlaybackSpeedControlNormalSpeed),
            @(PlaybackSpeedControlFaster12),
            @(PlaybackSpeedControlPlusHalfSpeed),
        ];
    }
    // Filter and sort by the canonical order
    NSArray* allOrdered = [self allSpeedControlsOrdered];
    NSMutableArray* result = [NSMutableArray array];
    for (NSNumber* speed in allOrdered) {
        if ([enabled containsObject:speed]) {
            [result addObject:speed];
        }
    }
    // Always include 1x
    if (![result containsObject:@(PlaybackSpeedControlNormalSpeed)]) {
        [result insertObject:@(PlaybackSpeedControlNormalSpeed) atIndex:0];
    }
    return result;
}

+ (PlaybackSpeedControl) nextEnabledSpeedAfter:(PlaybackSpeedControl)current
{
    NSArray* enabled = [self enabledSpeedControls];
    NSUInteger idx = [enabled indexOfObject:@(current)];
    if (idx == NSNotFound || idx + 1 >= enabled.count) {
        return [enabled.firstObject integerValue];
    }
    return [enabled[idx + 1] integerValue];
}

+ (NSString*) titleForSpeedControl:(PlaybackSpeedControl)control
{
    switch (control) {
        case PlaybackSpeedControlMinusHalfSpeed:    return @"0.5x";
        case PlaybackSpeedControlThreeQuarterSpeed: return @"0.75x";
        case PlaybackSpeedControlNormalSpeed:        return @"1x";
        case PlaybackSpeedControlFaster11:           return @"1.1x";
        case PlaybackSpeedControlFaster12:           return @"1.2x";
        case PlaybackSpeedControlFaster125:          return @"1.25x";
        case PlaybackSpeedControlFaster13:           return @"1.3x";
        case PlaybackSpeedControlPlusHalfSpeed:      return @"1.5x";
        case PlaybackSpeedControlDoubleSpeed:        return @"2x";
        case PlaybackSpeedControlTripleSpeed:        return @"3x";
        default:                                     return @"1x";
    }
}

@end
