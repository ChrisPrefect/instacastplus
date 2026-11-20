//
//  PlayerSpeedButton.m
//  Instacast
//
//  Created by Martin Hering on 10.01.12.
//  Copyright (c) 2012 Vemedio. All rights reserved.
//

#import "PlayerSpeedButton.h"
#import "VDModalInfo.h"
#import "CDFeed.h"
#import "CDEpisode.h"

@implementation PlayerSpeedButton {
    BOOL        _observing;
    BOOL        _observingSilenceTrim;
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
        [self _updateSpeedMenu];
        if (!_observingSilenceTrim) {
            _observingSilenceTrim = YES;
            __weak PlayerSpeedButton* weakSelf = self;
            [USER_DEFAULTS addTaskObserver:self forKeyPath:PlayerSilenceTrimEnabled task:^(id obj, NSDictionary *change) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf _updateSpeedMenu];
                });
            }];
        }
    }
    else
    {
        if (_observing) {
            [[PlaybackManager playbackManager] removeTaskObserver:self forKeyPath:@"speedControl"];
            _observing = NO;
        }
        if (_observingSilenceTrim) {
            [USER_DEFAULTS removeTaskObserver:self forKeyPath:PlayerSilenceTrimEnabled];
            _observingSilenceTrim = NO;
        }
    }
}

#pragma mark - Speed menu (pause shortening enabled)

// With pause shortening enabled in the playback settings the button opens a menu like the sleep
// timer: speeds in one section, the pause shortening strength in another. Without it the button
// keeps cycling through the speeds on tap and resets to 1x on long press.
- (BOOL) _usesSpeedMenu
{
    return [USER_DEFAULTS boolForKey:PlayerSilenceTrimEnabled];
}

- (void) _updateSpeedMenu
{
    if ([self _usesSpeedMenu]) {
        __weak PlayerSpeedButton* weakSelf = self;
        UIDeferredMenuElement* content = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement*>*)) {
            completion([weakSelf _speedMenuSections] ?: @[]);
        }];
        self.menu = [UIMenu menuWithTitle:@"" children:@[content]];
        self.showsMenuAsPrimaryAction = YES;
    } else if (self.menu) {
        self.showsMenuAsPrimaryAction = NO;
        self.menu = nil;
    }
}

- (NSArray<UIMenuElement*>*) _speedMenuSections
{
    PlaybackManager* pman = [PlaybackManager playbackManager];

    NSMutableArray<NSNumber*>* speeds = [[PlayerSpeedButton enabledSpeedControls] mutableCopy];
    if (![speeds containsObject:@(pman.speedControl)]) {
        [speeds addObject:@(pman.speedControl)];
        NSArray* ordered = [PlayerSpeedButton allSpeedControlsOrdered];
        [speeds sortUsingComparator:^NSComparisonResult(NSNumber* a, NSNumber* b) {
            return [@([ordered indexOfObject:a]) compare:@([ordered indexOfObject:b])];
        }];
    }
    NSMutableArray<UIMenuElement*>* speedActions = [NSMutableArray array];
    for (NSNumber* speed in speeds) {
        PlaybackSpeedControl control = speed.integerValue;
        NSString* title = [PlayerSpeedButton titleForSpeedControl:control];
        UIAction* action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction* a) {
            [PlaybackManager playbackManager].speedControl = control;
            PlayHapticFeedback(ICHapticFeedbackLight);
            NSString* announcement = [NSString stringWithFormat:@"Playback set to %@ speed.".ls, title];
            UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, announcement);
        }];
        action.state = (control == pman.speedControl) ? UIMenuElementStateOn : UIMenuElementStateOff;
        [speedActions addObject:action];
    }
    UIMenu* speedSection = [UIMenu menuWithTitle:@"Playback Speed".ls image:nil identifier:nil
                                         options:UIMenuOptionsDisplayInline children:speedActions];

    CDEpisode* episode = pman.playingEpisode;
    CDFeed* feed = episode.feed;
    NSInteger currentLevel = episode ? [pman silenceTrimLevelForEpisode:episode] : [USER_DEFAULTS integerForKey:PlayerSilenceTrimLevel];
    NSString* status = [pman silenceTrimStatusText];
    NSMutableArray<UIMenuElement*>* trimActions = [NSMutableArray array];
    for (NSNumber* levelNumber in @[@0, @1, @2, @3]) {
        NSInteger level = levelNumber.integerValue;
        UIAction* action = [UIAction actionWithTitle:[PlaybackManager titleForSilenceTrimLevel:level] image:nil identifier:nil handler:^(UIAction* a) {
            [PlaybackManager storeSilenceTrimLevel:level forFeed:feed];
            PlayHapticFeedback(ICHapticFeedbackLight);
            [[PlaybackManager playbackManager] silenceTrimSettingsDidChange];
        }];
        action.state = (level == currentLevel) ? UIMenuElementStateOn : UIMenuElementStateOff;
        if (level == currentLevel && level > 0 && status.length > 0) {
            action.subtitle = status;
        }
        [trimActions addObject:action];
    }
    UIMenu* trimSection = [UIMenu menuWithTitle:@"Shorten Pauses".ls image:nil identifier:nil
                                        options:UIMenuOptionsDisplayInline children:trimActions];
    return @[speedSection, trimSection];
}

// Like the sleep timer button: the menu grows out of the button instead of its trailing edge.
- (CGPoint)menuAttachmentPointForConfiguration:(UIContextMenuConfiguration *)configuration
{
    return CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMinY(self.bounds));
}

- (void) tintColorDidChange
{
    if ([PlaybackManager playbackManager].speedControl == PlaybackSpeedControlNormalSpeed) {
        [self setTitleColor:self.tintColor forState:UIControlStateNormal];
        [self setTitleColor:self.tintColor forState:UIControlStateHighlighted];
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    if (self.showsMenuAsPrimaryAction) {
        return [super beginTrackingWithTouch:touch withEvent:event];
    }
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
    if (self.showsMenuAsPrimaryAction) {
        [_longTrackingTimer invalidate];
        _longTrackingTimer = nil;
        _trackingDate = nil;
        return;
    }
    
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
