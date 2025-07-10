//
//  SettingInputChapterController.m
//  Instacast
//
//  Created by Vinh Huynh on 12/1/25.
//  Copyright © 2025 Vemedio. All rights reserved.
//

#import "SettingInputChapterController.h"
#import "SkipTimeCell.h"

@interface SettingInputChapterController () <UITextFieldDelegate>

@end

@implementation SettingInputChapterController
@synthesize chapterKey;

+ (SettingInputChapterController*) inputSampleViewController
{
    return [[self alloc] init];
}


- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Register a basic cell class
    NSLog(@"CHAPTER KEY====%@",self.chapterKey);
    NSLog(@"FEED UID====%@",self.feed.uid);
    [self.tableView registerNib:[UINib nibWithNibName:@"SkipTimeCell" bundle:nil] forCellReuseIdentifier:@"SkipTimeCell"];
    //[self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
    self.navigationItem.title =  self.feed.title;
    self.navigationItem.prompt = nil;
    self.tableView.delaysContentTouches = NO;
    self.tableView.allowsSelection = NO;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        self.tableView.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:1.0];
        self.tableView.separatorColor = [UIColor grayColor];
        self.navigationController.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName : [UIColor whiteColor]};
        
    }
    else
    {
        self.tableView.backgroundColor = ICBackgroundColor;
        self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
        self.navigationController.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName : [UIColor blackColor]};
        
    }
    
    // Add tap gesture to dismiss keyboard
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    tapGesture.cancelsTouchesInView = NO; // Allow other interactions (e.g., stepper)
    [self.tableView addGestureRecognizer:tapGesture];
}

- (void)handleTap:(UITapGestureRecognizer *)sender {
    [self.view endEditing:YES]; // Dismiss keyboard
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    SkipTimeCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SkipTimeCell" forIndexPath:indexPath];
    
    BOOL isNightMode = [ICAppearanceManager sharedManager].nightSettingMode;
    cell.titleLbl.textColor = isNightMode ? [UIColor whiteColor] : [UIColor blackColor];
    cell.timeTF.textColor = ICMutedTextColor;
    cell.secondsLbl.textColor = ICMutedTextColor;
    
    double period = [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_%@_chapter_%@", self.feed.uid, (indexPath.row == 0 ? @"start" : @"end"), self.chapterKey]];
    cell.timeTF.text = [NSString stringWithFormat:@"%.1f", period];
    cell.timeTF.delegate = self;
    cell.secondsLbl.text = @"Seconds".ls;
    
    if (indexPath.row == 0) {
        cell.titleLbl.text = @"Skip intro".ls;
        [self configureStepper:cell.stepperView forStart:YES];
    } else {
        cell.titleLbl.text = @"Skip outro".ls;
        [self configureStepper:cell.stepperView forStart:NO];
    }
    
    //NSLog(@"Cell titleLabel color after configuration: %@", cell.titleLbl.textColor);
    
    return cell;
}

- (void)configureStepper:(UIStepper *)stepper forStart:(BOOL)isStart {
    stepper.stepValue = 0.1;
    stepper.tag = isStart ? 0 : 1;
    
    double period = isStart ?
        [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey]] :
        [self.feed doubleForKey:[NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey]];
    
    stepper.minimumValue = -300.0;
    stepper.maximumValue = 300.0;
    stepper.value = period;
    
    BOOL isNightMode = [ICAppearanceManager sharedManager].nightSettingMode;
    UIColor *colorTemp = isNightMode ? [UIColor whiteColor] : [UIColor blackColor];
    stepper.tintColor = colorTemp;
    UIImage *plusImage = [[UIImage systemImageNamed:@"plus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *minusImage = [[UIImage systemImageNamed:@"minus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    
    [stepper setIncrementImage:plusImage forState:UIControlStateNormal];
    [stepper setDecrementImage:minusImage forState:UIControlStateNormal];
    
    [stepper addTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
}

- (void)stepperValueChanged:(UIStepper *)sender {
    NSString *key = (sender.tag == 0) ?
        [NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey] :
        [NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey];

    double newValue = sender.value;
    //NSLog(@"Stepper value changed to: %.1f for key: %@", newValue, key);

    if (self.feed) {
        [[self source] setDouble:newValue forKey:key];
    }

    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:sender.tag inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSString *newText = [textField.text stringByReplacingCharactersInRange:range withString:string];
    
    if (newText.length == 0) {
        return YES;
    }
    
    // Validate decimal format
    NSString *decimalRegex = @"^-?\\d*\\.?\\d{0,1}$";
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", decimalRegex];
    if (![predicate evaluateWithObject:newText]) {
        return NO;
    }
    
    // Validate range (-300.0 to 300.0)
    double value = [newText doubleValue];
    if (value < -300.0 || value > 300.0) {
        return NO;
    }
    
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    SkipTimeCell *cell = (SkipTimeCell *)textField.superview.superview;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;
    
    NSString *key = (indexPath.row == 0) ?
        [NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey] :
        [NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey];
    
    double newValue = [textField.text doubleValue];
    newValue = MIN(MAX(newValue, -300.0), 300.0);
    
    if (self.feed) {
        [[self source] setDouble:newValue forKey:key];
    }
    
    cell.stepperView.value = newValue;
    
    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}


- (id) source
{
    return (self.feed) ? self.feed : USER_DEFAULTS;
}

@end
