//
//  InstacastAppDelegate.h
//  Instacast
//
//  Created by Martin Hering on 22.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN


@class MainViewController_4;

@interface InstacastAppDelegate : NSObject <UIApplicationDelegate>

@property (nonatomic, strong, nullable) IBOutlet UIWindow *window;
@property (nonatomic, strong, nullable) MainViewController_4* mainViewController;



- (void) setNeedsStatusBarAppearanceUpdate;
- (nullable UIViewController*)getRootViewControllerDev;
+ (UIViewController*)databaseUnavailableViewControllerForError:(NSError*)error;
@end

NS_ASSUME_NONNULL_END
