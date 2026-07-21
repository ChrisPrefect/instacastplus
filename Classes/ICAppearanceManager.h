//
//  ICAppearanceManager.h
//  Instacast
//
//  Created by Martin Hering on 26.07.14.
//
//

#import <Foundation/Foundation.h>
#import "Defines.h"

@protocol ICAppearance <NSObject>
@property (nonatomic, readonly) UIColor* tintColor;
@property (nonatomic, readonly) UIColor* textColor;
@property (nonatomic, readonly) UIColor* mutedTextColor;
@property (nonatomic, readonly) UIColor* placeholderTextColor;
@property (nonatomic, readonly) UIColor* backgroundColor;
@property (nonatomic, readonly) UIColor* lightBackgroundColor;
@property (nonatomic, readonly) UIColor* darkBackgroundColor;
@property (nonatomic, readonly) UIColor* transparentBackdropColor;
@property (nonatomic, readonly) UIColor* tableSeparatorColor;
@property (nonatomic, readonly) UIColor* tableSelectedBackgroundColor;
@property (nonatomic, readonly) UIColor* groupCellBackgroundColor;
@property (nonatomic, readonly) UIColor* groupCellSelectedBackgroundColor;
@property (nonatomic, readonly) UIStatusBarStyle statusBarStyle;
@property (nonatomic, readonly) UIScrollViewIndicatorStyle scrollIndicatorStyle;
@property (nonatomic, readonly) NSString* cssFile;
@property (nonatomic, readonly) UIKeyboardAppearance keyboardAppearance;
@property (nonatomic, readonly) UIActivityIndicatorViewStyle activityIndicatorStyle;
@end

extern NSString* ICAppearanceManagerDidUpdateAppearanceNotification;

// ICTintColor serves the theme color from a cache. Call after writing a new theme
// color to the defaults; -updateAppearance already does it.
extern void ICInvalidateThemeTintColorCache(void);


@interface ICAppearanceManager : NSObject

+ (instancetype) sharedManager;

@property (nonatomic, strong) id<ICAppearance> appearance;

@property (nonatomic) ICAppearanceMode appearanceMode;
@property (nonatomic, readonly) BOOL nightSettingMode;  // Returns current dark mode state
@property (nonatomic, readonly) BOOL nightMode;         // Alias for nightSettingMode
@property (nonatomic, readonly) CGFloat fontSizeScale;  // 1.0 normal, 1.2 larger

- (void) updateAppearance;
- (void) updateThemeTintColor;
- (UIImage*) navigationBarBackgroundImage;

@end

#define ICTintColor                         ([ICAppearanceManager sharedManager].appearance.tintColor)
#define ICTextColor                         ([ICAppearanceManager sharedManager].appearance.textColor)
#define ICMutedTextColor                    ([ICAppearanceManager sharedManager].appearance.mutedTextColor)
#define ICPlaceholderTextColor              ([ICAppearanceManager sharedManager].appearance.placeholderTextColor)
#define ICBackgroundColor                   ([ICAppearanceManager sharedManager].appearance.backgroundColor)
#define ICTableSeparatorColor               ([ICAppearanceManager sharedManager].appearance.tableSeparatorColor)
#define ICTableSelectedBackgroundColor      ([ICAppearanceManager sharedManager].appearance.tableSelectedBackgroundColor)
#define ICTransparentBackdropColor          ([ICAppearanceManager sharedManager].appearance.transparentBackdropColor)
#define ICLightBackgroundColor               ([ICAppearanceManager sharedManager].appearance.lightBackgroundColor)
#define ICDarkBackgroundColor               ([ICAppearanceManager sharedManager].appearance.darkBackgroundColor)
#define ICGroupCellBackgroundColor          ([ICAppearanceManager sharedManager].appearance.groupCellBackgroundColor)
#define ICGroupCellSelectedBackgroundColor  ([ICAppearanceManager sharedManager].appearance.groupCellSelectedBackgroundColor)

// Font size scaling — central scale factors per level
static const CGFloat kICFontSizeScaleFactors[] = { 1.0, 1.1, 1.2, 1.3 };
#define ICFontSize(baseSize) ((baseSize) * [ICAppearanceManager sharedManager].fontSizeScale)

@interface ICDaylightAppearance : NSObject <ICAppearance>
@end


@interface ICNightAppearance : NSObject <ICAppearance>
@end

// Central window subclass that detects OS theme changes at the window level.
// This fires regardless of which VC is presented (including full-screen modals).
@interface ICWindow : UIWindow
@end
