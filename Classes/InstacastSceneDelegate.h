//
//  InstacastSceneDelegate.h
//  Instacast
//
//  Created by Devendra Kamal on 02/11/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>

NS_ASSUME_NONNULL_BEGIN

@interface InstacastSceneDelegate : UIResponder <UIWindowSceneDelegate, CPTemplateApplicationSceneDelegate>

@property (strong, nonatomic) UIWindow *window;
@property (nonatomic, strong) CPInterfaceController *interfaceController;


@end

NS_ASSUME_NONNULL_END
