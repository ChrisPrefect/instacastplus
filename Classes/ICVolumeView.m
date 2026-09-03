//
//  ICVolumeView.m
//  Instacast
//
//  Created by Martin Hering on 22.08.13.
//
//

#import "ICVolumeView.h"

// AVRoutePickerView has no image API — its glyph scales with the view's bounds. Measured
// in the simulator (iPhone 17 Pro): glyph ≈ 0.83 * bounds - 17, clamped at ~18pt below
// ~42pt bounds. 84pt (the raw tool slot the picker was dropped into) rendered a 52.7pt
// glyph next to ~25pt neighbours — that was the "AirPlay icon is twice as big" report.
// 50pt yields 23.3pt, matching speed (25.0pt), sleep timer (24.7pt) and bookmark (26.3pt).
static CGFloat const ICVolumeRoutePickerSize = 50.f;

@interface ICVolumeView ()
@property (nonatomic, strong, readwrite) AVRoutePickerView* routePickerView;
@end

@implementation ICVolumeView

- (instancetype) initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        AVRoutePickerView* routePickerView = [[AVRoutePickerView alloc] initWithFrame:CGRectZero];
        routePickerView.backgroundColor = [UIColor clearColor];
        [self addSubview:routePickerView];
        _routePickerView = routePickerView;
    }
    return self;
}

- (void) layoutSubviews
{
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    self.routePickerView.frame = CGRectMake(round((CGRectGetWidth(bounds) - ICVolumeRoutePickerSize) / 2.f),
                                            round((CGRectGetHeight(bounds) - ICVolumeRoutePickerSize) / 2.f),
                                            ICVolumeRoutePickerSize,
                                            ICVolumeRoutePickerSize);
}

// The glyph only occupies the centre of the tool slot, but the neighbouring tool buttons are
// 84x84 hit targets — keep the whole slot tappable instead of shrinking the target to 30pt.
- (UIView*) hitTest:(CGPoint)point withEvent:(UIEvent*)event
{
    UIView* hitView = [super hitTest:point withEvent:event];
    if (hitView != self) {
        return hitView;
    }

    AVRoutePickerView* picker = self.routePickerView;
    CGPoint pickerCenter = CGPointMake(CGRectGetMidX(picker.bounds), CGRectGetMidY(picker.bounds));
    return [picker hitTest:pickerCenter withEvent:event] ?: picker;
}

- (void) setActiveTintColor:(UIColor*)activeTintColor
{
    _activeTintColor = activeTintColor;
    self.routePickerView.activeTintColor = activeTintColor;
}

- (void) setPrioritizesVideoDevices:(BOOL)prioritizesVideoDevices
{
    _prioritizesVideoDevices = prioritizesVideoDevices;
    self.routePickerView.prioritizesVideoDevices = prioritizesVideoDevices;
}

@end
