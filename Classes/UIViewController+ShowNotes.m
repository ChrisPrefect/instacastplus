//
//  UIViewController+ShowNotes.m
//  Instacast
//
//  Created by Martin Hering on 05.11.12.
//
//

#import "UIViewController+ShowNotes.h"

#import "WebController.h"
#import "VDModalInfo.h"
#import "UtilityFunctions.h"

#import <StoreKit/StoreKit.h>

@interface UIViewController () <SKStoreProductViewControllerDelegate>

@end


@implementation UIViewController (ShowNotes)

- (BOOL) handleShowNotesURL:(NSURL*)url
{
    NSString* urlString = [url absoluteString];

	if ([urlString isEqualToString:@"about:blank"]) {
		return YES;
	}


	if ([url scheme] && ![[url scheme] hasPrefix:@"http"]) {
		[[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
		return NO;
	}

    NSArray* hostToBeRedirected = @[
    @"twitter",
    @"x.com",
    @"youtube",
    @"maps.apple.com",
    @"phobos.apple.com",
    ];

    for(NSString* host in hostToBeRedirected) {
        if ([url host] && [[url host] rangeOfString:host].location != NSNotFound) {
            DebugLog(@"external link %@", urlString);
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return NO;
        }
    }


	NSArray* mediaSuffixes = [NSArray arrayWithObjects:@"mp3",@"m4a",@"mp4",@"mp4",nil];
	if ([[url path] pathExtension] && [mediaSuffixes containsObject:[[url path] pathExtension]]) {
		DebugLog(@"media link %@", urlString);
        [App openURL:url options:@{} completionHandler:nil];
		return NO;
	}

    // Parse App Store Links
    if ([[url host] isEqualToString:@"itunes.apple.com"])
    {
        NSString* productId = [[url path] stringByMatchingRegex:@"/id(\\d+)" capture:1];
        NSString* mt = [[url queryParameters] objectForKey:@"mt"];
        if (productId && (!mt || ![mt isEqualToString:@"12"])) // 12: don't handle Mac App Store Links
        {
            VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Loading…".ls];
            [modelInfo show];

            SKStoreProductViewController* storeController = [[SKStoreProductViewController alloc] init];
            storeController.delegate = self;

            NSMutableDictionary* storeParams = [@{ SKStoreProductParameterITunesItemIdentifier : productId } mutableCopy];
            storeParams[SKStoreProductParameterAffiliateToken] = @"11lKc8";
            storeParams[SKStoreProductParameterCampaignToken] = @"instacast-app";
            [storeController loadProductWithParameters:storeParams
                                       completionBlock:^(BOOL result, NSError *error) {

                                           if (result) {
                                               [self presentViewController:storeController animated:YES completion:^{
                                                   [modelInfo close];
                                               }];
                                           }
                                           else
                                           {
                                               [modelInfo close];
                                           }
                                       }];
            return NO;
        }
    }

    DebugLog(@"website link %@",urlString);

    if ([USER_DEFAULTS boolForKey:OpenLinksInExternalBrowser]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        return NO;
    }

    WebController* webController = [WebController webController];
    webController.url = url;

    // Present in own UINavigationController (fullScreen) to isolate Liquid Glass state
    UINavigationController* webNavController = [[UINavigationController alloc] initWithRootViewController:webController];
    webNavController.modalPresentationStyle = UIModalPresentationFullScreen;
    webNavController.view.backgroundColor = ICBackgroundColor;
    webNavController.view.tintColor = ICTintColor;

    // Toolbar-Appearance
    UIToolbarAppearance *toolbarAppearance = [[UIToolbarAppearance alloc] init];
    [toolbarAppearance configureWithOpaqueBackground];
    toolbarAppearance.backgroundColor = ICBackgroundColor;
    toolbarAppearance.shadowColor = [UIColor clearColor];
    webNavController.toolbar.standardAppearance = toolbarAppearance;
    webNavController.toolbar.scrollEdgeAppearance = toolbarAppearance;
    webNavController.toolbar.compactAppearance = toolbarAppearance;
    webNavController.toolbar.compactScrollEdgeAppearance = toolbarAppearance;

    UIViewController* presenter = ([self isKindOfClass:[UINavigationController class]]) ? self : (self.navigationController ?: self);
    [presenter presentViewController:webNavController animated:YES completion:nil];

    return NO;
}

- (void)productViewControllerDidFinish:(SKStoreProductViewController *)viewController
{
    [viewController dismissViewControllerAnimated:NO completion:^{

    }];
}


@end
