//
//  MediaFilesViewController.m
//  Instacast
//
//  Created by Martin Hering on 24.10.12.
//
//

#import "MediaFilesViewController.h"
#import "UIManager.h"

#import "VDModalInfo.h"
#import "CDEpisode+ShowNotes.h"
#import "UITableViewController+Settings.h"
#import "InstacastAppDelegate.h"

enum {
    kDownloadedSection = 0,
    kDeleteAllButton,
    kNumberOfSections
};

static NSString *CellIdentifier = @"Cell";
static NSString* PlaceholderCellIdentifier = @"PlaceholderCell";
static NSString* SettingCellIdentifier = @"SettingCell";

@interface MediaFilesViewController () <UIDocumentInteractionControllerDelegate>
@property (nonatomic, strong) NSArray* cachedEpisodes;
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@end

@implementation MediaFilesViewController

+ (id) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (void) _reloadContent
{
    /*NSSortDescriptor* feedDescriptor = [[NSSortDescriptor alloc] initWithKey:@"feed.title" ascending:YES];
    NSSortDescriptor* titleDescriptor = [[NSSortDescriptor alloc] initWithKey:@"title" ascending:YES];
    self.cachedEpisodes = [[[CacheManager sharedCacheManager] cachedEpisodes] sortedArrayUsingDescriptors:@[feedDescriptor, titleDescriptor]];*/
    
    self.cachedEpisodes = [[[CacheManager sharedCacheManager] cachedEpisodes] sortedArrayUsingComparator:^NSComparisonResult(CDEpisode *episode1, CDEpisode *episode2) {
        unsigned long long fileSize1 = [[CacheManager sharedCacheManager] numberOfDownloadedBytesForEpisode:episode1];
        unsigned long long fileSize2 = [[CacheManager sharedCacheManager] numberOfDownloadedBytesForEpisode:episode2];
        
        if (fileSize1 < fileSize2) {
            return NSOrderedDescending;
        } else if (fileSize1 > fileSize2) {
            return NSOrderedAscending;
        } else {
            return NSOrderedSame;
        }
    }];
}


- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];
    
    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Downloaded Files".ls;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"pencil"]
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(toggleEditMode:)];
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    
    [[CacheManager sharedCacheManager] autoClearAndMakeRoomForBytes:0 automatic:YES];
    [self _reloadContent];
    [self.tableView reloadData];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;
    [self.tableView reloadData];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void) toggleEditMode:(id)sender
{
    [self setEditing:!self.editing animated:YES];
}

- (void) setEditing:(BOOL)editing animated:(BOOL)animated
{
    [super setEditing:editing animated:animated];
    UIImage* editImage = editing ? [UIImage systemImageNamed:@"checkmark"] : [UIImage systemImageNamed:@"pencil"];
    self.navigationItem.rightBarButtonItem.image = editImage;
}

#pragma mark - Table view data source


- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kDownloadedSection:
            return MAX(1,[self.cachedEpisodes count]);
        case kDeleteAllButton:
            return 1;
        default:
            break;
    }

    return 0;
}


- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kDeleteAllButton)
    {
        UITableViewCell* cell = [self resetCell];
        cell.userInteractionEnabled = YES;
        cell.textLabel.text = @"Delete Content".ls;
        return cell;
    }

    else if (indexPath.section == kDownloadedSection)
    {
        
        NSArray* episodes = self.cachedEpisodes;
        

        if ([episodes count] == 0)
        {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:PlaceholderCellIdentifier];
            if (cell == nil) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:PlaceholderCellIdentifier];
                cell.backgroundColor = ICGroupCellBackgroundColor;
            }
            
            cell.accessoryView = nil;
            cell.textLabel.text = @"Nothing downloaded yet.".ls;
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.font = [UIFont italicSystemFontOfSize:15];
            cell.textLabel.textColor = ICMutedTextColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            
            return cell;
        }
        else
        {
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
            if (cell == nil) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
                cell.selectedBackgroundView = [[UIView alloc] init];
                cell.textLabel.font = [UIFont systemFontOfSize:13];
                cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
            }
            
            cell.backgroundColor = ICGroupCellBackgroundColor;
            cell.selectedBackgroundView.backgroundColor = ICGroupCellSelectedBackgroundColor;
            cell.detailTextLabel.textColor = ICMutedTextColor;
            
            UILabel* sizeLabel = (UILabel*)cell.accessoryView;
            if (!sizeLabel) {
                sizeLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, (44-20)/2, 65, 20)];
                sizeLabel.font = [UIFont systemFontOfSize:14];
                sizeLabel.textAlignment = NSTextAlignmentRight;
                sizeLabel.textColor = [UIColor colorWithWhite:0.5f alpha:1.0f];
                cell.accessoryView = sizeLabel;
            }
            

            CDEpisode* episode = episodes[indexPath.row];
            CDFeed* feed = episode.feed;
            
            cell.textLabel.text = [episode cleanTitleUsingFeedTitle:feed.title];
            
            unsigned long long bytes = [[CacheManager sharedCacheManager] numberOfDownloadedBytesForEpisode:episode];
            cell.detailTextLabel.text = feed.title;
            
            cell.textLabel.textColor = (episode.consumed) ? ICMutedTextColor : ICTextColor;
            sizeLabel.text = [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleMemory];
            
            return cell;
        }
    }
    
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kDeleteAllButton) {
        return 43.0f;
    }
    
    return 44.0f;
}


// Override to support editing the table view.
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete)
    {
        NSArray* episodes = self.cachedEpisodes;
        NSInteger ec = [episodes count];
        
        CDEpisode* episode = episodes[indexPath.row];
        [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
        
        [self _reloadContent];
        
        episodes = self.cachedEpisodes;
        
        
        if ([episodes count] > 0 && [episodes count] == ec-1) {
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationFade];
        } else {
            [tableView reloadData];
        }
    }
    else if (editingStyle == UITableViewCellEditingStyleInsert) {
        // Create a new instance of the appropriate class, insert it into the array, and add a new row to the table view
    }   
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kDownloadedSection) {
        NSArray* episodes = self.cachedEpisodes;
        return ([episodes count] != 0);
    }
    
    return NO;
}


- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    if (section == kDownloadedSection) {
        return @"Downloaded Content".ls;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
}


#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kDeleteAllButton)
    {
        [self clearCacheAction:indexPath];
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    
    else if (indexPath.section == kDownloadedSection)
    {
        NSArray* episodes = self.cachedEpisodes;
        if ([episodes count] == 0) {
            return;
        }
        
        
        CDEpisode* episode = episodes[indexPath.row];
        
        NSURL* cacheURL = [[CacheManager sharedCacheManager] URLForCachedEpisode:episode];
        self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:cacheURL];
        self.interactionController.delegate = self;
        self.interactionController.name = episode.title;
        self.interactionController.UTI = @"public.data";
        
        CGRect cellRect = [self.tableView rectForRowAtIndexPath:indexPath];
        
        if (![self.interactionController presentOpenInMenuFromRect:cellRect inView:self.tableView animated:YES]) {
            self.interactionController = nil;
            [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        }
    }
}

- (void) documentInteractionControllerDidDismissOpenInMenu: (UIDocumentInteractionController *) controller
{
    self.interactionController = nil;
    [self.tableView deselectRowAtIndexPath:[self.tableView indexPathForSelectedRow] animated:YES];
}


- (void) clearCacheAction:(NSIndexPath*)cellIndexPath
{
    CacheManager* cman = [CacheManager sharedCacheManager];
    
    if ([cman isCaching])
    {
        [self presentAlertControllerWithTitle:@"Currently Downloading".ls
                                      message:@"Clearing the cache is not possible while Instacast is downloading episodes. Please try again later.".ls
                                       button:@"OK".ls
                                     animated:YES
                                   completion:NULL];
        return;
    }
    
    WEAK_SELF
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Only Delete Played".ls
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Clearing…".ls];
                                                [modelInfo show];
                                                
                                                [self perform:^(id sender) {
                                                    
                                                    for(CDEpisode* episode in self.cachedEpisodes) {
                                                        if (episode.consumed) {
                                                            [[CacheManager sharedCacheManager] removeCacheForEpisode:episode automatic:NO];
                                                        }
                                                    }
                                                    
                                                    [self _reloadContent];
                                                    [self.tableView reloadData];
                                                    [modelInfo close];
                                                } afterDelay:0.3f];

                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete All Content".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                VDModalInfo* modelInfo = [VDModalInfo modalInfoWithProgressLabel:@"Clearing…".ls];
                                                [modelInfo show];
                                                
                                                [self perform:^(id sender) {
                                                    [cman clearTheFuckingCache];
                                                    [[ImageCacheManager sharedImageCacheManager] clearTheFuckingCache];
                                                    [self _reloadContent];
                                                    [self.tableView reloadData];
                                                    [modelInfo close];
                                                } afterDelay:0.3f];

                                                self.alertController = nil;
                                            }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction * action) {
                                                STRONG_SELF
                                                self.alertController = nil;
                                            }]];
    
    [alert setModalPresentationStyle:UIModalPresentationPopover];
    UIPopoverPresentationController *popPresenter = [alert popoverPresentationController];
    UIViewController* rootViewController = [(InstacastAppDelegate*)[[UIApplication sharedApplication]delegate] getRootViewControllerDev];
    popPresenter.sourceView = [rootViewController view];
    popPresenter.sourceRect = CGRectMake([rootViewController view].center.x, [rootViewController view].center.y, 0, 0);
    popPresenter.permittedArrowDirections = 0;
    if ([ICAppearanceManager sharedManager].nightSettingMode)
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    else
    {
        alert.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    }
    self.alertController = alert;
    [self presentAlertControllerAnimated:YES completion:NULL];
}

@end
