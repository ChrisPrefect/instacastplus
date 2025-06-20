//
//  InstacastSceneDelegate.h
//  Instacast
//
//  Created by Devendra Kamal on 02/11/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <CarPlay/CarPlay.h>
#import <StoreKit/StoreKit.h>

NS_ASSUME_NONNULL_BEGIN
@class MainViewController_4;

@interface InstacastSceneDelegate : UIResponder <UIWindowSceneDelegate, CPTemplateApplicationSceneDelegate, SKProductsRequestDelegate,SKPaymentTransactionObserver>
{
    SKProductsRequest *productsRequest;
    NSMutableDictionary *validProducts;
    UIActivityIndicatorView *activityIndicatorView;
}

@property (strong, nonatomic) UIWindow *window;
@property (nonatomic, strong) CPInterfaceController *interfaceController;
@property (nonatomic, strong) MainViewController_4* mainViewController;
- (void)fetchAvailableProducts;
- (BOOL)canMakePurchases;
- (void)purchaseMyProduct:(SKProduct*)product;

@end

NS_ASSUME_NONNULL_END
