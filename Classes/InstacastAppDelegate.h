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
/// YES only after a BGContinuedProcessingTask launch handler was accepted by iOS.
/// Submitting a continued request without an accepted handler throws
/// NSInternalInconsistencyException, so every caller must check this first.
@property (nonatomic, readonly) BOOL transcriptionContinuedTasksAvailable;



- (void) setNeedsStatusBarAppearanceUpdate;
- (nullable UIViewController*)getRootViewControllerDev;
+ (UIViewController*)databaseUnavailableViewControllerForError:(NSError*)error;
- (void)handleNotificationResponse:(UNNotificationResponse*)response
                 completionHandler:(nullable void (^)(void))completionHandler;
- (void)setNotificationSceneReady:(BOOL)ready;
/// Identifier for the next BGContinuedProcessingTaskRequest, or nil when no
/// launch handler is registered. Matches the registration form iOS accepted.
- (nullable NSString*)newTranscriptionContinuedTaskIdentifier;
@end

NS_ASSUME_NONNULL_END
