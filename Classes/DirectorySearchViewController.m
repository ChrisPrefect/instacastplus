    //
//  DirectorySearchViewController.m
//  Instacast
//
//  Created by Martin Hering on 17.01.11.
//  Copyright 2011 Vemedio. All rights reserved.
//

#import "DirectorySearchViewController.h"
#import "DirectoryFeedTableViewCell.h"
#import "DirectoryFeedViewController.h"

#import "STITunesStore.h"
#import "ICFeedURLScraper.h"
#import "ICFeedParser.h"
#import "ICSearchBar.h"
#import "ApplePodcastChartsClient.h"

static NSInteger const kChartsDisplayLimit = 50;
static NSInteger const kChartsGenreMinCount = 5;

@interface DirectorySearchViewController ()
@property (nonatomic, strong) ICSearchBar* searchBar;
@property (nonatomic, strong) NSString* searchTerm;
@property (nonatomic, strong) STITunesStore* store;
@property (nonatomic, strong) NSArray* searchResults;
@property (nonatomic, strong) NSMutableDictionary* imageCache;
@property (nonatomic, weak) NSTimer* searchTimer;
@property (nonatomic, strong) ICFeedURLScraper* scraper;
@property (nonatomic, strong) ICFeedParser* feedParser;
@property (nonatomic) BOOL searchBarActive;

// Charts
@property (nonatomic, strong) NSArray* chartsAllResults;      // All 100 from API
@property (nonatomic, strong) NSArray* chartsFilteredResults;  // Filtered + capped to 50
@property (nonatomic, strong) NSArray* chartsGenres;           // Array of @{@"genreId", @"name", @"count"}
@property (nonatomic, strong) NSString* selectedGenreId;       // nil = "Alle"
@property (nonatomic) BOOL chartsLoading;
@property (nonatomic, strong) NSURLSessionDataTask* chartsLookupTask;

// Genre dropdown
@property (nonatomic, strong) UIView* genreDropdownOverlay;
@property (nonatomic, strong) NSArray* genreDropdownItems;
@end

NSString* kUIPersistenceDirectorySearchSearchString = @"SearchControllerSearchString";
NSString* kUIPersistenceDirectorySearchSelectedScopeIndex = @"DirectorySearchSelectedScopeIndex";


@implementation DirectorySearchViewController

+ (DirectorySearchViewController*) directorySearchViewController
{
	return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (BOOL)_isShowingCharts
{
    return [self.searchBar.text length] == 0 && self.searchResults == nil;
}

// Implement viewDidLoad to do additional setup after loading the view, typically from a nib.
- (void)viewDidLoad
{
    [super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAppearance) name:ICAppearanceManagerDidUpdateAppearanceNotification object:nil];

    self.title = @"Search".ls;

    self.tableView.rowHeight = 57+10;
    self.tableView.separatorInset = UIEdgeInsetsZero;

	ICSearchBar* searchBar = [[ICSearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar = searchBar;

    searchBar.backgroundImage = [[UIImage alloc] init];
    searchBar.scopeBarBackgroundImage = [[UIImage alloc] init];

	searchBar.delegate = self;
	searchBar.scopeButtonTitles = [NSArray arrayWithObjects:@"Title".ls, @"Author".ls, @"Description".ls, nil];
	searchBar.showsScopeBar = YES;
	searchBar.selectedScopeButtonIndex = [USER_DEFAULTS integerForKey:kUIPersistenceDirectorySearchSelectedScopeIndex];
	searchBar.placeholder = @"Search or Enter URL".ls;
    searchBar.translucent = YES;
    searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
	[searchBar sizeToFit];

	self.tableView.tableHeaderView = searchBar;

	self.imageCache = [NSMutableDictionary dictionary];

    // Load charts: 50 from new API (fast) + 20/genre from old API (background)
    [self _loadCharts];
}

-(void)searchBarColorUpdates
{
    UIColor *textColor = ICTextColor;
    UIColor *tintColorD = ICMutedTextColor;

    UITextField *searchTextField = self.searchBar.searchTextField;
    searchTextField.textColor = textColor;
    searchTextField.tintColor = tintColorD;
    searchTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Search".ls attributes:@{NSForegroundColorAttributeName: ICPlaceholderTextColor}];

    UIImageView *iconView = (UIImageView *)searchTextField.leftView;
    iconView.image = [iconView.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    iconView.tintColor = tintColorD;

    UIButton *clearButton = [searchTextField valueForKey:@"_clearButton"];
    [clearButton setImage:[[clearButton imageForState:UIControlStateNormal] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] forState:UIControlStateNormal];
    clearButton.tintColor = tintColorD;
}

- (void) updateAppearance
{
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;
    [self searchBarColorUpdates];
    [self.searchBar appearanceDidChange];
    [self.tableView reloadData];
}

- (void) viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;

    [self.searchBar appearanceDidChange];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"Player Close"] style:UIBarButtonItemStylePlain target:self action:@selector(close:)];

	[self.tableView reloadData];
    [self searchBarColorUpdates];
}

- (void) viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
}

- (void) viewWillDisappear:(BOOL)animated
{
	[super viewWillDisappear:animated];

	[self.searchTimer invalidate];
	self.searchTimer = nil;
	[self _dismissGenreDropdown];

	[NSRunLoop cancelPreviousPerformRequestsWithTarget:self];
}


- (void)dealloc {

	[_store cancelStoreSearch];
	[_scraper cancel];
	[_feedParser cancel];
    [_chartsLookupTask cancel];
}

- (void) close:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:NULL];
}

#pragma mark - Charts Loading & Filtering

- (void)_loadCharts
{
    ApplePodcastChartsClient *client = [ApplePodcastChartsClient sharedClient];

    // 1. Show cached data instantly (merged from both sources, even if stale)
    NSArray *cachedMain = [client cachedTopPodcastsForCountryCode:nil limit:50];
    NSArray *cachedGenres = [client cachedGenrePodcastsForCountryCode:nil];
    if (cachedMain.count > 0 || cachedGenres.count > 0) {
        self.chartsAllResults = [self _mergeMainResults:cachedMain withGenreResults:cachedGenres];
        [self _buildGenreList];
        [self _applyGenreFilter];
        [self.tableView reloadData];
    }

    // 2. Fetch both sources in parallel
    self.chartsLoading = YES;
    __weak typeof(self) weakSelf = self;

    // Phase 1: 50 from new API (fast, single request)
    [client fetchTopPodcastsWithCountryCode:nil limit:50 completion:^(NSArray *results, NSString *updated, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (results) {
            NSArray *genreResults = [client cachedGenrePodcastsForCountryCode:nil];
            strongSelf.chartsAllResults = [strongSelf _mergeMainResults:results withGenreResults:genreResults];
            [strongSelf _buildGenreList];
            [strongSelf _applyGenreFilter];
            if ([strongSelf _isShowingCharts]) {
                [strongSelf.tableView reloadData];
            }
        }
    }];

    // Phase 2: 20 per genre from old iTunes RSS API (background enrichment)
    [client fetchGenrePodcastsWithCountryCode:nil limitPerGenre:20 completion:^(NSArray *genreResults, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf.chartsLoading = NO;

        if (genreResults.count > 0) {
            NSArray *mainResults = [client cachedTopPodcastsForCountryCode:nil limit:50];
            strongSelf.chartsAllResults = [strongSelf _mergeMainResults:mainResults withGenreResults:genreResults];
            [strongSelf _buildGenreList];
            [strongSelf _applyGenreFilter];
            if ([strongSelf _isShowingCharts]) {
                [strongSelf.tableView reloadData];
            }
        }
    }];
}

- (NSArray *)_mergeMainResults:(NSArray *)mainResults withGenreResults:(NSArray *)genreResults
{
    if (!mainResults && !genreResults) return nil;
    if (!genreResults) return mainResults;
    if (!mainResults) return genreResults;

    NSMutableArray *merged = [NSMutableArray arrayWithArray:mainResults];
    NSMutableSet *existingIDs = [NSMutableSet set];
    for (NSDictionary *item in mainResults) {
        NSString *podcastId = item[kAppleChartsID];
        if (podcastId) [existingIDs addObject:podcastId];
    }

    for (NSDictionary *item in genreResults) {
        NSString *podcastId = item[kAppleChartsID];
        if (podcastId && ![existingIDs containsObject:podcastId]) {
            [merged addObject:item];
            [existingIDs addObject:podcastId];
        }
    }

    return [merged copy];
}

- (NSDictionary *)_subToParentGenreMapping
{
    static NSDictionary *mapping = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mapping = @{
            // Arts subs → 1301
            @"1482": @"1301", @"1402": @"1301", @"1459": @"1301",
            @"1306": @"1301", @"1405": @"1301",
            // Comedy subs → 1303
            @"1496": @"1303", @"1495": @"1303", @"1497": @"1303",
            // Education subs → 1304
            @"1501": @"1304", @"1499": @"1304", @"1498": @"1304", @"1500": @"1304",
            // Kids & Family subs → 1305
            @"1519": @"1305", @"1520": @"1305", @"1521": @"1305", @"1522": @"1305",
            // TV & Film subs → 1309
            @"1562": @"1309", @"1564": @"1309", @"1565": @"1309",
            @"1563": @"1309", @"1561": @"1309",
            // Music subs → 1310
            @"1523": @"1310", @"1524": @"1310", @"1525": @"1310",
            // Religion subs → 1314
            @"1438": @"1314", @"1439": @"1314", @"1463": @"1314",
            @"1440": @"1314", @"1441": @"1314",
            // Business subs → 1321
            @"1410": @"1321", @"1493": @"1321", @"1412": @"1321",
            @"1491": @"1321", @"1492": @"1321", @"1494": @"1321",
            // Society & Culture subs → 1324
            @"1543": @"1324", @"1302": @"1324", @"1443": @"1324",
            @"1320": @"1324", @"1544": @"1324",
            // Fiction subs → 1483
            @"1486": @"1483", @"1484": @"1483", @"1485": @"1483",
            // News subs → 1489
            @"1526": @"1489", @"1490": @"1489", @"1531": @"1489",
            @"1530": @"1489", @"1527": @"1489", @"1529": @"1489", @"1528": @"1489",
            // Leisure subs → 1502
            @"1510": @"1502", @"1503": @"1502", @"1504": @"1502",
            @"1506": @"1502", @"1507": @"1502",
            // Health & Fitness subs → 1512
            @"1513": @"1512", @"1514": @"1512", @"1518": @"1512", @"1517": @"1512",
            // Science subs → 1533
            @"1538": @"1533", @"1539": @"1533", @"1540": @"1533",
            @"1541": @"1533", @"1536": @"1533",
            // Sports subs → 1545
            @"1547": @"1545", @"1548": @"1545", @"1546": @"1545",
            @"1550": @"1545", @"1560": @"1545",
        };
    });
    return mapping;
}

- (NSString *)_resolveToParentGenreId:(NSString *)genreId
{
    return [self _subToParentGenreMapping][genreId] ?: genreId;
}

- (void)_buildGenreList
{
    NSDictionary *subToParent = [self _subToParentGenreMapping];

    // Fallback names for parent genres (English) in case no localized name found
    static NSDictionary *fallbackNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fallbackNames = @{
            @"1301": @"Arts", @"1303": @"Comedy", @"1304": @"Education",
            @"1305": @"Kids & Family", @"1309": @"TV & Film", @"1310": @"Music",
            @"1314": @"Religion & Spirituality", @"1318": @"Technology",
            @"1321": @"Business", @"1324": @"Society & Culture",
            @"1483": @"Fiction", @"1487": @"History", @"1488": @"True Crime",
            @"1489": @"News", @"1502": @"Leisure", @"1511": @"Government",
            @"1512": @"Health & Fitness", @"1533": @"Science", @"1545": @"Sports",
        };
    });

    // Count podcasts per parent AND per individual sub-genre
    NSMutableDictionary *parentCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary *parentNames = [NSMutableDictionary dictionary];
    NSMutableDictionary *subCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary *subNames = [NSMutableDictionary dictionary];

    for (NSDictionary *entry in self.chartsAllResults) {
        NSArray *genreIDs = entry[kAppleChartsGenreIDs];
        NSString *genresString = entry[kAppleChartsGenres];
        if (![genreIDs isKindOfClass:[NSArray class]]) continue;

        NSArray *names = [genresString componentsSeparatedByString:@", "];
        NSMutableSet *countedParents = [NSMutableSet set];

        for (NSUInteger i = 0; i < genreIDs.count; i++) {
            NSString *genreId = genreIDs[i];
            NSString *parentId = subToParent[genreId] ?: genreId;

            // Count each parent only once per podcast
            if (![countedParents containsObject:parentId]) {
                [countedParents addObject:parentId];
                parentCounts[parentId] = @([parentCounts[parentId] integerValue] + 1);
            }

            // Track parent localized name from direct parent genre matches
            if ([genreId isEqualToString:parentId] && i < names.count && !parentNames[parentId]) {
                parentNames[parentId] = names[i];
            }

            // Track sub-genre count and name (if it IS a sub)
            if (subToParent[genreId]) {
                subCounts[genreId] = @([subCounts[genreId] integerValue] + 1);
                if (i < names.count && !subNames[genreId]) {
                    subNames[genreId] = names[i];
                }
            }
        }
    }

    // Group sub-genres by parent
    NSMutableDictionary *subsByParent = [NSMutableDictionary dictionary];
    for (NSString *subId in subCounts) {
        NSString *parentId = subToParent[subId];
        if (!parentId) continue;
        NSInteger count = [subCounts[subId] integerValue];
        if (count < 2) continue; // minimum threshold for subs

        if (!subsByParent[parentId]) subsByParent[parentId] = [NSMutableArray array];
        [subsByParent[parentId] addObject:@{
            @"genreId": subId,
            @"name": subNames[subId] ?: subId,
            @"count": @(count)
        }];
    }

    // Sort subs alphabetically within each parent
    for (NSString *parentId in subsByParent) {
        [subsByParent[parentId] sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
        }];
    }

    // Build parent genre list with subs attached
    NSMutableArray *genres = [NSMutableArray array];
    for (NSString *parentId in parentCounts) {
        NSInteger count = [parentCounts[parentId] integerValue];
        if (count < kChartsGenreMinCount) continue;

        NSMutableDictionary *entry = [@{
            @"genreId": parentId,
            @"name": parentNames[parentId] ?: fallbackNames[parentId] ?: parentId,
            @"count": @(count)
        } mutableCopy];

        NSArray *subs = subsByParent[parentId];
        if (subs.count > 0) {
            entry[@"subs"] = subs;
        }

        [genres addObject:entry];
    }

    // Sort by count descending
    [genres sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"count"] compare:a[@"count"]];
    }];

    self.chartsGenres = [genres copy];
}

- (void)_applyGenreFilter
{
    NSArray *source = self.chartsAllResults;
    if (!source) {
        self.chartsFilteredResults = nil;
        return;
    }

    if (self.selectedGenreId) {
        // Check if selectedGenreId is a parent or a sub-genre
        BOOL isSubGenre = ([self _subToParentGenreMapping][self.selectedGenreId] != nil);

        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *entry in source) {
            NSArray *genreIDs = entry[kAppleChartsGenreIDs];
            if (![genreIDs isKindOfClass:[NSArray class]]) continue;

            BOOL matches = NO;
            if (isSubGenre) {
                // Match exact sub-genre ID
                matches = [genreIDs containsObject:self.selectedGenreId];
            } else {
                // Match any genre that resolves to this parent
                for (NSString *gid in genreIDs) {
                    NSString *parentId = [self _resolveToParentGenreId:gid];
                    if ([parentId isEqualToString:self.selectedGenreId]) {
                        matches = YES;
                        break;
                    }
                }
            }
            if (matches) {
                [filtered addObject:entry];
                if (filtered.count >= kChartsDisplayLimit) break;
            }
        }
        self.chartsFilteredResults = [filtered copy];
    } else {
        // "Alle Kategorien" — show first 50
        if (source.count > kChartsDisplayLimit) {
            self.chartsFilteredResults = [source subarrayWithRange:NSMakeRange(0, kChartsDisplayLimit)];
        } else {
            self.chartsFilteredResults = source;
        }
    }
}

- (NSString *)_selectedGenreName
{
    if (!self.selectedGenreId) {
        return @"All Categories".ls;
    }
    for (NSDictionary *genre in self.chartsGenres) {
        if ([genre[@"genreId"] isEqualToString:self.selectedGenreId]) {
            return genre[@"name"];
        }
        for (NSDictionary *sub in genre[@"subs"]) {
            if ([sub[@"genreId"] isEqualToString:self.selectedGenreId]) {
                return sub[@"name"];
            }
        }
    }
    return @"All Categories".ls;
}

#pragma mark - Genre Menu

- (void)_showGenreDropdown:(UIButton *)sender
{
    if (self.genreDropdownOverlay) {
        [self _dismissGenreDropdown];
        return;
    }

    // Build flat items list
    NSMutableArray *items = [NSMutableArray array];
    [items addObject:@{@"type": @"all", @"title": @"All Categories".ls, @"genreId": @""}];
    for (NSDictionary *parent in self.chartsGenres) {
        [items addObject:@{@"type": @"parent", @"title": parent[@"name"], @"genreId": parent[@"genreId"]}];
        for (NSDictionary *sub in parent[@"subs"]) {
            [items addObject:@{@"type": @"sub", @"title": sub[@"name"], @"genreId": sub[@"genreId"]}];
        }
    }
    self.genreDropdownItems = items;

    // Layout constants
    CGFloat rowHeight = 32;
    CGFloat menuWidth = 250;
    CGFloat maxHeight = 560;
    CGFloat leftPad = 21;
    CGFloat subLeftPad = 43;
    CGFloat rightPad = 8;
    CGFloat iconSize = 16;
    CGFloat iconGap = 5;
    CGFloat bottomScreenMargin = 64; // ~2 rows from screen bottom

    // Overlay (catches taps outside menu to dismiss)
    UIView *parentView = self.navigationController.view ?: self.view;
    UIControl *overlay = [[UIControl alloc] initWithFrame:parentView.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [UIColor clearColor];
    [overlay addTarget:self action:@selector(_dismissGenreDropdown) forControlEvents:UIControlEventTouchUpInside];

    // Position: top-aligned to button, extends downward to near screen bottom
    CGRect buttonFrame = [sender convertRect:sender.bounds toView:parentView];
    CGFloat menuX = MAX(8, CGRectGetMaxX(buttonFrame) - menuWidth);
    CGFloat menuY = CGRectGetMinY(buttonFrame) - 4;
    CGFloat availableHeight = parentView.bounds.size.height - menuY - bottomScreenMargin;
    CGFloat totalHeight = MIN(items.count * rowHeight, availableHeight);
    UIView *shadowWrap = [[UIView alloc] initWithFrame:CGRectMake(menuX, menuY, menuWidth, totalHeight)];
    shadowWrap.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowWrap.layer.shadowOpacity = 0.25;
    shadowWrap.layer.shadowRadius = 16;
    shadowWrap.layer.shadowOffset = CGSizeMake(0, 6);

    // Blurred background
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blur.frame = shadowWrap.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.layer.cornerRadius = 10;
    blur.clipsToBounds = YES;
    [shadowWrap addSubview:blur];

    // Scroll view
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:blur.contentView.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = NO;
    [blur.contentView addSubview:scroll];

    CGFloat y = 0;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = items[i];
        BOOL isAll = [item[@"type"] isEqualToString:@"all"];
        BOOL isSub = [item[@"type"] isEqualToString:@"sub"];
        NSString *genreId = item[@"genreId"];
        BOOL isSelected = (isAll && !self.selectedGenreId) ||
                          (genreId.length > 0 && [self.selectedGenreId isEqualToString:genreId]);

        UIControl *row = [[UIControl alloc] initWithFrame:CGRectMake(0, y, menuWidth, rowHeight)];
        row.tag = (NSInteger)i;
        [row addTarget:self action:@selector(_genreDropdownRowTapped:) forControlEvents:UIControlEventTouchUpInside];

        if (isSelected) {
            row.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.15];
        }

        CGFloat textX;
        if (isSub) {
            textX = subLeftPad;
        } else {
            UIImage *icon = isAll ? [UIImage systemImageNamed:@"list.bullet"] : [self _symbolForGenreId:genreId];
            if (icon) {
                UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
                UIImageView *iv = [[UIImageView alloc] initWithImage:[icon imageWithConfiguration:cfg]];
                iv.tintColor = ICTintColor;
                iv.contentMode = UIViewContentModeScaleAspectFit;
                iv.frame = CGRectMake(leftPad, (rowHeight - iconSize) / 2, iconSize, iconSize);
                [row addSubview:iv];
            }
            textX = leftPad + iconSize + iconGap;
        }

        // Label
        CGFloat labelRight = isSelected ? rightPad + 20 : rightPad;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(textX, 0, menuWidth - textX - labelRight, rowHeight)];
        label.text = item[@"title"];
        label.font = isSub
            ? [UIFont systemFontOfSize:14]
            : [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        label.textColor = ICTextColor;
        [row addSubview:label];

        // Checkmark
        if (isSelected) {
            UIImageSymbolConfiguration *chkCfg = [UIImageSymbolConfiguration configurationWithPointSize:11 weight:UIImageSymbolWeightSemibold];
            UIImageView *chk = [[UIImageView alloc] initWithImage:
                [[UIImage systemImageNamed:@"checkmark"] imageWithConfiguration:chkCfg]];
            chk.tintColor = ICTintColor;
            chk.frame = CGRectMake(menuWidth - rightPad - 14, (rowHeight - 12) / 2, 14, 12);
            [row addSubview:chk];
        }

        // Separator line
        if (i < items.count - 1) {
            CGFloat sepLeft = isSub ? subLeftPad : 0;
            UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(sepLeft, rowHeight - 0.5, menuWidth - sepLeft, 0.5)];
            sep.backgroundColor = [UIColor separatorColor];
            [row addSubview:sep];
        }

        [scroll addSubview:row];
        y += rowHeight;
    }
    scroll.contentSize = CGSizeMake(menuWidth, y);

    // Scroll to selected item
    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *item = items[i];
        BOOL isAll = [item[@"type"] isEqualToString:@"all"];
        NSString *genreId = item[@"genreId"];
        BOOL isSelected = (isAll && !self.selectedGenreId) ||
                          (genreId.length > 0 && [self.selectedGenreId isEqualToString:genreId]);
        if (isSelected) {
            CGFloat targetY = i * rowHeight;
            CGFloat maxOffset = scroll.contentSize.height - scroll.bounds.size.height;
            if (maxOffset > 0) {
                [scroll setContentOffset:CGPointMake(0, MIN(targetY, maxOffset)) animated:NO];
            }
            break;
        }
    }

    [overlay addSubview:shadowWrap];
    [parentView addSubview:overlay];
    self.genreDropdownOverlay = overlay;

    // Animate in
    shadowWrap.alpha = 0;
    shadowWrap.transform = CGAffineTransformMakeTranslation(0, -4);
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        shadowWrap.alpha = 1;
        shadowWrap.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)_dismissGenreDropdown
{
    if (!self.genreDropdownOverlay) return;
    UIView *overlay = self.genreDropdownOverlay;
    self.genreDropdownOverlay = nil;
    self.genreDropdownItems = nil;

    [UIView animateWithDuration:0.15 animations:^{
        overlay.alpha = 0;
    } completion:^(BOOL finished) {
        [overlay removeFromSuperview];
    }];
}

- (void)_genreDropdownRowTapped:(UIControl *)sender
{
    NSUInteger index = (NSUInteger)sender.tag;
    if (index >= self.genreDropdownItems.count) return;

    NSDictionary *item = self.genreDropdownItems[index];
    BOOL isAll = [item[@"type"] isEqualToString:@"all"];

    self.selectedGenreId = isAll ? nil : item[@"genreId"];
    [self _applyGenreFilter];
    [self.tableView reloadData];
    [self _dismissGenreDropdown];
}

- (UIImage *)_symbolForGenreId:(NSString *)genreId
{
    static NSDictionary *genreSymbols = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        genreSymbols = @{
            // Arts + subs → paintpalette.fill (iOS 14)
            @"1301": @"paintpalette.fill", @"1482": @"paintpalette.fill",
            @"1402": @"paintpalette.fill", @"1459": @"paintpalette.fill",
            @"1306": @"paintpalette.fill", @"1405": @"paintpalette.fill",
            // Comedy + subs → theatermasks (iOS 15.4)
            @"1303": @"theatermasks", @"1496": @"theatermasks",
            @"1495": @"theatermasks", @"1497": @"theatermasks",
            // Education + subs → graduationcap.fill (iOS 14)
            @"1304": @"graduationcap.fill", @"1501": @"graduationcap.fill",
            @"1499": @"graduationcap.fill", @"1498": @"graduationcap.fill",
            @"1500": @"graduationcap.fill",
            // Kids & Family + subs → figure.and.child.holdinghands (iOS 15)
            @"1305": @"figure.and.child.holdinghands",
            @"1519": @"figure.and.child.holdinghands",
            @"1520": @"figure.and.child.holdinghands",
            @"1521": @"figure.and.child.holdinghands",
            @"1522": @"figure.and.child.holdinghands",
            // TV & Film + subs → tv.fill (iOS 13)
            @"1309": @"tv.fill", @"1562": @"tv.fill", @"1564": @"tv.fill",
            @"1565": @"tv.fill", @"1563": @"tv.fill", @"1561": @"tv.fill",
            // Music + subs → music.note (iOS 13)
            @"1310": @"music.note", @"1523": @"music.note",
            @"1524": @"music.note", @"1525": @"music.note",
            // Religion & Spirituality + subs → sparkles (iOS 14)
            @"1314": @"sparkles", @"1438": @"sparkles", @"1439": @"sparkles",
            @"1463": @"sparkles", @"1440": @"sparkles", @"1441": @"sparkles",
            // Technology → desktopcomputer (iOS 13)
            @"1318": @"desktopcomputer",
            // Business + subs → briefcase.fill (iOS 13)
            @"1321": @"briefcase.fill", @"1410": @"briefcase.fill",
            @"1493": @"briefcase.fill", @"1412": @"briefcase.fill",
            @"1491": @"briefcase.fill", @"1492": @"briefcase.fill",
            @"1494": @"briefcase.fill",
            // Society & Culture + subs → person.2.fill (iOS 13)
            @"1324": @"person.2.fill", @"1543": @"person.2.fill",
            @"1302": @"person.2.fill", @"1443": @"person.2.fill",
            @"1320": @"person.2.fill", @"1544": @"person.2.fill",
            // Fiction + subs → books.vertical.fill (iOS 14)
            @"1483": @"books.vertical.fill", @"1486": @"books.vertical.fill",
            @"1484": @"books.vertical.fill", @"1485": @"books.vertical.fill",
            // History → clock.arrow.circlepath (iOS 14)
            @"1487": @"clock.arrow.circlepath",
            // True Crime → magnifyingglass (iOS 13)
            @"1488": @"magnifyingglass",
            // News + subs → newspaper.fill (iOS 14)
            @"1489": @"newspaper.fill", @"1526": @"newspaper.fill",
            @"1490": @"newspaper.fill", @"1531": @"newspaper.fill",
            @"1530": @"newspaper.fill", @"1527": @"newspaper.fill",
            @"1529": @"newspaper.fill", @"1528": @"newspaper.fill",
            // Leisure + subs → puzzlepiece.fill (iOS 14)
            @"1502": @"puzzlepiece.fill", @"1510": @"puzzlepiece.fill",
            @"1503": @"puzzlepiece.fill", @"1504": @"puzzlepiece.fill",
            @"1506": @"puzzlepiece.fill", @"1507": @"puzzlepiece.fill",
            // Government → building.columns.fill (iOS 14)
            @"1511": @"building.columns.fill",
            // Health & Fitness + subs → heart.fill (iOS 13)
            @"1512": @"heart.fill", @"1513": @"heart.fill",
            @"1514": @"heart.fill", @"1518": @"heart.fill",
            @"1517": @"heart.fill",
            // Science + subs → atom (iOS 15)
            @"1533": @"atom", @"1538": @"atom", @"1539": @"atom",
            @"1540": @"atom", @"1541": @"atom", @"1536": @"atom",
            // Sports + subs → figure.run (iOS 15)
            @"1545": @"figure.run", @"1547": @"figure.run",
            @"1548": @"figure.run", @"1546": @"figure.run",
            @"1550": @"figure.run", @"1560": @"figure.run",
        };
    });

    NSString *symbolName = genreSymbols[genreId];
    if (!symbolName) return nil;
    return [UIImage systemImageNamed:symbolName];
}

- (UIButton *)_createGenreButton
{
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];

    [button setTitle:[self _selectedGenreName] forState:UIControlStateNormal];

    // SF Symbol chevron as dropdown indicator
    UIImageSymbolConfiguration *symbolConfig = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightSemibold];
    UIImage *chevron = [[UIImage systemImageNamed:@"chevron.down"] imageWithConfiguration:symbolConfig];
    [button setImage:chevron forState:UIControlStateNormal];
    button.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft; // image trailing

    button.titleLabel.font = [UIFont systemFontOfSize:16.f weight:UIFontWeightMedium];
    [button setTitleColor:ICTintColor forState:UIControlStateNormal];
    button.tintColor = ICTintColor;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    button.translatesAutoresizingMaskIntoConstraints = NO;

    [button addTarget:self action:@selector(_showGenreDropdown:) forControlEvents:UIControlEventTouchUpInside];

    return button;
}

#pragma mark TableView Datasource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([self _isShowingCharts]) {
        return [self.chartsFilteredResults count];
    }
	return [self.searchResults count];
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    if (![self _isShowingCharts] || [self.chartsFilteredResults count] == 0) {
        return nil;
    }

    UIView *headerView = [[UIView alloc] init];
    headerView.backgroundColor = ICBackgroundColor;

    // Title label
    UILabel *label = [[UILabel alloc] init];
    label.text = @"Popular Podcasts".ls;
    label.textColor = ICTextColor;
    label.font = [UIFont systemFontOfSize:20.f weight:UIFontWeightBold];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [headerView addSubview:label];

    if (self.chartsGenres.count > 0) {
        // Genre dropdown button — right-aligned, same baseline as title
        UIButton *genreButton = [self _createGenreButton];
        [genreButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [genreButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [headerView addSubview:genreButton];

        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:10],
            [label.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],

            [genreButton.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-16],
            [genreButton.firstBaselineAnchor constraintEqualToAnchor:label.firstBaselineAnchor],
            [genreButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:8]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:10],
            [label.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor]
        ]];
    }

    return headerView;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self _isShowingCharts] && [self.chartsFilteredResults count] > 0) {
        return 44;
    }
    return 0;
}

// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _isShowingCharts]) {
        return [self _chartsCellForTableView:tableView atIndexPath:indexPath];
    }
    return [self _searchCellForTableView:tableView atIndexPath:indexPath];
}

- (UITableViewCell *)_searchCellForTableView:(UITableView *)tableView atIndexPath:(NSIndexPath *)indexPath
{
	static NSString *CellIdentifier = @"DirectoryFeedCell";

	DirectoryFeedTableViewCell *cell = (DirectoryFeedTableViewCell*)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
	if (cell == nil) {
		cell = [[DirectoryFeedTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
	}
    cell.backgroundColor = tableView.backgroundColor;

    if (indexPath.row >= [self.searchResults count]) {
        return cell;
    }

	NSDictionary* searchResult = [self.searchResults objectAtIndex:indexPath.row];
	cell.textLabel.text = [searchResult objectForKey:kiTunesStoreAlbum];
	cell.detailTextLabel.text = [searchResult objectForKey:kiTunesStoreArtist];

	cell.video = NO;
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

	NSString* imageURLString = [searchResult objectForKey:kiTunesStoreArtwork100];
    [self _loadImageForCell:cell imageURLString:imageURLString];

	return cell;
}

- (UITableViewCell *)_chartsCellForTableView:(UITableView *)tableView atIndexPath:(NSIndexPath *)indexPath
{
    static NSString *CellIdentifier = @"ChartsFeedCell";

    DirectoryFeedTableViewCell *cell = (DirectoryFeedTableViewCell*)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
    if (cell == nil) {
        cell = [[DirectoryFeedTableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellIdentifier];
    }
    cell.backgroundColor = tableView.backgroundColor;

    if (indexPath.row >= [self.chartsFilteredResults count]) {
        return cell;
    }

    NSDictionary* chartEntry = self.chartsFilteredResults[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), chartEntry[kAppleChartsName] ?: @""];
    cell.detailTextLabel.text = chartEntry[kAppleChartsArtistName];

    cell.video = NO;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    NSString* imageURLString = chartEntry[kAppleChartsArtworkUrl100];
    [self _loadImageForCell:cell imageURLString:imageURLString];

    return cell;
}

- (void)_loadImageForCell:(DirectoryFeedTableViewCell *)cell imageURLString:(NSString *)imageURLString
{
    if (!imageURLString) {
        cell.imageView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];
        return;
    }

    UIImage* image = [self.imageCache objectForKey:imageURLString];
    if (image) {
        cell.imageView.image = image;
    }
    else
    {
        cell.imageView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];

        NSURL* imageURL = [NSURL URLWithString:imageURLString];

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
            NSData* imageData = [[NSData alloc] initWithContentsOfURL:imageURL];
            UIImage* image = [[UIImage alloc] initWithData:imageData];

            if (image)
            {
                dispatch_async(dispatch_get_main_queue(), ^{
                    cell.imageView.image = image;
                    [self.imageCache setObject:image forKey:imageURLString];
                });
            }
        });
    }
}

#pragma mark TableView Delegate

- (void) _abortSelectingCell
{
	NSIndexPath* selectedIndexPath = [self.tableView indexPathForSelectedRow];
	if (selectedIndexPath) {
		UITableViewCell* cell = [self.tableView cellForRowAtIndexPath:selectedIndexPath];
		cell.accessoryView = nil;
		[self.tableView deselectRowAtIndexPath:selectedIndexPath animated:YES];
	}
	self.view.userInteractionEnabled = YES;
}


- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[self.searchBar resignFirstResponder];

    if ([self _isShowingCharts]) {
        [self _didSelectChartEntryAtIndexPath:indexPath];
        return;
    }

	NSDictionary* searchResult = [self.searchResults objectAtIndex:indexPath.row];
    NSURL* feedURL = searchResult[kiTunesStoreFeedURL];

    if (feedURL) {
        __weak DirectorySearchViewController* weakSelf = self;
        DirectoryFeedViewController* feedViewController = [DirectoryFeedViewController directoryFeedViewController];
        feedViewController.feedURL = feedURL;
        feedViewController.processAlternateFeeds = YES;
        feedViewController.shouldPopBackToList = YES;
        feedViewController.didLoadFeed = ^(BOOL success, NSError* error) {
            if (error) {
                [self presentError:error];
                [weakSelf.navigationController popViewControllerAnimated:YES];
            }
        };
        [feedViewController startLoading];

        [self.navigationController pushViewController:feedViewController animated:YES];
    }
    else
    {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (void)_didSelectChartEntryAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.row >= [self.chartsFilteredResults count]) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    NSDictionary *chartEntry = self.chartsFilteredResults[indexPath.row];
    NSString *podcastID = chartEntry[kAppleChartsID];

    if (!podcastID) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }

    // Show spinner on the cell
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    cell.accessoryView = spinner;

    // Cancel any previous lookup
    [self.chartsLookupTask cancel];

    // Look up the podcast via iTunes Lookup API to get feedUrl
    NSString *lookupURLString = [NSString stringWithFormat:@"https://itunes.apple.com/lookup?id=%@&entity=podcast", podcastID];
    NSURL *lookupURL = [NSURL URLWithString:lookupURLString];

    __weak typeof(self) weakSelf = self;
    self.chartsLookupTask = [[NSURLSession sharedSession] dataTaskWithURL:lookupURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf.chartsLookupTask = nil;

            // Restore cell accessory
            UITableViewCell *tappedCell = [strongSelf.tableView cellForRowAtIndexPath:indexPath];
            tappedCell.accessoryView = nil;
            tappedCell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

            if (error) {
                [strongSelf.tableView deselectRowAtIndexPath:indexPath animated:YES];
                return;
            }

            // Parse the lookup response
            NSURL *feedURL = [strongSelf _feedURLFromLookupData:data];

            if (feedURL) {
                DirectoryFeedViewController *feedViewController = [DirectoryFeedViewController directoryFeedViewController];
                feedViewController.feedURL = feedURL;
                feedViewController.processAlternateFeeds = YES;
                feedViewController.shouldPopBackToList = YES;
                feedViewController.didLoadFeed = ^(BOOL success, NSError *loadError) {
                    if (loadError) {
                        [strongSelf presentError:loadError];
                        [strongSelf.navigationController popViewControllerAnimated:YES];
                    }
                };
                [feedViewController startLoading];
                [strongSelf.navigationController pushViewController:feedViewController animated:YES];
            } else {
                [strongSelf.tableView deselectRowAtIndexPath:indexPath animated:YES];
            }
        });
    }];
    [self.chartsLookupTask resume];
}

- (NSURL *)_feedURLFromLookupData:(NSData *)data
{
    if (!data) return nil;

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;

    NSArray *results = json[@"results"];
    if (![results isKindOfClass:[NSArray class]] || results.count == 0) return nil;

    NSDictionary *result = results[0];
    if (![result isKindOfClass:[NSDictionary class]]) return nil;

    NSString *feedURLString = result[@"feedUrl"];
    if (![feedURLString isKindOfClass:[NSString class]] || feedURLString.length == 0) return nil;

    return [NSURL URLWithString:feedURLString];
}

#pragma mark -
#pragma mark ScrollView Delegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
	[self.searchBar resignFirstResponder];
}

#pragma mark UISearchBar Delegate

- (void) searchTimer:(NSTimer*)timer
{
	self.searchTimer = nil;
	NSString* searchText = [timer userInfo];

    if ([searchText rangeOfString:@"://"].location != NSNotFound) {
        return;
    }

    [App retainNetworkActivity];

	self.store = [[STITunesStore alloc] init];
	self.store.media = @"podcast";
	self.store.entity = @"podcast";

	NSArray* attributeTerms = [NSArray arrayWithObjects:@"titleTerm", @"artistTerm", @"descriptionTerm", nil];
	self.store.attribute = [attributeTerms objectAtIndex:self.searchBar.selectedScopeButtonIndex];

	[self.store startStoreSearchForSearchString:searchText delegate:self];

	[USER_DEFAULTS setObject:searchText forKey:kUIPersistenceDirectorySearchSearchString];
	[USER_DEFAULTS setInteger:self.searchBar.selectedScopeButtonIndex forKey:kUIPersistenceDirectorySearchSelectedScopeIndex];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
	[self.searchTimer invalidate];
	self.searchTimer = nil;

	if (self.store) {
		[self.store cancelStoreSearch];
		[App releaseNetworkActivity];
	}

	if ([searchText length] >= 3)
	{
		self.searchTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(searchTimer:) userInfo:searchText repeats:NO];
	}
    else if ([searchText length] == 0)
    {
        // Cleared search -> show charts again
        self.searchResults = nil;
        [self.tableView reloadData];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
	[self.searchBar resignFirstResponder];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
	self.searchTerm = self.searchBar.text;
	[self.searchBar resignFirstResponder];

    if ([self.searchTerm rangeOfString:@"://"].location != NSNotFound)
    {
        NSURL* feedURL = [NSURL URLWithString:self.searchTerm];

        NSString* urlString = [[feedURL absoluteString] substringFromIndex:[[feedURL scheme] length]];
        if ([urlString hasPrefix:@":http://"] || [urlString hasPrefix:@":https://"]) {
            NSString* newURLString = [urlString substringFromIndex:1];
            feedURL = [NSURL URLWithString:newURLString];
        }

        if (![[feedURL scheme] caseInsensitiveEquals:@"http"] && ![[feedURL scheme] caseInsensitiveEquals:@"https"]) {
            NSString* scheme = [feedURL scheme];
            NSString* urlString = [feedURL absoluteString];
            urlString = [urlString stringByReplacingCharactersInRange:NSMakeRange(0, [scheme length]) withString:@"http"];
            feedURL = [NSURL URLWithString:urlString];
        }

        if (feedURL)
        {
            __weak DirectorySearchViewController* weakSelf = self;

            DirectoryFeedViewController* feedViewController = [DirectoryFeedViewController directoryFeedViewController];

            if ([[[feedURL host] lowercaseString] isEqualToString:@"itunes.apple.com"]) {
                feedViewController.itunesURL = feedURL;
            } else {
                feedViewController.feedURL = feedURL;
            }
            feedViewController.didLoadFeed = ^(BOOL success, NSError* error) {
                if (error) {
                    [self presentError:error];
                    [weakSelf.navigationController popViewControllerAnimated:YES];
                }
            };
            [feedViewController startLoading];
            [self.navigationController pushViewController:feedViewController animated:YES];
        }

        return;
    }
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar
{
    self.searchBarActive = YES;
}

- (void)searchBarTextDidEndEditing:(UISearchBar *)searchBar
{
    self.searchBarActive = NO;
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope
{
	[self.searchTimer invalidate];
	self.searchTimer = nil;

	self.searchTimer = [NSTimer scheduledTimerWithTimeInterval:0 target:self selector:@selector(searchTimer:) userInfo:self.searchBar.text repeats:NO];
}

- (void) setSearchBarActive:(BOOL)searchBarActive
{
    if (searchBarActive != _searchBarActive) {
        _searchBarActive = searchBarActive;
    }
}


#pragma mark iTunes Store Delegate

- (void) itunesStore:(STITunesStore*)store didFindSearchResults:(NSArray*)theSearchResults
{
	DebugLog(@"itunesStore end %lu", (unsigned long)[theSearchResults count]);
	self.searchResults = theSearchResults;
	self.store = nil;

	[self.tableView reloadData];

	[App releaseNetworkActivity];
}

- (void) itunesStore:(STITunesStore*)store didEndWithError:(NSError*)error
{
	ErrLog(@"iTunes Store fail: %@", [error description]);
	self.store = nil;
	self.searchResults = nil;

	[self.tableView reloadData];

	[App releaseNetworkActivity];
}



- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate
{
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
}
@end
