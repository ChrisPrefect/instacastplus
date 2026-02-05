//
//  MainViewController_4.m
//  Instacast
//
//  Created by Martin Hering on 25.06.13.
//
//


#import "MainViewController_4.h"
#import "MainSidebarController.h"
#import "SubscriptionsTableViewController.h"
#import "OptionsViewController.h"
#import "ICNowPlayingActivityControl.h"
#import "PlaybackViewController.h"
#import "PlaylistsTableViewController.h"

#import "EpisodesTableViewController.h"
#import "DownloadsViewController.h"
#import "BookmarksTableViewController.h"
#import "ListEpisodesTableViewController.h"
#import "MainActivityViewController.h"
#import "StatusBarFixingViewController.h"
#import "DirectorySearchViewController.h"

#import "VDModalInfo.h"
#import "OnboardScreenVC.h"
#import "UpNextTableViewController.h"

typedef NS_ENUM(NSInteger, MainSidebarItemTags) {
    kMainSidebarItemSubscriptions   = 2,
    kMainSidebarItemLists           = 3,
    kMainSidebarItemBookmarks       = 4,
    kMainSidebarItemSearch          = 5,
    kMainSidebarItemDownloads       = 6,
    kMainSidebarItemUpNext          = 7,
    kMainSidebarItemSettings        = 8,
    kMainSidebarItemUnplayed        = 9,
    kMainSidebarItemImported        = 10,
    kMainSidebarItemFavorites       = 11,
};

@interface MainViewController_4 () <UINavigationControllerDelegate,OnboardScreenVCDelegate>
@property (nonatomic, strong, readwrite) UINavigationController* rootNavigationController;
@property (nonatomic, strong, readwrite) MainSidebarController* sidebarController;
@property (nonatomic, strong, readwrite) MainActivityViewController* activityViewController;

@property (nonatomic, readonly) CDEpisodeList* unplayedPlaylist;
@property (nonatomic, readonly) CDEpisodeList* favoritesPlaylist;
@end

@implementation MainViewController_4 {
    BOOL _observing;
    BOOL _laterDidAppear;
    BOOL _didWillAppear;
}



+ (instancetype) mainViewController
{
    return [[self alloc] initWithNibName:nil bundle:nil];
}

- (void) dealloc
{
    [self _setObserving:NO];
}

- (void) _setObserving:(BOOL)observing
{
    if (observing && !_observing)
    {
        WEAK_SELF
        
        [self.activityViewController addTaskObserver:self forKeyPath:@"visible" task:^(id obj, NSDictionary *change) {
            [weakSelf setNeedsContentControllerLayoutUpdateAnimated:YES];
        }];
        
        [self.unplayedPlaylist addTaskObserver:self forKeyPath:@"name" task:^(id obj, NSDictionary *change) {
            MainSidebarItem* sidebarItem = weakSelf.sidebarController.items[0][2];
            sidebarItem.title = self.unplayedPlaylist.name;
        }];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateAppearance)
                                                     name:ICAppearanceManagerDidUpdateAppearanceNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_cacheManagerDidUpdate:)
                                                     name:CacheManagerDidUpdateNotification
                                                   object:nil];

        _observing = YES;
    }
    else if (!observing && _observing)
    {
        [self.activityViewController removeTaskObserver:self forKeyPath:@"visible"];
        [self.unplayedPlaylist removeTaskObserver:self forKeyPath:@"name"];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self];
                
        _observing = NO;
    }
}

- (void) updateAppearance {
    self.view.backgroundColor = ICDarkBackgroundColor;
}

- (void) _cacheManagerDidUpdate:(NSNotification*)notification {
    // Reload sidebar to update download speed display
    [self.sidebarController.tableView reloadData];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
	// Do any additional setup after loading the view.
    
    //self.view.tintColor = ICTintColor;
    self.view.backgroundColor = ICDarkBackgroundColor;
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    CGRect b = self.view.bounds;
    MainActivityViewController* activityViewController = [MainActivityViewController viewController];
    activityViewController.view.frame = CGRectMake(0, CGRectGetHeight(b), CGRectGetWidth(b), 49);  // 5px taller
    activityViewController.view.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    self.activityViewController = activityViewController;

    [self.activityViewController.nowPlayingControl addTarget:self action:@selector(playNow:) forControlEvents:UIControlEventTouchUpInside];
    

    self.sidebarController = [[MainSidebarController alloc] initWithStyle:UITableViewStylePlain];
    self.sidebarController.items = @[
                                      @[
                                         [MainSidebarItem itemWithTitle:@"Podcasts".ls
                                                                    tag:kMainSidebarItemSubscriptions
                                                                  image:[UIImage imageNamed:@"Menu Subscriptions"]
                                                          selectedImage:[UIImage imageNamed:@"Menu Subscriptions Filled"]],

                                         [MainSidebarItem itemWithTitle:@"Favorites".ls
                                                                    tag:kMainSidebarItemFavorites
                                                                  image:[UIImage systemImageNamed:@"star" withConfiguration:[UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleLarge]]
                                                          selectedImage:[UIImage systemImageNamed:@"star.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleLarge]]
                                                             topSpacing:22],

                                         [MainSidebarItem itemWithTitle:self.unplayedPlaylist.name
                                                                    tag:kMainSidebarItemUnplayed
                                                                  image:[UIImage imageNamed:@"Menu Unplayed"]
                                                          selectedImage:[UIImage imageNamed:@"Menu Unplayed Filled"]],

                                         [MainSidebarItem itemWithTitle:@"Play Next".ls
                                                                    tag:kMainSidebarItemUpNext
                                                                  image:[UIImage systemImageNamed:@"list.bullet.indent" withConfiguration:[UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleLarge]]
                                                          selectedImage:[UIImage systemImageNamed:@"list.bullet.indent" withConfiguration:[UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleLarge]]],

                                         [MainSidebarItem itemWithTitle:@"Lists".ls
                                                                    tag:kMainSidebarItemLists
                                                                  image:[UIImage imageNamed:@"Menu Lists"]
                                                          selectedImage:[UIImage imageNamed:@"Menu Lists"]],

                                         [MainSidebarItem itemWithTitle:@"Bookmarks".ls
                                                                    tag:kMainSidebarItemBookmarks
                                                                  image:[UIImage imageNamed:@"Menu Bookmarks"]
                                                          selectedImage:[UIImage imageNamed:@"Menu Bookmarks Filled"]],
                                         ],
                                     @[
                                         ({
                                             MainSidebarItem* item = [MainSidebarItem itemWithTitle:@"Downloads".ls
                                                                        tag:kMainSidebarItemDownloads
                                                                      image:[UIImage imageNamed:@"Menu Downloads"]
                                                              selectedImage:[UIImage imageNamed:@"Menu Downloads Filled"]
                                                                 topSpacing:22];
                                             item.auxiliaryText = ^NSString* {
                                                 CacheManager* cm = [CacheManager sharedCacheManager];
                                                 if ([cm isCaching] && cm.rate > 0) {
                                                     NSString* speedStr = [NSByteCountFormatter stringFromByteCount:(long long)cm.rate countStyle:NSByteCountFormatterCountStyleMemory];
                                                     return [speedStr stringByAppendingString:@"/s"];
                                                 }
                                                 return nil;
                                             };
                                             item;
                                         }),

                                         [MainSidebarItem itemWithTitle:@"Settings".ls
                                                                    tag:kMainSidebarItemSettings
                                                                  image:[UIImage imageNamed:@"Menu Settings"]
                                                          selectedImage:[UIImage imageNamed:@"Menu Settings"]],
                                         ]
                                     ];
    
    NSInteger savedMainSidebarItemTag = [USER_DEFAULTS integerForKey:kUIPersistenceMainSidebarItem];
    if (savedMainSidebarItemTag > 0) {
        [self _selectMainSidebarItemWithTag:savedMainSidebarItemTag];
        self.sidebarController.selectedItemTag = savedMainSidebarItemTag;
    }
    else {
        [self _selectMainSidebarItemWithTag:kMainSidebarItemSubscriptions];
        self.sidebarController.selectedItemTag = kMainSidebarItemSubscriptions;
    }
    
    
    __weak MainViewController_4* weakSelf = self;
    self.sidebarController.didSelectItem = ^(MainSidebarItem* item) {
        
        if ([weakSelf _selectMainSidebarItemWithTag:item.tag])
        {
            [USER_DEFAULTS setInteger:item.tag forKey:kUIPersistenceMainSidebarItem];
            [USER_DEFAULTS synchronize];
            [weakSelf setSidebarShown:NO animated:YES];
            
            return YES;
        }
        
        return NO;
    };

    self.sidebarViewController = self.sidebarController;

    [self _setObserving:YES];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
    [super traitCollectionDidChange:previousTraitCollection];

    if ([ICAppearanceManager sharedManager].appearanceMode == ICAppearanceModeAutomatic) {
        if (self.traitCollection.userInterfaceStyle != previousTraitCollection.userInterfaceStyle) {
            [[ICAppearanceManager sharedManager] updateAppearance];
        }
    }
}

- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    _didWillAppear = YES;
    if ([USER_DEFAULTS valueForKey: @"onboard_will_show"] == nil)
    {
        [self showOnboardScreen];
    }
}

-(void)showOnboardScreen
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        OnboardScreenVC*onboardVC = [[OnboardScreenVC alloc] initWithNibName:@"OnboardScreenVC" bundle:nil];
        [USER_DEFAULTS setBool:true forKey:@"onboard_will_show"];
        [USER_DEFAULTS synchronize];
        onboardVC.providesPresentationContextTransitionStyle = YES;
        onboardVC.definesPresentationContext = YES;
        onboardVC.delegate = self;
        [onboardVC setModalPresentationStyle:UIModalPresentationOverCurrentContext];
        [self presentViewController:onboardVC animated:NO completion:nil];
    });
}

- (void) plusButtonPressDelegateMethod: (OnboardScreenVC *) sender {
    NSLog(@"Delegates are great!");
    DirectorySearchViewController* controller = [DirectorySearchViewController directorySearchViewController];
    PortraitNavigationController* navigationController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
    navigationController.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigationController animated:YES completion:NULL];
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    if (_didWillAppear) {
        [self setNeedsContentControllerLayoutUpdateAnimated:NO];
    }
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    _laterDidAppear = YES;
    _didWillAppear = NO;
    
    [self presentNextViewController];
}


- (void) playNow:(id)sender
{
    PlaybackViewController* playbackController = [PlaybackViewController playbackViewController];
    [playbackController presentFromParentViewController:self autostart:NO completion:^{
        [self setSidebarShown:NO animated:NO];
    }];
}

- (void) showDownloads:(id)sender
{
    DownloadsViewController* downloadsController = [DownloadsViewController downloadsViewController];
    
    downloadsController.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Player Close"]
                                                                                            style:UIBarButtonItemStylePlain
                                                                                           target:self
                                                                                           action:@selector(playerCloseButtonAction:)];
    
    PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:downloadsController];
    navController.toolbarHidden = NO;
    navController.modalPresentationStyle = UIModalPresentationFormSheet;
    
    [self presentViewController:navController animated:YES completion:^{
    }];
}

- (void) playerCloseButtonAction:(id)sender
{
    DownloadsViewController* downloadsController = [DownloadsViewController downloadsViewController];
    [downloadsController.presentingViewController dismissViewControllerAnimated:YES completion:NULL];
}


#pragma mark -

- (void) setNeedsContentControllerLayoutUpdateAnimated:(BOOL)animated
{
    [super setNeedsContentControllerLayoutUpdateAnimated:animated];
    
    UIEdgeInsets safeAreaInsets = UIEdgeInsetsMake(20, 0, 0, 0);
    if (@available(iOS 11.0, *)) {
        safeAreaInsets = self.view.safeAreaInsets;
    }
    
    CGRect b = self.view.bounds;
    // Now playing bar: 5px higher than before
    CGRect invisbleRect = CGRectMake(0, CGRectGetHeight(b), CGRectGetWidth(b), 49+safeAreaInsets.bottom);
    CGRect visibleRect = CGRectMake(0, CGRectGetHeight(b)-49-safeAreaInsets.bottom, CGRectGetWidth(b), 49+safeAreaInsets.bottom);
    
    if (self.activityViewController.visible && !self.activityViewController.parentViewController) {
        [self addChildViewController:self.activityViewController];
        [self.view insertSubview:self.activityViewController.view aboveSubview:self.sidebarViewController.view];
        [self.activityViewController didMoveToParentViewController:self];
    }
    else if (!self.activityViewController.visible && self.activityViewController.parentViewController) {
        [self.activityViewController willMoveToParentViewController:nil];
        [self.activityViewController.view removeFromSuperview];
        [self.activityViewController removeFromParentViewController];
    }
    
    if (animated) {
        [UIView animateWithDuration:0.3f animations:^{
            self.activityViewController.view.frame = (!self.activityViewController.visible) ? invisbleRect : visibleRect;
        }];
    }
    else
    {
        self.activityViewController.view.frame = (!self.activityViewController.visible) ? invisbleRect : visibleRect;
    }
}

- (CGRect) rectForContentControllerWhenShown:(BOOL)shown
{
    CGRect rect = [super rectForContentControllerWhenShown:shown];
    
    UIEdgeInsets safeAreaInsets = UIEdgeInsetsMake(20, 0, 0, 0);
    if (@available(iOS 11.0, *)) {
        safeAreaInsets = self.view.safeAreaInsets;
    }
    
    if (self.activityViewController.visible) {
        rect.size.height -= (safeAreaInsets.bottom);
        rect.size.height -= 49;  // Now playing bar is 5px taller (44->49)
    }
    
    return rect;
}

- (CDEpisodeList*) unplayedPlaylist
{
    CDEpisodeList* unplayedList = nil;

    // First, try to find by uid (most reliable)
    for(CDEpisodeList* list in DMANAGER.lists)
    {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            if ([list.uid isEqualToString:@"default.unplayed"]) {
                unplayedList = list;
                break;
            }
        }
    }

    // Fallback: find by icon (for backwards compatibility)
    if (!unplayedList)
    {
        for(CDEpisodeList* list in DMANAGER.lists)
        {
            if ([list isKindOfClass:[CDEpisodeList class]]) {
                if ([list.icon isEqualToString:@"List Unplayed"]) {
                    unplayedList = list;
                    break;
                }
            }
        }
    }

    if (!unplayedList)
    {
        unplayedList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:DMANAGER.objectContext];
        unplayedList.name = @"Unplayed".ls;
        unplayedList.icon = @"List Unplayed";
        unplayedList.rank = (int32_t)[DMANAGER.lists count]+1;
        unplayedList.played = NO;
        unplayedList.orderBy = @"pubDate";
        unplayedList.descending = YES;
        unplayedList.groupByPodcast = NO;
        unplayedList.continuousPlayback = YES;
        unplayedList.uid = @"default.unplayed";
        [DMANAGER save];
    }
    return unplayedList;
}

- (CDEpisodeList*) favoritesPlaylist
{
    CDEpisodeList* favoritesList = nil;

    // Find the favorites list by uid
    for(CDList* list in DMANAGER.lists)
    {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            CDEpisodeList* episodeList = (CDEpisodeList*)list;
            if ([episodeList.uid isEqualToString:@"default.favorites"]) {
                favoritesList = episodeList;
                break;
            }
        }
    }

    // Fallback: find by icon
    if (!favoritesList)
    {
        for(CDList* list in DMANAGER.lists)
        {
            if ([list isKindOfClass:[CDEpisodeList class]]) {
                CDEpisodeList* episodeList = (CDEpisodeList*)list;
                if ([episodeList.icon isEqualToString:@"List Favorites"]) {
                    favoritesList = episodeList;
                    break;
                }
            }
        }
    }

    // Create if not found
    if (!favoritesList)
    {
        favoritesList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:DMANAGER.objectContext];
        favoritesList.name = @"Favorites".ls;
        favoritesList.icon = @"List Favorites";
        favoritesList.rank = (int32_t)[DMANAGER.lists count]+1;
        favoritesList.starred = YES;
        favoritesList.orderBy = @"pubDate";
        favoritesList.descending = YES;
        favoritesList.groupByPodcast = NO;
        favoritesList.continuousPlayback = YES;
        favoritesList.uid = @"default.favorites";
        [DMANAGER save];
    }

    return favoritesList;
}

- (UIViewController*) _statusBarAdjustingContainerViewControllerForViewController:(UIViewController*)viewController
{
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    BOOL xScreen = (CGRectGetWidth(screenBounds) == 375 && CGRectGetHeight(screenBounds) == 812);
    CGFloat statusbarHeight = (xScreen) ? 44 : 20;
    
    StatusBarFixingViewController* vc = [[StatusBarFixingViewController alloc] initWithNibName:nil bundle:nil];
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    vc.view.frame = CGRectMake(0, 0, 100, 100);
    viewController.view.frame = CGRectMake(0, statusbarHeight, 100, 100-statusbarHeight);
    [vc addChildViewController:viewController];
    [vc.view addSubview:viewController.view];
    [viewController didMoveToParentViewController:vc];
    return vc;
}

- (BOOL) _selectMainSidebarItemWithTag:(NSInteger)tag
{
    switch (tag) {
        case kMainSidebarItemLists:
        {
            PlaylistsTableViewController* controller = [PlaylistsTableViewController viewController];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }

        case kMainSidebarItemSettings:
        {
            OptionsViewController* controller = [OptionsViewController optionsViewController];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;
            
            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            return YES;
        }

        case kMainSidebarItemBookmarks:
        {
            BookmarksTableViewController* controller = [BookmarksTableViewController bookmarksController];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }
        case kMainSidebarItemUnplayed:
        {
            UIViewController* controller = [ListEpisodesTableViewController viewControllerWithList:[self unplayedPlaylist]];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }
        case kMainSidebarItemFavorites:
        {
            UIViewController* controller = [ListEpisodesTableViewController viewControllerWithList:[self favoritesPlaylist]];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }
        case kMainSidebarItemUpNext:
        {
            UpNextTableViewController* controller = [UpNextTableViewController viewController];
            controller.presentedAsMainView = YES;
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }
        case kMainSidebarItemDownloads:
        {
            UIViewController* controller = [DownloadsViewController downloadsViewController];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }

        default:
        case kMainSidebarItemSubscriptions:
        {
            SubscriptionsTableViewController* controller = [SubscriptionsTableViewController subscriptionsController];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }
    }

    return NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        return UIInterfaceOrientationMaskAll;
    }
    
    return UIInterfaceOrientationMaskPortrait;
}


- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation duration:(NSTimeInterval)duration
{
    [self animateAdditionalSidebarViewsDuringShow:self.sidebarShown];
}


- (void) showShowNotesOfEpisode:(CDEpisode*)episode animated:(BOOL)animated
{
    if (self.presentedViewController)
    {
        [self clearViewControllerPresentationQueue];
        [self dismissViewControllerAnimated:NO completion:NULL];
    }
    
    
    if (self.sidebarController.selectedItemTag != kMainSidebarItemSubscriptions) {
        if ([self _selectMainSidebarItemWithTag:kMainSidebarItemSubscriptions]) {
            self.sidebarController.selectedItemTag = kMainSidebarItemSubscriptions;
        }
    }
    
    [USER_DEFAULTS setObject:episode.uid forKey:kDefaultEpisodesSelectedEpisodeUID];
    

    UIViewController* contentViewController = self.contentViewController;
    UINavigationController* navigationController = [contentViewController.childViewControllers firstObject];
    [navigationController popToRootViewControllerAnimated:NO];
    
    SubscriptionsTableViewController* subscriptionTableViewController = [navigationController.viewControllers firstObject];
    [subscriptionTableViewController showEpisodeListForFeed:episode.feed animated:NO];
}

- (void) playerCloseButtonAction2:(id)sender
{
    [self.presentedViewController dismissViewControllerAnimated:YES completion:^(void) {
        [self presentNextViewController];
    }];
}



@end
