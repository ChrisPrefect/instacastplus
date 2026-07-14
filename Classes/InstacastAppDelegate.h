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
@class UNNotificationResponse;

FOUNDATION_EXPORT NSNotificationName const InstacastDatabaseStartupDidFailNotification;

typedef NS_ENUM(NSInteger, ICDatabaseStartupState) {
    ICDatabaseStartupStateNotStarted = 0,
    ICDatabaseStartupStatePreparing,
    ICDatabaseStartupStateReady,
    ICDatabaseStartupStateFailed,
};

@interface InstacastAppDelegate : NSObject <UIApplicationDelegate>

@property (nonatomic, strong, nullable) IBOutlet UIWindow *window;
@property (nonatomic, strong, nullable) MainViewController_4* mainViewController;
@property (nonatomic, readonly) ICDatabaseStartupState databaseStartupState;
@property (nonatomic, strong, readonly, nullable) NSError* databasePreparationError;



- (void) setNeedsStatusBarAppearanceUpdate;
- (nullable UIViewController*)getRootViewControllerDev;
+ (UIViewController*)databaseUnavailableViewControllerForError:(NSError*)error;
- (void)handleNotificationResponse:(UNNotificationResponse*)response
                 completionHandler:(nullable void (^)(void))completionHandler;
- (void)setNotificationSceneReady:(BOOL)ready;
@end

NS_ASSUME_NONNULL_END
