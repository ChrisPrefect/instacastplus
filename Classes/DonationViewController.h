//
//  DonationViewController.h
//  Instacast
//
//  Created by Chris Thomann on 09.02.26.
//  Copyright (c) 2026 Instacast. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <StoreKit/StoreKit.h>

@interface DonationViewController : UITableViewController <SKProductsRequestDelegate, SKPaymentTransactionObserver>

+ (DonationViewController *)viewController;

@end
