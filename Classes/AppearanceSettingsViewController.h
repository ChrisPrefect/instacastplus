//
//  AppearanceSettingsViewController.h
//  Instacast
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, ColorPickerTarget) {
    ColorPickerTargetPlayer,
    ColorPickerTargetInterface,
    ColorPickerTargetWidget
};

@interface AppearanceSettingsViewController : UITableViewController<UIColorPickerViewControllerDelegate>
{
    NSArray* appIconsArray;
    UIColor* selectedThemeColor;
    UIColor* selectedPlayerColor;
    UIColor* selectedWidgetColor;
    ColorPickerTarget colorPickerTarget;
}

+ (AppearanceSettingsViewController*) viewController;

@end
