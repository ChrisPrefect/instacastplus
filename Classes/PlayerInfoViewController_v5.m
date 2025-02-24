//
//  PlayInfoViewController2.m
//  Instacast
//
//  Created by Martin Hering on 02.08.14.
//
//

#import <objc/runtime.h>

#import "PlayerInfoViewController_v5.h"
#import "ChaptersTableViewCell.h"
#import "PlayerInfoHeaderFooterView.h"
#import "PlayerBookmarksTableViewCell.h"
#import "UIViewController+ShowNotes.h"
#import "EpisodesTableViewCell.h"
#import "PlayerVideoViewController.h"
#import "PlayerView.h"
#import "PlaybackViewController.h"
#import "ChapterImageCell.h"
#import "UIImage+Utils.h"
#import "ICMetadata.h"
#import "InstacastAppDelegate.h"
#import <MediaPlayer/MediaPlayer.h>

static NSString* kChapterCell = @"ChapterCell";
static NSString* kBookmarkCell = @"BookmarkCell";
static NSString* kUpNextCell = @"UpNextCell";
static NSString* kHeaderView = @"HeaderView";

enum {
    kChaptersSection = 0,
    kBookmarksSection,
    kUpNextSection,
    kNumberOfSections
};



@interface PlayerInfoViewController_v5 () <UICollectionViewDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIScrollViewDelegate>
@property (nonatomic, strong, readwrite) UIImageView* imageView;

@property (nonatomic) NSTimeInterval duration;
@property (nonatomic, strong) NSArray* chapters;
@property (nonatomic) NSInteger	currentChapterIndex;
@property (nonatomic, strong) NSArray* bookmarks;
@end


@implementation PlayerInfoViewController_v5 {
    BOOL _observing;
    CGPoint _oldContentOffset;
    CGPoint _oldScrollVelocity;
    BOOL _dismissEnded;
    CGFloat _startY;
    BOOL _didWillAppear;
}

+ (instancetype) viewController {
    return [[self alloc] initWithStyle:UITableViewStylePlain];
}

- (void) dealloc
{
    [self _setObserving:NO];
}

- (void) _setObserving:(BOOL)observing
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    
    if (observing && !_observing)
    {
        __weak PlayerInfoViewController_v5* weakSelf = self;
        
        [pman addTaskObserver:self forKeyPath:@"playingEpisode.duration" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            weakSelf.duration = pman.playingEpisode.duration;
        }];
        
        [pman addTaskObserver:self forKeyPath:@"playingEpisode.chapters" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            weakSelf.chapters = [pman.playingEpisode sortedChapters];
            weakSelf.duration = pman.duration;
        }];
        
        [pman addTaskObserver:self forKeyPath:@"time" task:^(id obj, NSDictionary *change) {
            [weakSelf _updateVisibleCells];
        }];
        
        [pman addTaskObserver:self forKeyPath:@"currentChapter" task:^(id obj, NSDictionary *change) {
            PlaybackManager* pman = [PlaybackManager playbackManager];
            weakSelf.currentChapterIndex = pman.currentChapter;
        }];
        
        [nc addObserver:self selector:@selector(databaseManagerDidAddBookmarkNotification:) name:DatabaseManagerDidAddBookmarkNotification object:nil];
        
        _observing = YES;
    }
    else if (!observing && _observing)
    {
        [pman removeTaskObserver:self forKeyPath:@"playingEpisode.duration"];
        [pman removeTaskObserver:self forKeyPath:@"playingEpisode.chapters"];
        [pman removeTaskObserver:self forKeyPath:@"time"];
        [pman removeTaskObserver:self forKeyPath:@"currentChapter"];
        
        [nc removeObserver:self];
        
        _observing = NO;
    }
}

- (void) databaseManagerDidAddBookmarkNotification:(NSNotification*)notification
{
    [self reloadBookmarks];
    [self.tableView reloadData];
}

- (void) viewDidLoad
{
    [super viewDidLoad];
    
    self.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    self.bottomScrollInset = self.navigationController.toolbarHidden?0:44;
    
    self.tableView.separatorInset = UIEdgeInsetsZero;
    self.tableView.allowsSelectionDuringEditing = YES;
    if (@available(iOS 11.0, *)) {
        self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.tableView registerClass:[ChaptersTableViewCell class] forCellReuseIdentifier:kChapterCell];
    [self.tableView registerClass:[PlayerBookmarksTableViewCell class] forCellReuseIdentifier:kBookmarkCell];
    [self.tableView registerClass:[EpisodesTableViewCell class] forCellReuseIdentifier:kUpNextCell];
    [self.tableView registerClass:[PlayerInfoHeaderFooterView class] forHeaderFooterViewReuseIdentifier:kHeaderView];
    
    UIImage* placeholder = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) ? [UIImage imageNamed:@"Podcast Placeholder 580"] : [UIImage imageNamed:@"Podcast Placeholder 320"];
    self.imageView = [[UIImageView alloc] initWithImage:(self.image) ? self.image : placeholder];
    self.chapterView = [[UIView alloc] init];
    self.chapterView.backgroundColor = [UIColor clearColor];
    
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
    layout.itemSize = CGSizeMake(self.view.bounds.size.width, self.view.bounds.size.width);
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    [layout setMinimumInteritemSpacing:0.0f];
    [layout setMinimumLineSpacing:0.0f];
    self.chapterImagesCollection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    [self.chapterImagesCollection registerClass:[ChapterImageCell class] forCellWithReuseIdentifier: @"chapter_cell"];
    [self.chapterImagesCollection registerNib:[UINib nibWithNibName:@"ChapterImageCell" bundle:nil]  forCellWithReuseIdentifier:@"chapter_cell"];
    self.chapterImagesCollection.backgroundColor = [UIColor clearColor];
    self.chapterImagesCollection.showsHorizontalScrollIndicator = NO;
    self.chapterImagesCollection.showsVerticalScrollIndicator = NO;
    [self.chapterImagesCollection setPagingEnabled:YES];
    
    self.pageControl = [[UIPageControl alloc] initWithFrame:CGRectZero];
    self.pageControl.pageIndicatorTintColor = [UIColor lightGrayColor];
    self.pageControl.currentPageIndicatorTintColor = self.view.tintColor;
    self.pageControl.hidesForSinglePage = YES;
    [self.pageControl setHidden:true];
    [self.pageControl addTarget:self action:@selector(changePage:) forControlEvents:UIControlEventValueChanged];
    [self reloadData];
    
    [self _setObserving:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationDidChange) name:UIDeviceOrientationDidChangeNotification object:nil];
}


- (void) viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    _didWillAppear = YES;
    
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICTableSeparatorColor;
    
    [self layoutHeaderView];
    
    [self.tableView reloadData];
}

- (void) viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    _didWillAppear = NO;
}

- (void) viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    if (_didWillAppear) {
        if (!SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"11.0.0")) {
            
            // xxx: hard coded content Insets, because of rotation issues
            UIEdgeInsets edgeInsets = UIEdgeInsetsMake(20+44, 0, self.bottomScrollInset, 0);
            
            self.tableView.contentInset = edgeInsets;
            self.tableView.scrollIndicatorInsets = edgeInsets;
            if (CGPointEqualToPoint(self.tableView.contentOffset, CGPointZero)) {
                self.tableView.contentOffset = CGPointMake(0,-edgeInsets.top);
            }
        }
        else
        {
            UIEdgeInsets safeAreaInsets = UIEdgeInsetsMake(20+44, 0, 0, 0);
            if (@available(iOS 11.0, *)) {
                safeAreaInsets = self.view.safeAreaInsets;
            }
            
            UIEdgeInsets edgeInsets = UIEdgeInsetsMake(safeAreaInsets.top, 0, self.bottomScrollInset, 0);
            
            self.tableView.contentInset = edgeInsets;
            self.tableView.scrollIndicatorInsets = edgeInsets;
            self.tableView.contentOffset = CGPointMake(0, -safeAreaInsets.top);
        }
    }
}

- (void) layoutHeaderView
{
    CGRect b = self.view.bounds;
    self.rectCollection = self.view.bounds;
    
    if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
    {
        self.rectCollection = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetHeight(b));
    }
    else
    {
        self.rectCollection = CGRectMake(0, 0, CGRectGetHeight(b), CGRectGetWidth(b));
    }
    
    if (self.videoViewController)
    {
        UIView* playerView = self.videoViewController.view;
        CGSize videoSize = self.videoViewController.videoSize;
        
        CGFloat aspectRatio = videoSize.width / videoSize.height;
        CGFloat viewAspectRatio = CGRectGetWidth(b) / CGRectGetHeight(b);
        
        // xxx: landscape hack for iOS 8
        if (viewAspectRatio > 1) {
            playerView.frame = CGRectMake(0, 0, CGRectGetHeight(b), floorf(CGRectGetHeight(b)/aspectRatio));
        } else {
            playerView.frame = CGRectMake(0, 0, CGRectGetWidth(b), floorf(CGRectGetWidth(b)/aspectRatio));
        }
        
        self.tableView.tableHeaderView = playerView;
    } else {
        
        CGRect newFrameTemp = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetWidth(b));
        
        UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
        layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
        layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
        [layout setMinimumInteritemSpacing:0.0f];
        [layout setMinimumLineSpacing:0.0f];
        
        if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
        {
            newFrameTemp = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetWidth(b));
            layout.itemSize = CGSizeMake(self.view.bounds.size.width, self.view.bounds.size.width);
            self.pageControl.frame = CGRectMake(0, CGRectGetWidth(b) - 60, CGRectGetWidth(b), 40);
        }
        else
        {
            CGRect wb = [[self getKeyWindow] bounds];
            CGFloat statusbarHeight = CGRectGetHeight([self getStatusBarFrame]);
            CGFloat controllerHeight = (MAX(CGRectGetHeight(wb)-statusbarHeight-44-CGRectGetWidth(wb), 184) + 96);
            
            newFrameTemp = CGRectMake(0, 0, CGRectGetHeight(self.rectCollection), CGRectGetWidth(self.rectCollection) - controllerHeight);
            self.pageControl.frame = CGRectMake(0, CGRectGetHeight(self.rectCollection) - 60, CGRectGetWidth(self.rectCollection), 40);
            layout.itemSize = CGSizeMake(self.view.bounds.size.height, self.view.bounds.size.width - controllerHeight);
        }
        
        self.chapterImagesCollection.collectionViewLayout = layout;
        self.imageView.frame = newFrameTemp;
        self.chapterView.frame = newFrameTemp;
        self.chapterImagesCollection.frame = newFrameTemp;

        [self.chapterView addSubview:self.chapterImagesCollection];
        [self.chapterView addSubview:self.pageControl];
        self.chapterImagesCollection.delegate = self;
        self.chapterImagesCollection.dataSource = self;
        [self.chapterImagesCollection reloadData];
        self.pageControl.currentPageIndicatorTintColor = self.view.tintColor;
        [self updateCollectionsImage:0];
        
        //self.chapterImagesCollection.backgroundColor = [UIColor yellowColor];
        self.tableView.tableHeaderView = self.chapterView;//self.imageView;//
    }
}

- (void)orientationDidChange
{
    CGRect b = self.rectCollection;
    
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    [layout setMinimumInteritemSpacing:0.0f];
    [layout setMinimumLineSpacing:0.0f];
    
    CGRect newFrameTemp = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetWidth(b));
    
    if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
    {
        newFrameTemp = CGRectMake(0, 0, CGRectGetWidth(b), CGRectGetWidth(b));
        layout.itemSize = CGSizeMake(self.view.bounds.size.width, self.view.bounds.size.width);
        self.pageControl.frame = CGRectMake(0, CGRectGetWidth(b) - 60, CGRectGetWidth(b), 40);
    }
    else
    {
        CGRect wb = [[self getKeyWindow] bounds];
        CGFloat statusbarHeight = CGRectGetHeight([self getStatusBarFrame]);
        CGFloat controllerHeight = (MAX(CGRectGetHeight(wb)-statusbarHeight-44-CGRectGetWidth(wb), 184) + 96);
        
        newFrameTemp = CGRectMake(0, 0, CGRectGetHeight(b), CGRectGetWidth(b) - controllerHeight);
        self.pageControl.frame = CGRectMake(0, CGRectGetHeight(b) - 60, CGRectGetWidth(b), 40);
        layout.itemSize = CGSizeMake(self.view.bounds.size.height, self.view.bounds.size.width - controllerHeight);
    }
    
    self.chapterImagesCollection.collectionViewLayout = layout;
    self.imageView.frame = newFrameTemp;
    self.chapterView.frame = newFrameTemp;
    self.chapterImagesCollection.frame = newFrameTemp;
    [self.chapterImagesCollection reloadData];
}

-(UIInterfaceOrientation)getDeviceOrientation
{
    UIWindowScene *windowScene = (UIWindowScene *)[[[UIApplication sharedApplication] connectedScenes] anyObject];
    if ([windowScene isKindOfClass:[UIWindowScene class]]) {
        return  windowScene.interfaceOrientation;
    }
    return UIInterfaceOrientationPortrait;
}

-(UIWindow *)getKeyWindow {
    if (@available(iOS 13.0, *)) {
        // For iOS 13 and later, get the key window by iterating through windows
        for (UIWindow *window in [UIApplication sharedApplication].windows) {
            if (window.isKeyWindow) {
                return window;
            }
        }
    } else {
        // For earlier versions, use the deprecated keyWindow method
        return [UIApplication sharedApplication].keyWindow;
    }
    return nil; // In case no key window is found
}
- (CGRect)getStatusBarFrame {
    if (@available(iOS 13.0, *)) {
        // For iOS 13 and later, get the statusBarFrame using the window scene
        UIWindowScene *windowScene = (UIWindowScene *)[UIApplication.sharedApplication.connectedScenes anyObject];
        return windowScene.statusBarManager.statusBarFrame;
    } else {
        // For iOS 12 and earlier, use the deprecated statusBarFrame
        return [UIApplication sharedApplication].statusBarFrame;
    }
}

- (void) viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    _oldContentOffset = self.tableView.contentOffset;
}

- (void) reloadData
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    self.chapters = [pman.playingEpisode sortedChapters];
    self.currentChapterIndex = pman.currentChapter;
    self.duration = pman.playingEpisode.duration;
    
    [self reloadBookmarks];
}

- (void) reload
{
    [self reloadData];
    [self.tableView reloadData];
    
    PlaybackManager* pman = [PlaybackManager playbackManager];
    BOOL movingVideo = pman.movingVideo;
    
    PlayerView* playerView = pman.playerView;
    
    if (playerView && movingVideo)
    {
        playerView.transform = CGAffineTransformIdentity;
        
        PlayerVideoViewController* videoViewController = self.videoViewController;
        
        if (!videoViewController) {
            videoViewController = [PlayerVideoViewController viewController];
        }
        
        videoViewController.playerView = playerView;
        videoViewController.videoSize = pman.viewImageSize;
        
        if (!self.videoViewController) {
            self.videoViewController = videoViewController;
        }
    }
    else if (self.videoViewController)
    {
        self.videoViewController = nil;
    }
    [self updateCollectionsImage:0];
    [self.tableView scrollRectToVisible:CGRectMake(0, 0, 10, 10) animated:YES];
}

- (void) tintColorDidChange
{
    [self.tableView reloadData];
}

- (void) reloadBookmarks
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] init];
    fetchRequest.entity = [NSEntityDescription entityForName:@"Bookmark" inManagedObjectContext:DMANAGER.objectContext];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"episodeHash == %@", pman.playingEpisode.objectHash];
    fetchRequest.sortDescriptors = @[ [[NSSortDescriptor alloc] initWithKey:@"position" ascending:YES] ];
    
    self.bookmarks = [DMANAGER.objectContext executeFetchRequest:fetchRequest error:nil];
}


- (void) setChapters:(NSArray *)chapters
{
    if (_chapters != chapters) {
        _chapters = chapters;
        [self.tableView reloadData];
    }
}

- (void) setVideoViewController:(PlayerVideoViewController *)videoViewController
{
    if (_videoViewController != videoViewController)
    {
        PlayerVideoViewController* oldController = _videoViewController;
        
        _videoViewController = videoViewController;
        
        if (videoViewController) {
            [self addChildViewController:videoViewController];
            [self layoutHeaderView];
            [videoViewController didMoveToParentViewController:self];
        }
        else
        {
            [oldController willMoveToParentViewController:nil];
            [self layoutHeaderView];
            [oldController removeFromParentViewController];
        }
    }
}


#pragma mark -

- (void) setImage:(UIImage *)image {
    if (_image != image) {
        _image = image;
        self.imageView.image = image;
        [self updateCollectionsImage:0];
    }
}

#pragma mark -

- (void) _updateVisibleCells
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    for(NSIndexPath* indexPath in self.tableView.indexPathsForVisibleRows)
    {
        ChaptersTableViewCell* cell = (ChaptersTableViewCell*)[self.tableView cellForRowAtIndexPath:indexPath];
        if ([cell isKindOfClass:[ChaptersTableViewCell class]])
        {
            if (indexPath.row == pman.currentChapter) {
                cell.textLabel.textColor = self.view.tintColor;
                cell.numLabel.textColor = self.view.tintColor;
                cell.timeLabel.textColor = self.view.tintColor;
            }
            else
            {
                cell.textLabel.textColor = (indexPath.row <= pman.currentChapter) ? ICMutedTextColor : ICTextColor;
                cell.numLabel.textColor = ICMutedTextColor;
                cell.timeLabel.textColor = ICMutedTextColor;
            }
            
            BOOL hidden = (pman.currentChapter != indexPath.row);
            BOOL changed = (cell.progressView.hidden != hidden);
            cell.progressView.hidden = hidden;
            [cell.progressView setProgress:((pman.time - cell.objectValue.timecode) / cell.objectValue.duration) animated:(!hidden && !changed)];
        }
    }
}

- (BOOL) _hasChapters {
    return ([self.chapters count] > 0);
}

- (BOOL) _hasBookmarks {
    return ([self.bookmarks count] > 0);
}

- (BOOL) _hasUpNext {
    return ([[AudioSession sharedAudioSession].playlist count] > 0);
}

- (NSInteger) _chaptersSection {
    return 0;
}

- (NSInteger) _bookmarksSection {
    return 1;
}

- (NSInteger) _upNextSection {
    return 2;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return 3;
}

#pragma mark -

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    if ([self _hasChapters] && section == [self _chaptersSection]) {
        return [self.chapters count];
    }
    else if ([self _hasBookmarks] && section == [self _bookmarksSection]) {
        return [self.bookmarks count];
    }
    else if ([self _hasUpNext] && section == [self _upNextSection]) {
        return [[AudioSession sharedAudioSession].playlist count];
    }
    return 0;
}


// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    if ([self _hasChapters] && indexPath.section == [self _chaptersSection])
    {
        ChaptersTableViewCell* cell = (ChaptersTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kChapterCell forIndexPath:indexPath];
        cell.backgroundColor = self.tableView.backgroundColor;
        
        CDChapter* chapter = [self.chapters objectAtIndex:indexPath.row];
        cell.objectValue = chapter;
        
        
        if (indexPath.row == pman.currentChapter) {
            cell.textLabel.textColor = self.view.tintColor;
            cell.numLabel.textColor = self.view.tintColor;
            cell.timeLabel.textColor = self.view.tintColor;
        }
        else {
            cell.textLabel.textColor = (indexPath.row <= pman.currentChapter) ? ICMutedTextColor : ICTextColor;
            cell.numLabel.textColor = ICMutedTextColor;
            cell.timeLabel.textColor = ICMutedTextColor;
        }
        
        cell.progressView.hidden = (pman.currentChapter != indexPath.row);
        cell.progressView.progress = 0;
        cell.progressView.tintColor = self.view.tintColor;
        cell.progressView.progress = (pman.time - chapter.timecode) / chapter.duration;
        
        NSArray* actions = [cell.linkButton actionsForTarget:self forControlEvent:UIControlEventValueChanged];
        for(NSString* action in actions) {
            [cell.linkButton removeTarget:self action:NSSelectorFromString(action) forControlEvents:UIControlEventTouchUpInside];
        }
        
        [cell.linkButton setAssociatedObject:chapter forKey:@"__chapter"];
        [cell.linkButton addTarget:self action:@selector(handleChapterLinkButton:) forControlEvents:UIControlEventTouchUpInside];
        return cell;
    }
    else if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
    {
        PlayerBookmarksTableViewCell* cell = (PlayerBookmarksTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kBookmarkCell forIndexPath:indexPath];
        cell.backgroundColor = self.tableView.backgroundColor;
        
        CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
        
        cell.textLabel.text = bookmark.title;
        
        NSInteger time = bookmark.position;
        cell.timeLabel.text = [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(time/3600)%60, (long)(time/60%60), (long)time%60];
        
        return cell;
    }
    
    if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        EpisodesTableViewCell* cell = (EpisodesTableViewCell*)[tableView dequeueReusableCellWithIdentifier:kUpNextCell forIndexPath:indexPath];
        cell.backgroundColor = self.tableView.backgroundColor;
        
        CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
        cell.embedded = YES;
        cell.panRecognizer.enabled = NO;
        cell.objectValue = episode;
        
        return cell;
    }
    
    return nil;
}

- (void) handleChapterLinkButton:(UIButton*)sender
{
    CDChapter* chapter = [sender associatedObjectForKey:@"__chapter"];
    [self handleShowNotesURL:chapter.linkURL];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection]) {
        return YES;
    }
    
    if ([self _hasUpNext] && indexPath.section == [self _upNextSection]) {
        return YES;
    }
    
    return NO;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle == UITableViewCellEditingStyleDelete)
    {
        if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
        {
            CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
            
            NSMutableArray* newBookmarks = [self.bookmarks mutableCopy];
            [newBookmarks removeObject:bookmark];
            self.bookmarks = newBookmarks;
            
            [DMANAGER removeBookmark:bookmark];
            
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationRight];
        }
        
        else if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
        {
            CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
            
            [[AudioSession sharedAudioSession] eraseEpisodesFromUpNext:@[episode]];
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationRight];
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        return YES;
    }
    
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath
{
    [[AudioSession sharedAudioSession] reorderUpNextEpisodeFromIndex:fromIndexPath.row toIndex:toIndexPath.row];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self _hasChapters] && indexPath.section == [self _chaptersSection])
    {
        CDChapter* chapter = [self.chapters objectAtIndex:indexPath.row];
        return [ChaptersTableViewCell proposedHeightWithTitle:chapter.title tableBounds:self.tableView.bounds];
    }
    else if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
    {
        CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
        return [PlayerBookmarksTableViewCell proposedHeightWithTitle:bookmark.title tableBounds:self.tableView.bounds];
    }
    else if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
        return [EpisodesTableViewCell proposedHeightWithObjectValue:episode tableSize:self.tableView.bounds.size imageSize:CGSizeZero embedded:YES editing:self.editing];
    }
    return 0;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section
{
    PlayerInfoHeaderFooterView* headerView = [tableView dequeueReusableHeaderFooterViewWithIdentifier:kHeaderView];
    
    headerView.editButton.tintColor = self.view.tintColor;
    headerView.doneButton.tintColor = self.view.tintColor;
    
    NSArray* actions = [headerView.editButton actionsForTarget:self forControlEvent:UIControlEventValueChanged];
    for(NSString* action in actions) {
        [headerView.editButton removeTarget:self action:NSSelectorFromString(action) forControlEvents:UIControlEventTouchUpInside];
    }
    
    actions = [headerView.doneButton actionsForTarget:self forControlEvent:UIControlEventValueChanged];
    for(NSString* action in actions) {
        [headerView.doneButton removeTarget:self action:NSSelectorFromString(action) forControlEvents:UIControlEventTouchUpInside];
    }
    
    if ([self _hasChapters] && section == [self _chaptersSection])
    {
        headerView.textLabel.text = @"Chapters".ls;
        headerView.canEdit = NO;
    }
    else if ([self _hasBookmarks] && section == [self _bookmarksSection])
    {
        headerView.textLabel.text = @"Bookmarks".ls;
        headerView.canEdit = YES;
    }
    else if ([self _hasUpNext] && section == [self _upNextSection])
    {
        headerView.textLabel.text = @"Up Next".ls;
        headerView.canEdit = YES;
    }
    
    if (headerView.canEdit)
    {
        [headerView.editButton setAssociatedObject:headerView forKey:@"__headerView"];
        [headerView.editButton addTarget:self action:@selector(handleHeaderViewEditButton:) forControlEvents:UIControlEventTouchUpInside];
        
        [headerView.doneButton setAssociatedObject:headerView forKey:@"__headerView"];
        [headerView.doneButton addTarget:self action:@selector(handleHeaderViewDoneButton:) forControlEvents:UIControlEventTouchUpInside];
    }
    
    return headerView;
}

- (void) handleHeaderViewEditButton:(UIButton*)button
{
    PlayerInfoHeaderFooterView* headerView = [button associatedObjectForKey:@"__headerView"];
    [headerView setEditing:YES animated:YES];
    [self setEditing:YES animated:YES];
}

- (void) handleHeaderViewDoneButton:(UIButton*)button
{
    PlayerInfoHeaderFooterView* headerView = [button associatedObjectForKey:@"__headerView"];
    [headerView setEditing:NO animated:YES];
    [self setEditing:NO animated:YES];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section
{
    if ([self _hasChapters] && section == [self _chaptersSection]) {
        return 44;
    }
    else if ([self _hasBookmarks] && section == [self _bookmarksSection]) {
        return 44;
    }
    else if ([self _hasUpNext] && section == [self _upNextSection]) {
        return 44;
    }
    
    return 0;
}


- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    PlaybackManager* pman = [PlaybackManager playbackManager];
    
    if ([self _hasChapters] && indexPath.section == [self _chaptersSection])
    {
        CDChapter* chapter = [self.chapters objectAtIndex:indexPath.row];
        
        NSArray* playbackChapters = pman.chapters;
        ICMetadataChapter* playbackChapter = playbackChapters[chapter.index];
        [pman seekToChapter:playbackChapter];
        [pman play];
        
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
    else if ([self _hasBookmarks] && indexPath.section == [self _bookmarksSection])
    {
        CDBookmark* bookmark = [self.bookmarks objectAtIndex:indexPath.row];
        
        if (self.editing)
        {
            WEAK_SELF
            UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Edit Bookmark".ls
                                                                           message:bookmark.title
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            
            [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                textField.placeholder = @"Bookmark title".ls;
                textField.text = bookmark.title;
            }];
            
            [alert addAction:[UIAlertAction actionWithTitle:@"Save".ls
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction * action) {
                STRONG_SELF
                
                NSString* text = self.alertController.textFields.firstObject.text;
                
                [self perform:^(id sender) {
                    
                    bookmark.title = text;
                    [DMANAGER save];
                    
                    [self.tableView reloadRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:UITableViewRowAnimationFade];
                    
                } afterDelay:0.3];
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
        else
        {
            NSTimeInterval time = bookmark.position;
            [pman seekToTime:time];
            [pman play];
            
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
        }
    }
    
    else if ([self _hasUpNext] && indexPath.section == [self _upNextSection])
    {
        CDEpisode* episode = [AudioSession sharedAudioSession].playlist[indexPath.row];
        
        AudioSession* audioSession = [AudioSession sharedAudioSession];
        [audioSession playEpisode:episode];
    }
}

#pragma mark -

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"11.0.0")) {
        return;
    }
    
    CGFloat topOffset = scrollView.contentInset.top;
    CGFloat yOffset = scrollView.contentOffset.y + topOffset;
    UIPanGestureRecognizer* recognizer = scrollView.panGestureRecognizer;
    CGPoint translation = [recognizer translationInView:scrollView];
    CGPoint velocity = [recognizer velocityInView:scrollView];
    
    PlaybackViewController* navigationController = (PlaybackViewController*)self.navigationController;
    
    if (yOffset <= 0 && [recognizer state] == UIGestureRecognizerStateChanged)
    {
        if (!navigationController.interactive) {
            [navigationController beginInteractiveDismissing];
            scrollView.showsVerticalScrollIndicator = NO;
            _dismissEnded = NO;
            _startY = translation.y;
        }
        
        translation.y -= _startY;
        [navigationController.dismissalAnimator _driveTransitionWithTranslation:translation velocity:velocity recognizerState:recognizer.state];
        
        scrollView.transform = CGAffineTransformMakeTranslation(0, yOffset);
        _oldScrollVelocity = velocity;
    }
    else
    {
        if (navigationController.interactive) {
            [navigationController.dismissalAnimator _driveTransitionWithTranslation:translation velocity:_oldScrollVelocity recognizerState:UIGestureRecognizerStateEnded];
            
            scrollView.showsVerticalScrollIndicator = YES;
            _dismissEnded = YES;
            _startY = 0;
        }
        
        if (_dismissEnded)
        {
            if (yOffset < 0) {
                scrollView.transform = CGAffineTransformMakeTranslation(0, yOffset);
                scrollView.bounces = NO;
            }
            else {
                scrollView.transform = CGAffineTransformIdentity;
                scrollView.bounces = YES;
                _dismissEnded = NO;
            }
        }
    }
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView
{
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    if (self->chapterImagesArray.count <= 0)
    {
        return 1;
    }
    return self->chapterImagesArray.count;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    CGRect b = self.rectCollection;
    CGRect wb = [[self getKeyWindow] bounds];
    CGFloat statusbarHeight = CGRectGetHeight([self getStatusBarFrame]);
    CGFloat controllerHeight = (MAX(CGRectGetHeight(wb)-statusbarHeight-44-CGRectGetWidth(wb), 184) + 96);
    
    if (UIInterfaceOrientationIsPortrait([self getDeviceOrientation]))
    {
        return CGSizeMake(CGRectGetWidth(b), CGRectGetWidth(b));
    }
    else
    {
        return CGSizeMake(CGRectGetHeight(b), CGRectGetWidth(b) - controllerHeight);
    }
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    ChapterImageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"chapter_cell" forIndexPath:indexPath];
    cell.chapterImageView.contentMode = UIViewContentModeScaleAspectFit;
    if (self->chapterImagesArray.count <= 0)
    {
        CDEpisode* episode = [AudioSession sharedAudioSession].episode;
        CDFeed* feed = episode.feed;
        NSURL* imageURL = (episode.imageURL) ? episode.imageURL : feed.imageURL;
        UIImage* cachedImage = [[ImageCacheManager sharedImageCacheManager] localImageForImageURL:imageURL size:320 grayscale:NO];
        
        if (cachedImage) {
            cell.chapterImageView.image = cachedImage;
            UIColor *averageColor = [self averageColorFromImage:cachedImage];
            cell.contentView.backgroundColor = averageColor;
        }
        else {
            cell.chapterImageView.image = ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) ? [UIImage imageNamed:@"Podcast Placeholder 580"] : [UIImage imageNamed:@"Podcast Placeholder 320"];
        }
    }
    else
    {
        if ([self->chapterImagesArray objectAtIndex:indexPath.item] != nil)
        {
            ICMetadataImage* artwork = self->chapterImagesArray[indexPath.item];
            [artwork loadPlatformImageScaleToWidth:CGRectGetWidth(self.view.bounds)*[ImageCacheManager scalingFactor] completion:^(id platformImage) {
                cell.chapterImageView.image = platformImage;
                UIColor *averageColor = [self averageColorFromImage:platformImage];
                cell.contentView.backgroundColor = averageColor;
            }];
        }
    }
    return cell;
}

- (UIColor *)averageColorFromImage:(UIImage *)image {
    // Resize the image to a 1x1 pixel to get the average color
    CGSize size = CGSizeMake(1, 1);
    UIGraphicsBeginImageContext(size);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    // Get the pixel data
    CGImageRef cgImage = resizedImage.CGImage;
    unsigned char pixel[4] = {0};
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), cgImage);
    CGContextRelease(context);
    
    // Extract color components
    CGFloat red = pixel[0] / 255.0;
    CGFloat green = pixel[1] / 255.0;
    CGFloat blue = pixel[2] / 255.0;
    
    return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
}


-(void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView
{
    CGFloat pageWidth = self.chapterImagesCollection.frame.size.width;
    self.pageControl.currentPage = self.chapterImagesCollection.contentOffset.x / pageWidth;
    [self.pageControl setHidden:true];//false
    /*dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        //[self.pageControl setHidden:true];
    });*/
    [currentImageTimer invalidate];
    currentImageTimer = nil;
    currentImageTimer = [NSTimer scheduledTimerWithTimeInterval: 10 target: self selector: @selector(afterTimerSetCurrentImg:) userInfo: nil repeats: NO];
}

-(void)afterTimerSetCurrentImg:(NSTimer *)timer {
    PlaybackManager* pman = [PlaybackManager playbackManager];
    [self changeChapterImageIndex:pman.currentArtwork];
    [currentImageTimer invalidate];
    currentImageTimer = nil;
}

- (void)changeChapterImageIndex:(NSUInteger)indexNumber
{
    if (self->chapterImagesArray.count <= 0)
    {
        PlaybackManager* pman = [PlaybackManager playbackManager];
        if (!pman.movingVideo && [pman.artworks count] > 0 && pman.currentArtwork >= 0)
        {
            self->chapterImagesArray = pman.artworks;
            self.pageControl.numberOfPages = [pman.artworks count];
        }
    }
    [self.chapterImagesCollection reloadData];
    self.pageControl.currentPageIndicatorTintColor = self.view.tintColor;
    self.pageControl.currentPage = indexNumber;
    [self.pageControl setHidden:true];
    if (self->chapterImagesArray.count > indexNumber)
    {
        if (CGRectGetWidth(self.chapterImagesCollection.bounds) != 0)
        {
            [self.chapterImagesCollection scrollToItemAtIndexPath:[NSIndexPath indexPathForRow:indexNumber inSection:0] atScrollPosition:UICollectionViewScrollPositionCenteredHorizontally animated:false];
        }
    }
}

- (void)updateCollectionsImage:(NSUInteger)indexNumber {
    PlaybackManager* pman = [PlaybackManager playbackManager];
    if (!pman.movingVideo && [pman.artworks count] > 0 && pman.currentArtwork >= 0)
    {
        self->chapterImagesArray = pman.artworks;
        self.pageControl.numberOfPages = [pman.artworks count];
        self.pageControl.currentPage = indexNumber;
        [self.chapterImagesCollection reloadData];
        self.pageControl.currentPageIndicatorTintColor = self.view.tintColor;
        
    }
    [self.chapterImagesCollection reloadData];
    self.pageControl.currentPage = indexNumber;
    [self.pageControl setHidden:true];
    self.pageControl.currentPageIndicatorTintColor = self.view.tintColor;
    
}

-(IBAction)changePage:(id)sender {
    PlaybackManager* pman = [PlaybackManager playbackManager];
    [self changeChapterImageIndex:pman.currentArtwork];
}

- (void)updateCollectionsImage:(NSArray *)images atIndex:(NSUInteger)indexNumber {
}

@end

