//
//  ChapterSkipListViewController.m
//  Instacast
//
//  Created by Chris on 11/02/26.
//  Copyright © 2026 Vemedio. All rights reserved.
//

#import "ChapterSkipListViewController.h"
#import "CDModel.h"
#import "SkipTimeCell.h"
#import "UITableViewController+Settings.h"

@interface ChapterSkipListViewController () <UITextFieldDelegate>

@property (nonatomic, strong) NSMutableArray<NSString *> *keywords;
@property (nonatomic, assign) NSInteger expandedIndex; // -1 = none expanded

@end

@implementation ChapterSkipListViewController

+ (instancetype)controllerWithFeed:(CDFeed *)feed
{
    ChapterSkipListViewController *controller = [[self alloc] initWithStyle:UITableViewStyleGrouped];
    controller.feed = feed;
    return controller;
}

#pragma mark - View Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    self.expandedIndex = -1;

    // Load keywords from feed
    NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", self.feed.uid];
    NSString *chaptersName = [self.feed stringForKey:key];
    if (chaptersName.length > 0) {
        NSArray *names = [chaptersName componentsSeparatedByString:@".  "];
        self.keywords = [NSMutableArray arrayWithArray:names];
    } else {
        self.keywords = [NSMutableArray array];
    }

    self.navigationItem.title = @"Skip Chapter".ls;

    [self.tableView registerNib:[UINib nibWithNibName:@"SkipTimeCell" bundle:nil] forCellReuseIdentifier:@"SkipTimeCell"];

    self.tableView.delaysContentTouches = NO;

    // Tap gesture to dismiss keyboard
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboard)];
    tapGesture.cancelsTouchesInView = NO;
    [self.tableView addGestureRecognizer:tapGesture];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
    [self updateAppearance];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dismissKeyboard
{
    [self.view endEditing:YES];
}

- (void)updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    [self.tableView reloadData];
}

#pragma mark - Data Persistence

- (void)saveKeywords
{
    NSString *key = [NSString stringWithFormat:@"%@_auto_skip_chapter_name", self.feed.uid];
    if (self.keywords.count > 0) {
        NSString *joined = [self.keywords componentsJoinedByString:@".  "];
        [self.feed setString:joined forKey:key];
    } else {
        [self.feed resetValueForKey:key];
    }
}

- (id)source
{
    return (self.feed) ? self.feed : USER_DEFAULTS;
}

#pragma mark - Row Index Helpers

// Returns the flat row index for a keyword at the given keyword index
- (NSInteger)rowForKeywordAtIndex:(NSInteger)keywordIndex
{
    NSInteger row = 0;
    for (NSInteger i = 0; i < keywordIndex; i++) {
        row++; // keyword row
        if (i == self.expandedIndex) {
            row += 3; // skip-before, skip-after, delete
        }
    }
    return row;
}

// Returns the total number of rows (keywords + expanded detail rows + add row)
- (NSInteger)totalRowCount
{
    NSInteger count = self.keywords.count; // keyword rows
    if (self.expandedIndex >= 0 && self.expandedIndex < (NSInteger)self.keywords.count) {
        count += 3; // skip-before, skip-after, delete
    }
    count += 1; // "Add Keyword" row
    return count;
}

// Determines what type of row a given indexPath.row is
// Returns: 0 = keyword row, 1 = skip-before row, 2 = skip-after row, 3 = add row, 4 = delete row
// Also sets outKeywordIndex to the keyword this row belongs to
- (NSInteger)rowTypeForRow:(NSInteger)row keywordIndex:(NSInteger *)outKeywordIndex
{
    NSInteger keywordIdx = 0;
    NSInteger currentRow = 0;

    while (keywordIdx < (NSInteger)self.keywords.count) {
        if (currentRow == row) {
            if (outKeywordIndex) *outKeywordIndex = keywordIdx;
            return 0; // keyword row
        }
        currentRow++;

        if (keywordIdx == self.expandedIndex) {
            if (currentRow == row) {
                if (outKeywordIndex) *outKeywordIndex = keywordIdx;
                return 1; // skip-before row
            }
            currentRow++;
            if (currentRow == row) {
                if (outKeywordIndex) *outKeywordIndex = keywordIdx;
                return 2; // skip-after row
            }
            currentRow++;
            if (currentRow == row) {
                if (outKeywordIndex) *outKeywordIndex = keywordIdx;
                return 4; // delete row
            }
            currentRow++;
        }

        keywordIdx++;
    }

    // Must be the "Add" row
    if (outKeywordIndex) *outKeywordIndex = -1;
    return 3;
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self totalRowCount];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSInteger keywordIndex = -1;
    NSInteger rowType = [self rowTypeForRow:indexPath.row keywordIndex:&keywordIndex];

    if (rowType == 0) {
        // Keyword row
        static NSString *KeywordCellId = @"KeywordCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:KeywordCellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:KeywordCellId];
            cell.selectedBackgroundView = [[UIView alloc] init];
        }

        cell.textLabel.text = self.keywords[keywordIndex];
        cell.textLabel.textColor = ICTextColor;
        cell.backgroundColor = ICGroupCellBackgroundColor;
        cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;

        BOOL isExpanded = (keywordIndex == self.expandedIndex);
        UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:isExpanded ? @"chevron.down" : @"chevron.right"]];
        chevron.tintColor = ICMutedTextColor;
        cell.accessoryView = chevron;

        return cell;
    }
    else if (rowType == 1 || rowType == 2) {
        // SkipTimeCell
        SkipTimeCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SkipTimeCell" forIndexPath:indexPath];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.contentView.backgroundColor = ICGroupCellBackgroundColor;

        BOOL isNightMode = [ICAppearanceManager sharedManager].nightSettingMode;
        cell.titleLbl.textColor = isNightMode ? [UIColor whiteColor] : [UIColor blackColor];
        cell.timeTF.textColor = ICMutedTextColor;
        cell.secondsLbl.textColor = ICMutedTextColor;
        cell.secondsLbl.text = @"Seconds".ls;
        cell.timeTF.delegate = self;

        NSString *keyword = self.keywords[keywordIndex];
        BOOL isStart = (rowType == 1);
        NSString *periodKey = [NSString stringWithFormat:@"%@_auto_skip_%@_chapter_%@",
                               self.feed.uid, (isStart ? @"start" : @"end"), keyword];
        double period = [self.feed doubleForKey:periodKey];
        cell.timeTF.text = [NSString stringWithFormat:@"%.1f", period];

        if (isStart) {
            cell.titleLbl.text = @"Start".ls;
        } else {
            cell.titleLbl.text = @"End".ls;
        }

        [self configureStepper:cell.stepperView forKeywordAtIndex:keywordIndex isStart:isStart];

        return cell;
    }
    else if (rowType == 4) {
        // Delete keyword row
        static NSString *DeleteCellId = @"DeleteKeywordCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:DeleteCellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:DeleteCellId];
            cell.selectedBackgroundView = [[UIView alloc] init];
        }

        cell.backgroundColor = ICGroupCellBackgroundColor;
        cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
        cell.textLabel.text = @"Remove Keyword".ls;
        cell.textLabel.textColor = [UIColor systemRedColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.imageView.image = nil;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;

        return cell;
    }
    else {
        // "Add Keyword" row
        static NSString *AddCellId = @"AddKeywordCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:AddCellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:AddCellId];
            cell.selectedBackgroundView = [[UIView alloc] init];
        }

        cell.backgroundColor = ICGroupCellBackgroundColor;
        cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;

        UIImage *plusImage = [UIImage systemImageNamed:@"plus"];
        cell.imageView.image = plusImage;
        cell.imageView.tintColor = ICTintColor;
        cell.textLabel.text = @"Add Keyword…".ls;
        cell.textLabel.textColor = ICTintColor;
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;

        return cell;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    return @"Skip Chapter".ls;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return @"Chapters whose name contains one of these keywords will be automatically skipped. Matching is case-insensitive and works on partial names.\n\nStart: Offset in seconds. +2s plays the first 2s of the chapter before skipping. −2s begins skipping 2s before the chapter starts.\nEnd: Offset in seconds. +2s also skips the first 2s after the chapter.".ls;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSInteger keywordIndex = -1;
    NSInteger rowType = [self rowTypeForRow:indexPath.row keywordIndex:&keywordIndex];

    if (rowType == 0) {
        // Toggle expand/collapse
        [self toggleExpandKeywordAtIndex:keywordIndex];
    }
    else if (rowType == 4) {
        // Delete keyword
        [self deleteKeywordAtIndex:keywordIndex];
    }
    else if (rowType == 3) {
        // Add keyword
        [self showAddKeywordAlert];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSInteger keywordIndex = -1;
    NSInteger rowType = [self rowTypeForRow:indexPath.row keywordIndex:&keywordIndex];
    return (rowType == 0); // Only keyword rows can be swiped to delete
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;

    NSInteger keywordIndex = -1;
    NSInteger rowType = [self rowTypeForRow:indexPath.row keywordIndex:&keywordIndex];
    if (rowType != 0 || keywordIndex < 0 || keywordIndex >= (NSInteger)self.keywords.count) return;

    [self deleteKeywordAtIndex:keywordIndex];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.textColor = [UIColor grayColor];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *footer = (UITableViewHeaderFooterView *)view;
    footer.textLabel.textColor = [UIColor grayColor];
    footer.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString* text = [self tableView:tableView titleForFooterInSection:section];
    return [self heightForFooterText:text];
}

#pragma mark - Expand / Collapse

- (void)toggleExpandKeywordAtIndex:(NSInteger)keywordIndex
{
    NSInteger oldExpanded = self.expandedIndex;

    [self.tableView beginUpdates];

    // Collapse previously expanded keyword
    if (oldExpanded >= 0 && oldExpanded < (NSInteger)self.keywords.count) {
        NSInteger oldBaseRow = [self rowForKeywordAtIndex:oldExpanded];
        self.expandedIndex = -1; // must set before computing new rows
        NSArray *collapseRows = @[
            [NSIndexPath indexPathForRow:oldBaseRow + 1 inSection:0],
            [NSIndexPath indexPathForRow:oldBaseRow + 2 inSection:0],
            [NSIndexPath indexPathForRow:oldBaseRow + 3 inSection:0]
        ];
        [self.tableView deleteRowsAtIndexPaths:collapseRows withRowAnimation:UITableViewRowAnimationFade];
    }

    // Expand the new keyword (unless we tapped the same one)
    if (keywordIndex != oldExpanded) {
        self.expandedIndex = keywordIndex;
        NSInteger newBaseRow = [self rowForKeywordAtIndex:keywordIndex];
        NSArray *expandRows = @[
            [NSIndexPath indexPathForRow:newBaseRow + 1 inSection:0],
            [NSIndexPath indexPathForRow:newBaseRow + 2 inSection:0],
            [NSIndexPath indexPathForRow:newBaseRow + 3 inSection:0]
        ];
        [self.tableView insertRowsAtIndexPaths:expandRows withRowAnimation:UITableViewRowAnimationFade];
    }

    [self.tableView endUpdates];

    // Update chevrons on visible keyword cells (outside batch update to avoid index path conflicts)
    for (UITableViewCell *visibleCell in self.tableView.visibleCells) {
        NSIndexPath *ip = [self.tableView indexPathForCell:visibleCell];
        if (!ip) continue;
        NSInteger kwIdx = -1;
        NSInteger type = [self rowTypeForRow:ip.row keywordIndex:&kwIdx];
        if (type == 0) {
            BOOL isExp = (kwIdx == self.expandedIndex);
            UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:isExp ? @"chevron.down" : @"chevron.right"]];
            chevron.tintColor = ICMutedTextColor;
            visibleCell.accessoryView = chevron;
        }
    }
}

#pragma mark - Delete Keyword

- (void)deleteKeywordAtIndex:(NSInteger)keywordIndex
{
    if (keywordIndex < 0 || keywordIndex >= (NSInteger)self.keywords.count) return;

    NSString *keyword = self.keywords[keywordIndex];
    BOOL wasExpanded = (keywordIndex == self.expandedIndex);

    // Build index paths to remove
    NSMutableArray<NSIndexPath *> *rowsToDelete = [NSMutableArray array];
    NSInteger baseRow = [self rowForKeywordAtIndex:keywordIndex];
    [rowsToDelete addObject:[NSIndexPath indexPathForRow:baseRow inSection:0]]; // keyword row
    if (wasExpanded) {
        [rowsToDelete addObject:[NSIndexPath indexPathForRow:baseRow + 1 inSection:0]]; // start
        [rowsToDelete addObject:[NSIndexPath indexPathForRow:baseRow + 2 inSection:0]]; // end
        [rowsToDelete addObject:[NSIndexPath indexPathForRow:baseRow + 3 inSection:0]]; // delete
    }

    // Update expanded index
    if (wasExpanded) {
        self.expandedIndex = -1;
    } else if (self.expandedIndex > keywordIndex) {
        self.expandedIndex--;
    }

    // Remove keyword and clean up per-chapter skip values
    [self.keywords removeObjectAtIndex:keywordIndex];
    [self.feed resetValueForKey:[NSString stringWithFormat:@"%@_auto_skip_start_chapter_%@", self.feed.uid, keyword]];
    [self.feed resetValueForKey:[NSString stringWithFormat:@"%@_auto_skip_end_chapter_%@", self.feed.uid, keyword]];
    [self saveKeywords];

    [self.tableView deleteRowsAtIndexPaths:rowsToDelete withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Add Keyword

- (void)showAddKeywordAlert
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Keyword…".ls
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"e.g. Ads, Intro, Sponsor";
        textField.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];

    if ([ICAppearanceManager sharedManager].nightSettingMode) {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    } else {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }

    WEAK_SELF
    UIAlertAction *addAction = [UIAlertAction actionWithTitle:@"Add".ls
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *action) {
        STRONG_SELF
        NSString *keyword = alert.textFields.firstObject.text;
        keyword = [keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (keyword.length > 0) {
            [self addKeyword:keyword];
        }
    }];

    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel".ls
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];

    [alert addAction:addAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)addKeyword:(NSString *)keyword
{
    [self.keywords addObject:keyword];
    [self saveKeywords];

    // Insert new keyword row (before the Add row)
    NSInteger newRow = [self rowForKeywordAtIndex:self.keywords.count - 1];
    [self.tableView insertRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:newRow inSection:0]]
                          withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Stepper

- (void)configureStepper:(UIStepper *)stepper forKeywordAtIndex:(NSInteger)keywordIndex isStart:(BOOL)isStart
{
    NSString *keyword = self.keywords[keywordIndex];

    stepper.stepValue = 0.1;
    stepper.minimumValue = -300.0;
    stepper.maximumValue = 300.0;

    NSString *periodKey = [NSString stringWithFormat:@"%@_auto_skip_%@_chapter_%@",
                           self.feed.uid, (isStart ? @"start" : @"end"), keyword];
    stepper.value = [self.feed doubleForKey:periodKey];

    // Tag encodes keyword index and start/end: tag = keywordIndex * 2 + (isStart ? 0 : 1)
    stepper.tag = keywordIndex * 2 + (isStart ? 0 : 1);

    BOOL isNightMode = [ICAppearanceManager sharedManager].nightSettingMode;
    UIColor *colorTemp = isNightMode ? [UIColor whiteColor] : [UIColor blackColor];
    stepper.tintColor = colorTemp;
    UIImage *plusImage = [[UIImage systemImageNamed:@"plus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    UIImage *minusImage = [[UIImage systemImageNamed:@"minus"] imageWithTintColor:colorTemp renderingMode:UIImageRenderingModeAlwaysOriginal];
    [stepper setIncrementImage:plusImage forState:UIControlStateNormal];
    [stepper setDecrementImage:minusImage forState:UIControlStateNormal];

    [stepper removeTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
    [stepper addTarget:self action:@selector(stepperValueChanged:) forControlEvents:UIControlEventValueChanged];
}

- (void)stepperValueChanged:(UIStepper *)sender
{
    NSInteger keywordIndex = sender.tag / 2;
    BOOL isStart = (sender.tag % 2 == 0);

    if (keywordIndex < 0 || keywordIndex >= (NSInteger)self.keywords.count) return;

    NSString *keyword = self.keywords[keywordIndex];
    NSString *periodKey = [NSString stringWithFormat:@"%@_auto_skip_%@_chapter_%@",
                           self.feed.uid, (isStart ? @"start" : @"end"), keyword];

    [[self source] setDouble:sender.value forKey:periodKey];

    // Find the SkipTimeCell row and reload it
    NSInteger baseRow = [self rowForKeywordAtIndex:keywordIndex];
    NSInteger skipRow = baseRow + (isStart ? 1 : 2);
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:skipRow inSection:0]]
                          withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - UITextField Delegate

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string
{
    NSString *newText = [textField.text stringByReplacingCharactersInRange:range withString:string];

    if (newText.length == 0) return YES;

    NSString *decimalRegex = @"^-?\\d*\\.?\\d{0,1}$";
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", decimalRegex];
    if (![predicate evaluateWithObject:newText]) return NO;

    double value = [newText doubleValue];
    if (value < -300.0 || value > 300.0) return NO;

    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    SkipTimeCell *cell = (SkipTimeCell *)textField.superview.superview;
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    NSInteger keywordIndex = -1;
    NSInteger rowType = [self rowTypeForRow:indexPath.row keywordIndex:&keywordIndex];
    if (rowType != 1 && rowType != 2) return;
    if (keywordIndex < 0 || keywordIndex >= (NSInteger)self.keywords.count) return;

    NSString *keyword = self.keywords[keywordIndex];
    BOOL isStart = (rowType == 1);
    NSString *periodKey = [NSString stringWithFormat:@"%@_auto_skip_%@_chapter_%@",
                           self.feed.uid, (isStart ? @"start" : @"end"), keyword];

    double newValue = [textField.text doubleValue];
    newValue = MIN(MAX(newValue, -300.0), 300.0);

    [[self source] setDouble:newValue forKey:periodKey];
    cell.stepperView.value = newValue;

    [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end
