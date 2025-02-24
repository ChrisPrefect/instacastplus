//
//  InstacastSceneDelegate.m
//  Instacast
//
//  Created by Devendra Kamal on 02/11/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import "InstacastSceneDelegate.h"
#import "MainViewController_4.h"
#import "InstacastAppDelegate.h"
#import <CarPlay/CarPlay.h>

@implementation InstacastSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
    // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
    // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
    if ([scene isKindOfClass:[UIWindowScene class]]) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
        self.window.backgroundColor = ICBackgroundColor;
        
        if ([DatabaseManager dataStoreNeedsMigration]) {
            UIViewController* migrationViewController = [[UIViewController alloc] initWithNibName:@"DataMigrationView" bundle:nil];
            self.window.rootViewController = migrationViewController;
            ((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window = self.window;
            [((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window makeKeyAndVisible];
        }
        else
        {
            MainViewController_4* mainViewController = [MainViewController_4 mainViewController];
            [UIManager sharedManager].mainViewController = mainViewController;
            self.window.rootViewController = mainViewController;
            ((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window = self.window;
            [((InstacastAppDelegate *)[UIApplication sharedApplication].delegate).window makeKeyAndVisible];
        }
    }
//    if ([scene isKindOfClass:[CPTemplateApplicationScene class]]) {
//        CPTemplateApplicationScene *carPlayScene = (CPTemplateApplicationScene *)scene;
//        carPlayScene.delegate = self;
//        
//        // Create an empty CPListTemplate to act as a placeholder
//        CPListTemplate *placeholderTemplate = [[CPListTemplate alloc] initWithTitle:@"DNow Playing" sections:@[]];
//        
//        // Set the placeholder template as the root
//        [carPlayScene.interfaceController setRootTemplate:placeholderTemplate animated:YES];
//    }
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    // Called as the scene is being released by the system.
    // This occurs shortly after the scene enters the background, or when its session is discarded.
    // Release any resources associated with this scene that can be re-created the next time the scene connects.
    // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
}


- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Called when the scene has moved from an inactive state to an active state.
    // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
}


- (void)sceneWillResignActive:(UIScene *)scene {
    // Called when the scene will move from an active state to an inactive state.
    // This may occur due to temporary interruptions (ex. an incoming phone call).
}


- (void)sceneWillEnterForeground:(UIScene *)scene {
    // Called as the scene transitions from the background to the foreground.
    // Use this method to undo the changes made on entering the background.
}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    // Called as the scene transitions from the foreground to the background.
    // Use this method to save data, release shared resources, and store enough scene-specific state information
    // to restore the scene back to its current state.
    
    // Save changes in the application's managed object context when the application transitions to the background.
}

- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene  didConnectInterfaceController:(CPInterfaceController *)interfaceController {
    
    self.interfaceController = interfaceController;
    if (@available(iOS 14.0, *)) {
        CPNowPlayingTemplate *nowPlayingTemplate = [CPNowPlayingTemplate sharedTemplate];
        [interfaceController setRootTemplate:nowPlayingTemplate animated:YES];
    } else {
        // Fallback on earlier versions
    }
}



- (void)templateApplicationScene:(CPTemplateApplicationScene *)templateApplicationScene didDisconnectInterfaceController:(CPInterfaceController *)interfaceController {
    self.interfaceController = nil;
}

@end
