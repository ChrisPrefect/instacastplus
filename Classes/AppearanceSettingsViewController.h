//
//  AppearanceSettingsViewController.h
//  Instacast
//

#import <UIKit/UIKit.h>

@interface AppearanceSettingsViewController : UITableViewController<UIColorPickerViewControllerDelegate>
{
    NSArray* appIconsArray;
    UIColor* selectedThemeColor;
    UIColor* selectedPlayerColor;
    BOOL isPlayerColorSelected;
}

+ (AppearanceSettingsViewController*) viewController;

@end
