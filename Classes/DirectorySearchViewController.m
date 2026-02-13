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

- (void)_buildGenreList
{
    // Count podcasts per genre
    NSMutableDictionary *genreCounts = [NSMutableDictionary dictionary]; // genreId -> count
    NSMutableDictionary *genreNames = [NSMutableDictionary dictionary]; // genreId -> name

    for (NSDictionary *entry in self.chartsAllResults) {
        NSArray *genreIDs = entry[kAppleChartsGenreIDs];
        NSString *genresString = entry[kAppleChartsGenres];
        if (![genreIDs isKindOfClass:[NSArray class]]) continue;

        // Parse genre names from the comma-separated string
        NSArray *names = [genresString componentsSeparatedByString:@", "];

        for (NSUInteger i = 0; i < genreIDs.count; i++) {
            NSString *genreId = genreIDs[i];
            NSNumber *count = genreCounts[genreId] ?: @0;
            genreCounts[genreId] = @(count.integerValue + 1);

            if (i < names.count && !genreNames[genreId]) {
                genreNames[genreId] = names[i];
            }
        }
    }

    // Build sorted genre list, only genres with >= kChartsGenreMinCount
    NSMutableArray *genres = [NSMutableArray array];
    for (NSString *genreId in genreCounts) {
        NSInteger count = [genreCounts[genreId] integerValue];
        if (count >= kChartsGenreMinCount) {
            [genres addObject:@{
                @"genreId": genreId,
                @"name": genreNames[genreId] ?: genreId,
                @"count": @(count)
            }];
        }
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
        NSMutableArray *filtered = [NSMutableArray array];
        for (NSDictionary *entry in source) {
            NSArray *genreIDs = entry[kAppleChartsGenreIDs];
            if ([genreIDs containsObject:self.selectedGenreId]) {
                [filtered addObject:entry];
                if (filtered.count >= kChartsDisplayLimit) break;
            }
        }
        self.chartsFilteredResults = [filtered copy];
    } else {
        // "Alle" — show first 50
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
        return @"All".ls;
    }
    for (NSDictionary *genre in self.chartsGenres) {
        if ([genre[@"genreId"] isEqualToString:self.selectedGenreId]) {
            return genre[@"name"];
        }
    }
    return @"All".ls;
}

#pragma mark - Genre Menu

- (void)_showGenreMenu:(UIButton *)sender
{
    if (@available(iOS 14.0, *)) {
        // Menu is already attached via UIButton.menu + showsMenuAsPrimaryAction
        return;
    }

    // iOS 13 fallback: UIAlertController
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Genre".ls
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    // "Alle" option
    NSString *allTitle = self.selectedGenreId == nil
        ? [NSString stringWithFormat:@"\u2713 %@", @"All".ls]
        : @"All".ls;
    [alert addAction:[UIAlertAction actionWithTitle:allTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        self.selectedGenreId = nil;
        [self _applyGenreFilter];
        [self.tableView reloadData];
    }]];

    for (NSDictionary *genre in self.chartsGenres) {
        NSString *genreId = genre[@"genreId"];
        NSString *name = genre[@"name"];
        NSString *title = [self.selectedGenreId isEqualToString:genreId]
            ? [NSString stringWithFormat:@"\u2713 %@", name]
            : name;

        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.selectedGenreId = genreId;
            [self _applyGenreFilter];
            [self.tableView reloadData];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls style:UIAlertActionStyleCancel handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = sender;
        alert.popoverPresentationController.sourceRect = sender.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (UIButton *)_createGenreButton
{
    UIButton *button;

    NSString *title = [NSString stringWithFormat:@"%@  \u25BE", [self _selectedGenreName]];

    if (@available(iOS 14.0, *)) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.showsMenuAsPrimaryAction = YES;
        button.menu = [self _buildGenreUIMenu];
    } else {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button addTarget:self action:@selector(_showGenreMenu:) forControlEvents:UIControlEventTouchUpInside];
    }

    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.f weight:UIFontWeightMedium];
    [button setTitleColor:ICTintColor forState:UIControlStateNormal];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    button.translatesAutoresizingMaskIntoConstraints = NO;

    return button;
}

- (UIMenu *)_buildGenreUIMenu API_AVAILABLE(ios(14.0))
{
    NSMutableArray *actions = [NSMutableArray array];

    // "Alle" option
    UIAction *allAction = [UIAction actionWithTitle:@"All".ls
                                              image:nil
                                         identifier:nil
                                            handler:^(UIAction *action) {
        self.selectedGenreId = nil;
        [self _applyGenreFilter];
        [self.tableView reloadData];
    }];
    if (!self.selectedGenreId) {
        allAction.state = UIMenuElementStateOn;
    }
    [actions addObject:allAction];

    for (NSDictionary *genre in self.chartsGenres) {
        NSString *genreId = genre[@"genreId"];
        NSString *name = genre[@"name"];

        UIAction *action = [UIAction actionWithTitle:name
                                               image:nil
                                          identifier:nil
                                             handler:^(UIAction *action) {
            self.selectedGenreId = genreId;
            [self _applyGenreFilter];
            [self.tableView reloadData];
        }];
        if ([self.selectedGenreId isEqualToString:genreId]) {
            action.state = UIMenuElementStateOn;
        }
        [actions addObject:action];
    }

    return [UIMenu menuWithTitle:@"" children:actions];
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

            [genreButton.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-10],
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
