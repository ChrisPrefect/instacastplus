//
//  OnboardScreenVC.m
//  Instacast
//
//  Created by Devendra Kamal on 15/08/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import "OnboardScreenVC.h"

@interface OnboardScreenVC ()
@end

@implementation OnboardScreenVC

@synthesize delegate;

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.
    
    self.descLabel.text = @"to add podcasts, search the podcast directory".ls;
    self.shadowView.userInteractionEnabled = YES;
    UITapGestureRecognizer *tapGesture1 = [[UITapGestureRecognizer alloc] initWithTarget:self  action:@selector(tapGesture:)];
    tapGesture1.numberOfTapsRequired = 1;
    [self.shadowView addGestureRecognizer:tapGesture1];
    self.shadowView.backgroundColor = [UIColor blackColor];
    self.shadowView.alpha = 0.5;
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if ([UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)
    {
        self.arrowImage.image = [UIImage imageNamed:@"onboard_arrow_wh"];
        self.descLabel.textColor = [UIColor whiteColor];
    }
    else
    {
        self.arrowImage.image = [UIImage imageNamed:@"onboard_arrow_bl"];
        self.descLabel.textColor = [UIColor blackColor];
    }
    UIToolbar *toolbar = [[UIToolbar alloc] init]; //initWithFrame:CGRectMake(0, self.view.bounds.size.height - 44, self.view.bounds.size.width, 44)];
    toolbar.barStyle = UIBarStyleDefault;
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;

    [toolbar setBackgroundImage:[UIImage new] forToolbarPosition:UIBarPositionAny barMetrics:UIBarMetricsDefault];
    toolbar.tintColor = ICTintColor;

    //
    // Create a button instead of UIImageView
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    
    // Load image and set rendering mode to template
    UIImage *addImage = [[UIImage imageNamed:@"Toolbar Add"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [button setImage:addImage forState:UIControlStateNormal];
    
    // Set tint color
    button.tintColor = ICTintColor; // Change as needed
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    
    // Adjust button size to fit the image properly
    button.frame = CGRectMake(0, 0, 30, 30); // Ensure it's square
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 0); // Prevent shifting
    
    // Add target action
    [button addTarget:self action:@selector(addAction:) forControlEvents:UIControlEventTouchUpInside];
    
    // Add shadow effect to the button
    button.layer.shadowColor = [UIColor whiteColor].CGColor;
    button.layer.shadowOffset = CGSizeMake(0, 0);
    button.layer.shadowOpacity = 0.9;
    button.layer.shadowRadius = 3;
    button.layer.masksToBounds = NO;
    
    // Wrap button in a stack view to fix alignment
    UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[button]];
    stackView.axis = UILayoutConstraintAxisHorizontal;
    stackView.alignment = UIStackViewAlignmentCenter;
    stackView.spacing = 0; // No extra space
    
    // Create UIBarButtonItem with the custom view
    UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithCustomView:stackView];

    //UIBarButtonItem* addItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Toolbar Add"] style:UIBarButtonItemStylePlain target:self action:@selector(addAction:)];
    
    UIBarButtonItem* flexSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    [toolbar setItems:@[addItem, flexSpace] animated:YES];
    [self.view addSubview:toolbar];

    // Use Auto Layout to position the toolbar at the bottom with safe area insets
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [toolbar.heightAnchor constraintEqualToConstant:44]
    ]];
    // (0 793; 414 49);

}

- (void) addAction:(id)sender
{
    [self dismissViewControllerAnimated:NO completion:^{
        [self.delegate plusButtonPressDelegateMethod:self];
    }];
}

- (void) tapGesture: (id)sender
{
    [self dismissViewControllerAnimated:NO completion:nil];
}

-(IBAction)plusButtonPressed:(id)sender 
{
    [self dismissViewControllerAnimated:NO completion:^{
        [self.delegate plusButtonPressDelegateMethod:self];
    }];
    
}



@end
