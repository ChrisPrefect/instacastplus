//
//  WebController.h
//  Instacast
//
//  Created by Martin Hering on 13.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <MessageUI/MessageUI.h>
#import "WebKit/WebKit.h"


@interface WebController : UIViewController <WKNavigationDelegate, MFMailComposeViewControllerDelegate>

+ (WebController*) webController;

@property (nonatomic, strong) NSURL* url;
@property (nonatomic, readonly, strong) WKWebView* webView;

@end
