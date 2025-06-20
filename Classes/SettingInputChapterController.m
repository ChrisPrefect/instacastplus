//
//  SettingInputChapterController.m
//  Instacast
//
//  Created by Vinh Huynh on 12/1/25.
//  Copyright © 2025 Vemedio. All rights reserved.
//

#import "SettingInputChapterController.h"

@interface SettingInputChapterController ()

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
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
    self.navigationItem.title =  self.feed.title;
    self.navigationItem.prompt = nil;
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
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    //UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    NSString *DetailCellIdentifier = @"detailStepperCell";
    
    UITableViewCell *cell = [self.tableView dequeueReusableCellWithIdentifier:DetailCellIdentifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:DetailCellIdentifier];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectedBackgroundView = [[UIView alloc] init];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    cell.textLabel.textColor = ICTextColor;
    cell.detailTextLabel.textColor = ICMutedTextColor;
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        cell.textLabel.textColor = [UIColor whiteColor];
    }
    else
    {
        cell.textLabel.textColor = [UIColor blackColor];
    }
    if (indexPath.row == 0) {
        NSInteger period = [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey]];
        //NSString*strDV = @"Skip intro".ls;
        cell.textLabel.text = @"Skip intro".ls;//[NSString stringWithFormat:@"%@: %ld %@", strDV, (long)period, @"Seconds".ls];
        //
        NSString*timeTest = [NSString stringWithFormat:@"%ld %@", (long)period, @"Seconds".ls];
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UIStackView class]]) {
                [subview removeFromSuperview];
            }
        }
        if ([self isSmallDevice]) {
            UILabel *detailLabel = [[UILabel alloc] init];
            detailLabel.text = timeTest;
            detailLabel.textColor = [UIColor grayColor];
            detailLabel.textAlignment = NSTextAlignmentLeft;
            detailLabel.numberOfLines = 0;
            
            UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[cell.textLabel, detailLabel]];
            stackView.axis = UILayoutConstraintAxisVertical;
            stackView.spacing = 5;
            stackView.alignment = UIStackViewAlignmentLeading;
            
            stackView.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:stackView];
            
            // Add Constraints
            [NSLayoutConstraint activateConstraints:@[
                [stackView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:15],
                [stackView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-15],
                [stackView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                [stackView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
            ]];
        }
        else
        {
            cell.detailTextLabel.text = timeTest;
        }
        //
        [self addStepperToCell:cell forStart:YES];
    } else if (indexPath.row == 1) {
        NSInteger period = [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey]];
        //NSString*endDV = @"Skip outro".ls;
        cell.textLabel.text = @"Skip outro".ls;//[NSString stringWithFormat:@"%@: %ld %@", endDV, (long)period, @"Seconds".ls];
        //
        NSString*timeTest = [NSString stringWithFormat:@"%ld %@", (long)period, @"Seconds".ls];
        for (UIView *subview in cell.contentView.subviews) {
            if ([subview isKindOfClass:[UIStackView class]]) {
                [subview removeFromSuperview];
            }
        }
        if ([self isSmallDevice]) {
            UILabel *detailLabel = [[UILabel alloc] init];
            detailLabel.text = timeTest;
            detailLabel.textColor = [UIColor grayColor];
            detailLabel.textAlignment = NSTextAlignmentLeft;
            detailLabel.numberOfLines = 0;
            
            UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[cell.textLabel, detailLabel]];
            stackView.axis = UILayoutConstraintAxisVertical;
            stackView.spacing = 5;
            stackView.alignment = UIStackViewAlignmentLeading;
            
            stackView.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:stackView];
            
            // Add Constraints
            [NSLayoutConstraint activateConstraints:@[
                [stackView.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:15],
                [stackView.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-15],
                [stackView.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
                [stackView.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10]
            ]];
        }
        else
        {
            cell.detailTextLabel.text = timeTest;
        }
        //
        [self addStepperToCell:cell forStart:NO];
    }
    return cell;
}

- (BOOL)isSmallDevice {
    return ([UIScreen mainScreen].bounds.size.width < 375); // iPhone SE and similar
}

#pragma mark - Stepper and Switch Handlers

- (void)addStepperToCell:(UITableViewCell *)cell forStart:(BOOL)isStart {
    UIStepper *stepper = [[UIStepper alloc] init];
    stepper.tag = isStart ? 0 : 1;
    NSInteger period = isStart ?  [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey]] : [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey]];
   
    stepper.minimumValue = -5*60;//0;
    stepper.value = period;//stepper.value = MAX(period, 0);
    stepper.maximumValue = 5*60;
    [stepper addTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
    
    UIColor*colorTemp;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        colorTemp = [UIColor whiteColor];
        
    }
    else
    {
        colorTemp = [UIColor blackColor];
    }
    UIImage *plusImage = [[UIImage systemImageNamed:@"plus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    
    UIImage *minusImage = [[UIImage systemImageNamed:@"minus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    [stepper setIncrementImage:plusImage forState:UIControlStateNormal];
    [stepper setDecrementImage:minusImage forState:UIControlStateNormal];

    
    cell.accessoryView = stepper;
}

- (void)stepperValueChanged:(UIStepper *)sender {
    NSString *key = (sender.tag == 0) ?
    [NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey] :
    [NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey];
    
    NSInteger newValue = sender.value;
    
    if (self.feed) {
        [[self source] setInteger:newValue forKey:key];
    }    
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:sender.tag inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}


- (id) source
{
    return (self.feed) ? self.feed : USER_DEFAULTS;
}

@end
