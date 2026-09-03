//
//  ICVolumeView.h
//  Instacast
//
//  Created by Martin Hering on 22.08.13.
//
//

#import <AVKit/AVKit.h>

// AVRoutePickerView has no image API and scales its glyph to the view's bounds, while every
// neighbouring player tool button draws a fixed-point-size SF Symbol. Dropped straight into
// the 84x84 tool slot the AirPlay icon therefore rendered several times too large (the
// MPVolumeView it replaced was given an explicit 26pt image). This wraps the picker: the
// container keeps the full tool slot for layout and hit testing, the picker inside stays at
// glyph size.
@interface ICVolumeView : UIView

@property (nonatomic, strong, readonly) AVRoutePickerView* routePickerView;

// Forwarded to the wrapped picker.
@property (nonatomic, strong) UIColor* activeTintColor;
@property (nonatomic, assign) BOOL prioritizesVideoDevices;

@end
