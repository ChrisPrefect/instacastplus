//
//  StatusBarFixingViewController.m
//  Instacast
//
//  Created by Martin Hering on 26.07.14.
//
//

#import "StatusBarFixingViewController.h"

@interface StatusBarFixingViewController ()

@end

@implementation StatusBarFixingViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateAppearance];
}

-(void) updateAppearance {
    self.view.backgroundColor = ICBackgroundColor;
}

- (UIViewController*) childViewControllerForStatusBarStyle {
    return [self.childViewControllers firstObject];
}

- (UIViewController*) childViewControllerForStatusBarHidden {
    return [self.childViewControllers firstObject];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
