//
//  InputSampleViewController.m
//  Instacast
//
//  Created by Vinh Huynh on 29/12/24.
//  Copyright © 2024 Vemedio. All rights reserved.
//

#import "SettingInputViewController.h"
#import "FeedSettingsViewController.h"
#import "SettingInputChapterController.h"
#import "Language.h"

@interface SettingInputViewController () <UITextFieldDelegate>

@property (nonatomic, strong) UITextField *keywordTextField;
@property (nonatomic, strong) UIButton *addKeywordButton;
@property (nonatomic, strong) NSLayoutConstraint *textViewHeightConstraint;

@end

@implementation SettingInputViewController

+ (SettingInputViewController*) inputSampleViewController
{
    return [[self alloc] init];
}

- (void)viewDidLoad {
    [super viewDidLoad];
       
    /*self.navigationItem.title = self.title.ls;
    if ([[self.navigationController.viewControllers objectAtIndex:0] isKindOfClass:[FeedSettingsViewController class]]) {
        self.navigationItem.prompt = self.feed.title;
    }*/
    [self titleAndPromptSetting];
    // Set up input view
    [self setupKeywordInputView];
    
    // Register cell
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"KeywordCell"];
    
    // Enable self-sizing cells
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44.0;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        self.tableView.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:1.0];
        self.tableView.separatorColor = [UIColor grayColor];
    }
    else
    {
        self.tableView.backgroundColor = ICBackgroundColor;
        self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    }
    
    [self updateTableViewSeparator];
    
}

-(void)titleAndPromptSetting
{
    if ([[self.navigationController.viewControllers objectAtIndex:0] isKindOfClass:[FeedSettingsViewController class]]) {
        self.navigationItem.title = nil;
        self.navigationItem.prompt = nil;
        UILabel *promptLabel = [[UILabel alloc] init];
        promptLabel.text = self.feed.title; // Your prompt text
        promptLabel.font = [UIFont systemFontOfSize:12];
        promptLabel.textAlignment = NSTextAlignmentCenter;
        
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = self.titleStr.ls; // Your title text
        titleLabel.font = [UIFont boldSystemFontOfSize:17];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        
        if ([ICAppearanceManager sharedManager].nightSettingMode)
        {
            promptLabel.textColor = [UIColor whiteColor]; // Change color of the prompt
            titleLabel.textColor = [UIColor whiteColor]; // Change color of the title
        }
        else
        {
            promptLabel.textColor = [UIColor blackColor]; // Change color of the prompt
            titleLabel.textColor = [UIColor blackColor]; // Change color of the title
        }
        // Create a vertical stack view to hold both labels
        UIStackView *stackView = [[UIStackView alloc] initWithArrangedSubviews:@[promptLabel, titleLabel]];
        stackView.axis = UILayoutConstraintAxisVertical;
        stackView.alignment = UIStackViewAlignmentCenter;
        stackView.spacing = 2; // Adjust spacing
        
        // Assign the stack view to the navigation bar
        self.navigationItem.titleView = stackView;
        
    }
    else
    {
        self.navigationItem.title = self.title.ls;
    }
}

- (void)updateTableViewSeparator {
    if ([self.tableView numberOfRowsInSection:0] == 0) {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    } else {
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    }
}
- (void) updateAppearance {
    
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        self.tableView.backgroundColor = [UIColor colorWithRed:20/255.0 green:20/255.0 blue:20/255.0 alpha:1.0];
        self.tableView.separatorColor = [UIColor grayColor];
    }
    else
    {
        self.tableView.backgroundColor = ICBackgroundColor;
        self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    }
    
    [self.tableView reloadData];
    [self updateTableViewSeparator];
}

- (NSArray *)values {
    return  _inputValues;
}

#pragma mark - Setup UI

- (void)setupKeywordInputView {
    self.keywordTextField = [[UITextField alloc] init];
    self.keywordTextField.delegate = self;
    //self.keywordTextField.placeholder = @"Add Chapter Name".ls;
    
    self.keywordTextField.translatesAutoresizingMaskIntoConstraints = NO;
    
    
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        self.keywordTextField.textColor = [UIColor whiteColor];
        self.keywordTextField.backgroundColor = [UIColor clearColor];
        self.keywordTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Add Chapter Name".ls attributes:@{NSForegroundColorAttributeName: [UIColor lightGrayColor]}];
    }
    else
    {
        self.keywordTextField.textColor = [UIColor blackColor];
        self.keywordTextField.backgroundColor = [UIColor clearColor];
        self.keywordTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Add Chapter Name".ls attributes:@{NSForegroundColorAttributeName: [UIColor darkGrayColor]}];
    }

    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 50)];
    
    [headerView addSubview:self.keywordTextField];
    [NSLayoutConstraint activateConstraints:@[
        [self.keywordTextField.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:20],
        [self.keywordTextField.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-20],
        [self.keywordTextField.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor constant:0],
        [self.keywordTextField.heightAnchor constraintEqualToConstant:40]
    ]];

    // Set the table header view
    self.tableView.tableHeaderView = headerView;
}

#pragma mark - Actions

- (void)addKeyword {
    NSString *keyword = self.keywordTextField.text;
    if (keyword.length > 0) {
        [self.inputValues addObject:keyword];
        [self.tableView reloadData];
        [self updateTableViewSeparator];
        self.keywordTextField.text = @"";
        NSString *keyworks = [self.inputValues componentsJoinedByString:@".  "];
        [self _setString:keyworks forKey:self.key];
    }
}

#pragma mark - Text Field Delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self addKeyword];
    return  YES;
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.inputValues.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"KeywordCell" forIndexPath:indexPath];
    cell.backgroundColor = [UIColor clearColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    // Clear existing content
    for (UIView *subview in cell.contentView.subviews) {
        [subview removeFromSuperview];
    }
    
    // Keyword Label
    UILabel *label = [[UILabel alloc] init];
    label.text = self.inputValues[indexPath.row];
    label.font = [UIFont systemFontOfSize:16];
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        label.textColor = [UIColor whiteColor];
    }
    else
    {
        label.textColor = [UIColor blackColor];
    }
    // Settings Button
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeCustom];
    settingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    settingsButton.backgroundColor = [UIColor clearColor];
    settingsButton.tag = indexPath.row;
    [settingsButton addTarget:self action:@selector(openSettings:) forControlEvents:UIControlEventTouchUpInside];
    
    UIImage *gearImage;
    if (@available(iOS 14.0, *)) {
        gearImage = [UIImage systemImageNamed:@"gearshape"];//gearshape
    } else {
        gearImage = [[UIImage imageNamed:@"setting_chapter"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]; // Use a custom image
    }
    UIImageView *settingsIconImageView = [[UIImageView alloc] initWithImage:gearImage];
    settingsIconImageView.tintColor = ICTintColor;
    settingsIconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    settingsIconImageView.contentMode = UIViewContentModeScaleAspectFit;
    settingsIconImageView.clipsToBounds = YES;
    [settingsButton addSubview:settingsIconImageView];
    
    // Delete Button with image below
    UIButton *deleteButton = [UIButton buttonWithType:UIButtonTypeCustom];
    deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    deleteButton.backgroundColor = [UIColor clearColor];
    deleteButton.tag = indexPath.row;
    [deleteButton addTarget:self action:@selector(deleteKeyword:) forControlEvents:UIControlEventTouchUpInside];
    
    UIImageView *deleteIconImageView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"trash"]];
    deleteIconImageView.translatesAutoresizingMaskIntoConstraints = NO;
    deleteIconImageView.contentMode = UIViewContentModeScaleAspectFit;
    deleteIconImageView.clipsToBounds = YES;
    [deleteButton addSubview:deleteIconImageView];
    
    [NSLayoutConstraint activateConstraints:@[
        [settingsIconImageView.centerXAnchor constraintEqualToAnchor:settingsButton.centerXAnchor],
        [settingsIconImageView.centerYAnchor constraintEqualToAnchor:settingsButton.centerYAnchor],
        [settingsIconImageView.widthAnchor constraintEqualToConstant:16],
        [settingsIconImageView.heightAnchor constraintEqualToConstant:16],
        
        [deleteIconImageView.centerXAnchor constraintEqualToAnchor:deleteButton.centerXAnchor],
        [deleteIconImageView.centerYAnchor constraintEqualToAnchor:deleteButton.centerYAnchor],
        [deleteIconImageView.topAnchor constraintEqualToAnchor:deleteButton.bottomAnchor constant:5],
        [deleteIconImageView.widthAnchor constraintEqualToConstant:16],
        [deleteIconImageView.heightAnchor constraintEqualToConstant:16]
    ]];
    
    // Add content to cell
    [cell.contentView addSubview:label];
    [cell.contentView addSubview:settingsButton];
    [cell.contentView addSubview:deleteButton];
    
    // Constraints for label and delete button
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:15],
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:10],
        [label.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-10],
        [label.trailingAnchor constraintEqualToAnchor:deleteButton.leadingAnchor constant:-10],
        
        // Settings Button Constraints
        [settingsButton.trailingAnchor constraintEqualToAnchor:deleteButton.leadingAnchor constant:-10],
        [settingsButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [settingsButton.widthAnchor constraintEqualToConstant:30],
        [settingsButton.heightAnchor constraintEqualToConstant:30],
        
        // Delete Button Constraints
        [deleteButton.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-15],
        [deleteButton.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [deleteButton.widthAnchor constraintEqualToConstant:30],
        [deleteButton.heightAnchor constraintEqualToConstant:30]
    ]];
    
    return cell;
}

#pragma mark - UITableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    /*SettingInputChapterController *settingController  = [SettingInputChapterController inputSampleViewController];
    settingController.chapterKey = self.inputValues[indexPath.row];
    settingController.feed = self.feed;
    [self.navigationController pushViewController:settingController animated:YES];*/
}

#pragma mark - Delete Keyword

- (void)deleteKeyword:(UIButton *)sender {
    NSInteger index = sender.tag;
    [self.inputValues removeObjectAtIndex:index];
    [self.tableView reloadData];
    [self updateTableViewSeparator];
    if (self.inputValues.count > 0) {
        NSString *keyworks = [self.inputValues componentsJoinedByString:@".  "];
        [self _setString:keyworks forKey:self.key];
    } else {
        if (self.feed) {
            [self.feed resetValueForKey:self.key];
        }
        else {
            [USER_DEFAULTS removeObjectForKey:self.key];
        }
    }
}

- (void)openSettings:(UIButton *)sender {
    NSInteger rowIndex = sender.tag;
    SettingInputChapterController *settingController  = [SettingInputChapterController inputSampleViewController];
    settingController.chapterKey = self.inputValues[rowIndex];
    settingController.feed = self.feed;
    [self.navigationController pushViewController:settingController animated:YES];
}

@end
