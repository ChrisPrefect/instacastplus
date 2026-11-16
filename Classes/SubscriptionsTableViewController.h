//
//  SubscriptionsTableViewController.h
//  Instacast
//
//  Created by Martin Hering on 28.12.10.
//  Copyright 2010 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>

// Identifies the floating "+" button (iOS 26 and later), e.g. for the onboarding hint.
extern NSString* const ICSubscriptionsAddButtonAccessibilityIdentifier;
// Posted when the floating "+" button is on screen (iOS 26 and later).
extern NSString* const ICSubscriptionsAddButtonDidAppearNotification;

@interface SubscriptionsTableViewController : UITableViewController

+ (SubscriptionsTableViewController*) subscriptionsController;

- (void) showEpisodeListForFeed:(CDFeed*)feed animated:(BOOL)animated;
@end
