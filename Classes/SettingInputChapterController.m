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
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
    if (indexPath.row == 0) {
        NSInteger period = [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey]];
        NSString*strDV = @"Skip Start".ls;
        cell.textLabel.text = [NSString stringWithFormat:@"%@: %ld %@", strDV, (long)period, @"Seconds".ls];
        [self addStepperToCell:cell forStart:YES];
    } else if (indexPath.row == 1) {
        NSInteger period = [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey]];
        NSString*endDV = @"Skip End".ls;
        cell.textLabel.text = [NSString stringWithFormat:@"%@: %ld %@", endDV, (long)period, @"Seconds".ls];
        [self addStepperToCell:cell forStart:NO];
    }
    return cell;
}

#pragma mark - Stepper and Switch Handlers

- (void)addStepperToCell:(UITableViewCell *)cell forStart:(BOOL)isStart {
    UIStepper *stepper = [[UIStepper alloc] init];
    stepper.tag = isStart ? 0 : 1;
    NSInteger period = isStart ?  [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, self.chapterKey]] : [self.feed integerForKey:[NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, self.chapterKey]];
    stepper.value = MAX(period, 0);
    stepper.minimumValue = 0;
    stepper.maximumValue = 60;
    [stepper addTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
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
