//
//  OptionsViewController.h
//  Instacast
//
//  Created by Martin Hering on 07.11.11.
//  Copyright (c) 2011 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <StoreKit/StoreKit.h>

@interface OptionsViewController : UITableViewController<SKProductsRequestDelegate,SKPaymentTransactionObserver> 
{
    BOOL _observing;
    SKProductsRequest *productsRequest;
    NSMutableDictionary *validProducts;
    UIActivityIndicatorView *activityIndicatorView;
}

+ (OptionsViewController*) optionsViewController;
- (void)fetchAvailableProducts;
- (BOOL)canMakePurchases;
- (void)purchaseMyProduct:(SKProduct*)product;

@end
