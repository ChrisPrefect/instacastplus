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
    kMainSidebarItemStarted         = 12,
};

NSString* MainMenuListUIDsDidChangeNotification = @"MainMenuListUIDsDidChangeNotification";

@interface MainViewController_4 () <UINavigationControllerDelegate,OnboardScreenVCDelegate>
@property (nonatomic, strong, readwrite) UINavigationController* rootNavigationController;
@property (nonatomic, strong, readwrite) MainSidebarController* sidebarController;
@property (nonatomic, strong, readwrite) MainActivityViewController* activityViewController;

@property (nonatomic, readonly) CDEpisodeList* unplayedPlaylist;
@property (nonatomic, readonly) CDEpisodeList* favoritesPlaylist;
@property (nonatomic, readonly) CDEpisodeList* startedPlaylist;
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
            for (NSArray* section in weakSelf.sidebarController.items) {
                for (MainSidebarItem* item in section) {
                    if (item.tag == kMainSidebarItemUnplayed) {
                        item.title = weakSelf.unplayedPlaylist.name.ls;
                        break;
                    }
                }
            }
        }];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(updateAppearance)
                                                     name:ICAppearanceManagerDidUpdateAppearanceNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_mainMenuListUIDsDidChange:)
                                                     name:MainMenuListUIDsDidChangeNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_cacheManagerDidUpdate:)
                                                     name:CacheManagerDidUpdateNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(_cacheManagerDidUpdate:)
                                                     name:CacheManagerDidEndCachingNotification
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
    [self coalescedPerformSelector:@selector(_reloadSidebarAfterCacheUpdate) afterDelay:0.2];
}

- (void) _reloadSidebarAfterCacheUpdate
{
    if (!self.isViewLoaded || !self.view.window) {
        return;
    }

    // Reload sidebar to update download speed display
    [self.sidebarController.tableView reloadData];
    [self.sidebarController updateRowSelectionForSelectedItemTag];
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

    // Initialize MainMenuListUIDs with defaults if not set
    // Also migrate: if key exists but doesn't contain default list UIDs, add them
    NSArray* existingUIDs = [USER_DEFAULTS objectForKey:@"MainMenuListUIDs"];
    if (!existingUIDs) {
        [USER_DEFAULTS setObject:@[@"default.favorites", @"default.unplayed", @"default.started", @"default.downloaded"] forKey:@"MainMenuListUIDs"];
        [USER_DEFAULTS synchronize];
    } else if (![USER_DEFAULTS boolForKey:@"MainMenuListUIDsMigratedDefaults"]) {
        // One-time migration: add default list UIDs that were previously hardcoded
        NSMutableArray* uids = [existingUIDs mutableCopy];
        NSArray* defaults = @[@"default.favorites", @"default.unplayed", @"default.started"];
        for (NSString* uid in defaults) {
            if (![uids containsObject:uid]) {
                [uids insertObject:uid atIndex:0];
            }
        }
        [USER_DEFAULTS setObject:uids forKey:@"MainMenuListUIDs"];
        [USER_DEFAULTS setBool:YES forKey:@"MainMenuListUIDsMigratedDefaults"];
        [USER_DEFAULTS synchronize];
    }

    [self _rebuildSidebarItems];
    
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
    // Bottom padding: mindestens 21pt damit label3 (y=49, h=17 → bottom=66) sichtbar bleibt,
    // auch wenn safeAreaInsets.bottom = 0 (iPad Stage Manager Fenster-Modus)
    CGFloat bottomPadding = MAX(safeAreaInsets.bottom, 21);
    CGRect invisbleRect = CGRectMake(0, CGRectGetHeight(b), CGRectGetWidth(b), 49+bottomPadding);
    CGRect visibleRect = CGRectMake(0, CGRectGetHeight(b)-49-bottomPadding, CGRectGetWidth(b), 49+bottomPadding);
    
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
        CGFloat bottomPadding = MAX(safeAreaInsets.bottom, 21);
        rect.size.height -= bottomPadding;
        rect.size.height -= 49;
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

- (CDEpisodeList*) startedPlaylist
{
    CDEpisodeList* startedList = nil;

    // Find by uid
    for(CDList* list in DMANAGER.lists)
    {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            CDEpisodeList* episodeList = (CDEpisodeList*)list;
            if ([episodeList.uid isEqualToString:@"default.started"]) {
                startedList = episodeList;
                break;
            }
        }
    }

    // Create if not found
    if (!startedList)
    {
        startedList = [NSEntityDescription insertNewObjectForEntityForName:@"EpisodeList" inManagedObjectContext:DMANAGER.objectContext];
        startedList.name = @"Started".ls;
        startedList.icon = @"List Partially Played";
        startedList.rank = (int32_t)[DMANAGER.lists count]+1;
        startedList.unfinished = YES;
        startedList.unplayed = NO;
        startedList.played = NO;
        startedList.orderBy = @"lastPlayed";
        startedList.descending = YES;
        startedList.groupByPodcast = NO;
        startedList.continuousPlayback = YES;
        startedList.uid = @"default.started";
        [DMANAGER save];
    }

    return startedList;
}

- (CDEpisodeList*) _episodeListForUID:(NSString*)uid
{
    for (CDList* list in DMANAGER.lists) {
        if ([list isKindOfClass:[CDEpisodeList class]] && [list.uid isEqualToString:uid]) {
            return (CDEpisodeList*)list;
        }
    }
    return nil;
}

- (void) _mainMenuListUIDsDidChange:(NSNotification*)notification
{
    [self _rebuildSidebarItems];
    [self.sidebarController.tableView reloadData];
    [self.sidebarController updateRowSelectionForSelectedItemTag];
}

- (NSInteger) _tagForListUID:(NSString*)uid
{
    // Map known default UIDs to their existing enum tags for backward compatibility
    if ([uid isEqualToString:@"default.unplayed"])  return kMainSidebarItemUnplayed;
    if ([uid isEqualToString:@"default.favorites"]) return kMainSidebarItemFavorites;
    if ([uid isEqualToString:@"default.started"])   return kMainSidebarItemStarted;
    return -1; // dynamic
}

- (MainSidebarItem*) _sidebarItemForListUID:(NSString*)uid dynamicTag:(NSInteger*)dynamicTag
{
    CDEpisodeList* list = [self _episodeListForUID:uid];
    if (!list) return nil;

    NSInteger tag = [self _tagForListUID:uid];
    UIImage* image;
    UIImage* selectedImage;
    CGFloat topSpacing = 0;
    UIImageSymbolConfiguration* config = [UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleLarge];

    if ([uid isEqualToString:@"default.favorites"]) {
        image = [UIImage systemImageNamed:@"star" withConfiguration:config];
        selectedImage = [UIImage systemImageNamed:@"star.fill" withConfiguration:config];
    } else if ([uid isEqualToString:@"default.unplayed"]) {
        image = [UIImage imageNamed:@"Menu Unplayed"];
        selectedImage = [UIImage imageNamed:@"Menu Unplayed Filled"];
    } else if ([uid isEqualToString:@"default.started"]) {
        image = [[UIImage imageNamed:@"List Partially Played"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        selectedImage = image;
    } else {
        // Dynamic custom list
        tag = (*dynamicTag)++;
        image = [list.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        selectedImage = image;
    }

    return [MainSidebarItem itemWithTitle:list.name.ls tag:tag image:image selectedImage:selectedImage topSpacing:topSpacing];
}

- (void) _rebuildSidebarItems
{
    NSMutableArray* section1 = [NSMutableArray array];

    [section1 addObject:[MainSidebarItem itemWithTitle:@"Podcasts".ls
                                                   tag:kMainSidebarItemSubscriptions
                                                 image:[UIImage imageNamed:@"Menu Subscriptions"]
                                         selectedImage:[UIImage imageNamed:@"Menu Subscriptions Filled"]]];

    // Add list items from MainMenuListUIDs
    NSArray* mainMenuUIDs = [USER_DEFAULTS objectForKey:@"MainMenuListUIDs"];
    NSInteger dynamicTag = 100;
    BOOL firstListItem = YES;
    for (NSString* uid in mainMenuUIDs) {
        MainSidebarItem* item = [self _sidebarItemForListUID:uid dynamicTag:&dynamicTag];
        if (item) {
            if (firstListItem) {
                item.topSpacing = 22;
                firstListItem = NO;
            }
            [section1 addObject:item];
        }
    }

    [section1 addObject:[MainSidebarItem itemWithTitle:@"Lists".ls
                                                   tag:kMainSidebarItemLists
                                                 image:[UIImage imageNamed:@"Menu Lists"]
                                         selectedImage:[UIImage imageNamed:@"Menu Lists"]]];

    [section1 addObject:[MainSidebarItem itemWithTitle:@"Play Next".ls
                                                   tag:kMainSidebarItemUpNext
                                                 image:[UIImage systemImageNamed:@"list.bullet.indent" withConfiguration:[UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleLarge]]
                                         selectedImage:[UIImage systemImageNamed:@"list.bullet.indent" withConfiguration:[UIImageSymbolConfiguration configurationWithScale:UIImageSymbolScaleLarge]]
                                            topSpacing:22]];

    [section1 addObject:[MainSidebarItem itemWithTitle:@"Bookmarks".ls
                                                   tag:kMainSidebarItemBookmarks
                                                 image:[UIImage imageNamed:@"Menu Bookmarks"]
                                         selectedImage:[UIImage imageNamed:@"Menu Bookmarks Filled"]]];

    MainSidebarItem* downloadsItem = [MainSidebarItem itemWithTitle:@"Downloads".ls
                                                                tag:kMainSidebarItemDownloads
                                                              image:[UIImage imageNamed:@"Menu Downloads"]
                                                      selectedImage:[UIImage imageNamed:@"Menu Downloads Filled"]
                                                         topSpacing:22];
    downloadsItem.subtitle = ^NSString*{
        CacheManager* cman = [CacheManager sharedCacheManager];
        if ([cman isCaching] && ![cman isCachingSuspended]) {
            double rate = cman.rate;
            if (rate > 1024) {
                NSString* rateString = [NSByteCountFormatter stringFromByteCount:(long long)rate countStyle:NSByteCountFormatterCountStyleMemory];
                return [NSString stringWithFormat:@"%@/s", rateString];
            }
        }
        return nil;
    };

    NSArray* section2 = @[
        downloadsItem,
        [MainSidebarItem itemWithTitle:@"Settings".ls
                                   tag:kMainSidebarItemSettings
                                 image:[UIImage imageNamed:@"Menu Settings"]
                         selectedImage:[UIImage imageNamed:@"Menu Settings"]],
    ];

    self.sidebarController.items = @[section1, section2];
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

- (CDEpisodeList*) _episodeListForDynamicTag:(NSInteger)tag
{
    if (tag < 100) return nil;
    NSArray* mainMenuUIDs = [USER_DEFAULTS objectForKey:@"MainMenuListUIDs"];
    NSInteger dynamicTag = 100;
    for (NSString* uid in mainMenuUIDs) {
        if ([self _tagForListUID:uid] != -1) continue; // skip default UIDs (they have fixed tags)
        if (dynamicTag == tag) {
            return [self _episodeListForUID:uid];
        }
        dynamicTag++;
    }
    return nil;
}

- (BOOL) _selectMainSidebarItemWithTag:(NSInteger)tag
{
    // Handle dynamic list items (tag >= 100)
    if (tag >= 100) {
        CDEpisodeList* list = [self _episodeListForDynamicTag:tag];
        if (list) {
            UIViewController* controller = [ListEpisodesTableViewController viewControllerWithList:list];
            controller.navigationItem.leftBarButtonItem = self.sidebarMenuItem;

            PortraitNavigationController* navController = [[PortraitNavigationController alloc] initWithRootViewController:controller];
            navController.view.tintColor = ICTintColor;
            self.contentViewController = [self _statusBarAdjustingContainerViewControllerForViewController:navController];
            navController.toolbarHidden = NO;
            return YES;
        }
    }

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
        case kMainSidebarItemStarted:
        {
            UIViewController* controller = [ListEpisodesTableViewController viewControllerWithList:[self startedPlaylist]];
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
