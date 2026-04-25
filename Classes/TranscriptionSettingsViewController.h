//
//  TranscriptionSettingsViewController.h
//  Instacast
//
//  Settings for "Transkription und Kapitel".
//

#import <UIKit/UIKit.h>

@interface TranscriptionSettingsViewController : UITableViewController
+ (UIViewController *)modelLibraryViewController;
+ (UIViewController *)modelLibraryViewControllerFocusedOnVoiceToText:(BOOL)voiceToText;
@end
