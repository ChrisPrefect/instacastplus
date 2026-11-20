//
//  PlaybackSettingsViewController.h
//  Instacast
//

#import <UIKit/UIKit.h>

@interface PlaybackSettingsViewController : UITableViewController

+ (PlaybackSettingsViewController*) viewController;
// Explanations of the pause shortening levels 0-3, shared with the podcast settings.
+ (NSArray<NSString*>*) silenceTrimLevelFooterTexts;

@end
