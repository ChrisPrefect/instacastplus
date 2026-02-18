//
//  ICBackupImportProgressView.m
//  Instacast
//

#import "ICBackupImportProgressView.h"

// Metadata categories in display order (Phase C)
static ICBackupImportCategory const kMetadataCategories[] = {
    ICBackupImportEpisodeStatus,
    ICBackupImportFeedSettings,
    ICBackupImportBookmarks,
    ICBackupImportUpNext,
    ICBackupImportNowPlaying,
    ICBackupImportPlaylists,
    ICBackupImportSettings,
    ICBackupImportSortOrder,
    ICBackupImportDownloads,
};
static const NSInteger kMetadataCategoriesCount = 9;

#pragma mark - Feed Row View

typedef NS_ENUM(NSInteger, ICFeedRowState) {
    ICFeedRowStatePending,
    ICFeedRowStateActive,
    ICFeedRowStateCompleted,
    ICFeedRowStateError,
    ICFeedRowStateSkipped,
};

@interface _ICFeedRowView : UIView
@property (nonatomic, strong) UIImageView *statusImageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIProgressView *progressBar;
@property (nonatomic) ICFeedRowState state;
@end

@implementation _ICFeedRowView

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _state = ICFeedRowStatePending;

        _statusImageView = [[UIImageView alloc] init];
        _statusImageView.contentMode = UIViewContentModeScaleAspectFit;
        _statusImageView.tintColor = [UIColor tertiaryLabelColor];
        UIImage *circle = [UIImage systemImageNamed:@"circle"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightRegular]];
        _statusImageView.image = circle;
        _statusImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_statusImageView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        _spinner.hidesWhenStopped = YES;
        [self addSubview:_spinner];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:14];
        _titleLabel.textColor = [UIColor tertiaryLabelColor];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        _detailLabel.textColor = [UIColor tertiaryLabelColor];
        _detailLabel.textAlignment = NSTextAlignmentRight;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_detailLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_detailLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self addSubview:_detailLabel];

        _progressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _progressBar.translatesAutoresizingMaskIntoConstraints = NO;
        _progressBar.progress = 0;
        _progressBar.hidden = YES;
        _progressBar.trackTintColor = [UIColor tertiarySystemFillColor];
        [self addSubview:_progressBar];

        [NSLayoutConstraint activateConstraints:@[
            [_statusImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_statusImageView.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
            [_statusImageView.widthAnchor constraintEqualToConstant:20],
            [_statusImageView.heightAnchor constraintEqualToConstant:20],

            [_spinner.centerXAnchor constraintEqualToAnchor:_statusImageView.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:_statusImageView.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_statusImageView.trailingAnchor constant:8],
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],

            [_detailLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:6],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_detailLabel.centerYAnchor constraintEqualToAnchor:_titleLabel.centerYAnchor],

            [_progressBar.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_progressBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_progressBar.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],

            [self.bottomAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.bottomAnchor constant:4],
            [self.bottomAnchor constraintGreaterThanOrEqualToAnchor:_progressBar.bottomAnchor constant:4],
        ]];
    }
    return self;
}

- (void)setActiveState {
    _state = ICFeedRowStateActive;
    _statusImageView.hidden = YES;
    [_spinner startAnimating];
    _titleLabel.textColor = [UIColor labelColor];
    _detailLabel.textColor = [UIColor secondaryLabelColor];
    _progressBar.hidden = NO;
    _progressBar.progress = 0;
}

- (void)setProgress:(float)progress detail:(NSString *)detail {
    _progressBar.progress = progress;
    _detailLabel.text = detail;
}

- (void)setCompletedWithEpisodeCount:(NSInteger)count {
    _state = ICFeedRowStateCompleted;
    [_spinner stopAnimating];
    _statusImageView.hidden = NO;
    _statusImageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightRegular]];
    _statusImageView.tintColor = [UIColor systemGreenColor];
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.textColor = [UIColor tertiaryLabelColor];
    _detailLabel.text = [NSString stringWithFormat:@"%ld Ep.", (long)count];
    _progressBar.hidden = YES;
}

- (void)setErrorWithMessage:(NSString *)message {
    _state = ICFeedRowStateError;
    [_spinner stopAnimating];
    _statusImageView.hidden = NO;
    _statusImageView.image = [UIImage systemImageNamed:@"xmark.circle.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightRegular]];
    _statusImageView.tintColor = [UIColor systemRedColor];
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.textColor = [UIColor systemRedColor];
    _detailLabel.text = message;
    _progressBar.hidden = YES;
}

- (void)setSkippedState {
    _state = ICFeedRowStateSkipped;
    [_spinner stopAnimating];
    _statusImageView.hidden = NO;
    _statusImageView.image = [UIImage systemImageNamed:@"forward.circle.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightRegular]];
    _statusImageView.tintColor = [UIColor systemOrangeColor];
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.textColor = [UIColor tertiaryLabelColor];
    _detailLabel.text = @"Skipped".ls;
    _progressBar.hidden = YES;
}

@end

#pragma mark - Metadata Row View

@interface _ICMetadataRowView : UIView
@property (nonatomic, strong) UIImageView *statusImageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@end

@implementation _ICMetadataRowView

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _statusImageView = [[UIImageView alloc] init];
        _statusImageView.contentMode = UIViewContentModeScaleAspectFit;
        _statusImageView.tintColor = [UIColor tertiaryLabelColor];
        UIImage *circle = [UIImage systemImageNamed:@"circle"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular]];
        _statusImageView.image = circle;
        _statusImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_statusImageView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        _spinner.hidesWhenStopped = YES;
        [self addSubview:_spinner];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:13];
        _titleLabel.textColor = [UIColor tertiaryLabelColor];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = [UIFont systemFontOfSize:11];
        _detailLabel.textColor = [UIColor tertiaryLabelColor];
        _detailLabel.textAlignment = NSTextAlignmentRight;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_detailLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_detailLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self addSubview:_detailLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_statusImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_statusImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_statusImageView.widthAnchor constraintEqualToConstant:16],
            [_statusImageView.heightAnchor constraintEqualToConstant:16],

            [_spinner.centerXAnchor constraintEqualToAnchor:_statusImageView.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:_statusImageView.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_statusImageView.trailingAnchor constant:6],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [_detailLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:4],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_detailLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [self.heightAnchor constraintEqualToConstant:24],
        ]];
    }
    return self;
}

- (void)setActive {
    _statusImageView.hidden = YES;
    [_spinner startAnimating];
    _titleLabel.textColor = [UIColor labelColor];
}

- (void)setCompletedWithDetail:(NSString *)detail {
    [_spinner stopAnimating];
    _statusImageView.hidden = NO;
    _statusImageView.image = [UIImage systemImageNamed:@"checkmark.circle.fill"
                                      withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightRegular]];
    _statusImageView.tintColor = [UIColor systemGreenColor];
    _titleLabel.textColor = [UIColor secondaryLabelColor];
    _detailLabel.text = detail;
    _detailLabel.textColor = [UIColor tertiaryLabelColor];
}

@end

#pragma mark - Progress View

@interface ICBackupImportProgressView ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *timerLabel;
@property (nonatomic, strong) UIProgressView *totalProgressBar;
@property (nonatomic, strong) UILabel *totalProgressLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIScrollView *feedScrollView;
@property (nonatomic, strong) UIStackView *feedStack;
@property (nonatomic, strong) UIStackView *metadataStack;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIWindow *parentWindow;

@property (nonatomic, strong) NSMutableArray<_ICFeedRowView *> *feedRows;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, _ICMetadataRowView *> *metadataRows;

@property (nonatomic, strong) NSTimer *timerUpdate;
@property (nonatomic) NSTimeInterval startTime;
@property (nonatomic) NSInteger completedFeedCount;
@property (nonatomic) NSInteger totalFeedCount;
@end

@implementation ICBackupImportProgressView

- (void)dealloc
{
    [self.timerUpdate invalidate];
}

- (instancetype)initWithFeedTitles:(NSArray<NSString *> *)feedTitles
                        categories:(ICBackupImportCategory)categories
{
    self = [super initWithFrame:[UIScreen mainScreen].bounds];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        self.feedRows = [NSMutableArray array];
        self.metadataRows = [NSMutableDictionary dictionary];
        self.totalFeedCount = feedTitles.count;
        self.completedFeedCount = 0;

        BOOL isDark = [ICAppearanceManager sharedManager].nightSettingMode;

        // Card
        _cardView = [[UIView alloc] init];
        _cardView.backgroundColor = isDark ? [UIColor colorWithWhite:0.15 alpha:0.95] : [UIColor colorWithWhite:1.0 alpha:0.95];
        _cardView.layer.cornerRadius = 16;
        _cardView.layer.cornerCurve = kCACornerCurveContinuous;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.25;
        _cardView.layer.shadowRadius = 24;
        _cardView.layer.shadowOffset = CGSizeMake(0, 6);
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        _cardView.clipsToBounds = NO;
        [self addSubview:_cardView];

        // Title
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = @"Importing Data…".ls;
        _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _titleLabel.textColor = isDark ? [UIColor whiteColor] : [UIColor labelColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_titleLabel];

        // Timer
        _timerLabel = [[UILabel alloc] init];
        _timerLabel.text = @"";
        _timerLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
        _timerLabel.textColor = [UIColor secondaryLabelColor];
        _timerLabel.textAlignment = NSTextAlignmentCenter;
        _timerLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_timerLabel];

        // Total progress bar
        _totalProgressBar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
        _totalProgressBar.translatesAutoresizingMaskIntoConstraints = NO;
        _totalProgressBar.progress = 0;
        _totalProgressBar.trackTintColor = [UIColor tertiarySystemFillColor];
        [_cardView addSubview:_totalProgressBar];

        _totalProgressLabel = [[UILabel alloc] init];
        _totalProgressLabel.text = @"0%";
        _totalProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
        _totalProgressLabel.textColor = [UIColor secondaryLabelColor];
        _totalProgressLabel.textAlignment = NSTextAlignmentRight;
        _totalProgressLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_totalProgressLabel];

        // Status label
        _statusLabel = [[UILabel alloc] init];
        _statusLabel.font = [UIFont systemFontOfSize:13];
        _statusLabel.textColor = [UIColor secondaryLabelColor];
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_statusLabel];

        // Feed scroll view
        _feedScrollView = [[UIScrollView alloc] init];
        _feedScrollView.translatesAutoresizingMaskIntoConstraints = NO;
        _feedScrollView.showsVerticalScrollIndicator = YES;
        _feedScrollView.alwaysBounceVertical = NO;
        [_cardView addSubview:_feedScrollView];

        // Feed stack
        _feedStack = [[UIStackView alloc] init];
        _feedStack.axis = UILayoutConstraintAxisVertical;
        _feedStack.spacing = 2;
        _feedStack.translatesAutoresizingMaskIntoConstraints = NO;
        [_feedScrollView addSubview:_feedStack];

        // Build feed rows
        for (NSString *title in feedTitles) {
            _ICFeedRowView *row = [[_ICFeedRowView alloc] initWithTitle:title];
            [_feedStack addArrangedSubview:row];
            [self.feedRows addObject:row];
        }

        // Separator before metadata
        UIView *separator = [[UIView alloc] init];
        separator.backgroundColor = [UIColor separatorColor];
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:separator];

        // Metadata stack
        _metadataStack = [[UIStackView alloc] init];
        _metadataStack.axis = UILayoutConstraintAxisVertical;
        _metadataStack.spacing = 2;
        _metadataStack.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_metadataStack];

        // Build metadata rows (excluding NewPodcasts which is handled by feed rows)
        for (NSInteger i = 0; i < kMetadataCategoriesCount; i++) {
            ICBackupImportCategory cat = kMetadataCategories[i];
            if (!(categories & cat)) continue;

            NSString *title = [self titleForCategory:cat];
            _ICMetadataRowView *row = [[_ICMetadataRowView alloc] initWithTitle:title];
            [_metadataStack addArrangedSubview:row];
            self.metadataRows[@(cat)] = row;
        }

        // Cancel button
        _cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_cancelButton setTitle:@"Cancel".ls forState:UIControlStateNormal];
        _cancelButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_cancelButton addTarget:self action:@selector(_cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [_cardView addSubview:_cancelButton];

        // Calculate max feed list height (cap at 200pt to keep card manageable)
        CGFloat maxFeedHeight = MIN(feedTitles.count * 32, 200);

        // Layout
        [NSLayoutConstraint activateConstraints:@[
            // Card — centered, wide
            [_cardView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_cardView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-20],
            [_cardView.widthAnchor constraintEqualToConstant:340],

            // Title
            [_titleLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:18],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],

            // Timer
            [_timerLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:4],
            [_timerLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [_timerLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],

            // Total progress bar
            [_totalProgressBar.topAnchor constraintEqualToAnchor:_timerLabel.bottomAnchor constant:12],
            [_totalProgressBar.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [_totalProgressBar.trailingAnchor constraintEqualToAnchor:_totalProgressLabel.leadingAnchor constant:-8],

            [_totalProgressLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],
            [_totalProgressLabel.centerYAnchor constraintEqualToAnchor:_totalProgressBar.centerYAnchor],
            [_totalProgressLabel.widthAnchor constraintEqualToConstant:36],

            // Status
            [_statusLabel.topAnchor constraintEqualToAnchor:_totalProgressBar.bottomAnchor constant:8],
            [_statusLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [_statusLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],

            // Feed scroll view
            [_feedScrollView.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:10],
            [_feedScrollView.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [_feedScrollView.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],
            [_feedScrollView.heightAnchor constraintLessThanOrEqualToConstant:maxFeedHeight],

            // Feed stack inside scroll view
            [_feedStack.topAnchor constraintEqualToAnchor:_feedScrollView.topAnchor],
            [_feedStack.leadingAnchor constraintEqualToAnchor:_feedScrollView.leadingAnchor],
            [_feedStack.trailingAnchor constraintEqualToAnchor:_feedScrollView.trailingAnchor],
            [_feedStack.bottomAnchor constraintEqualToAnchor:_feedScrollView.bottomAnchor],
            [_feedStack.widthAnchor constraintEqualToAnchor:_feedScrollView.widthAnchor],

            // Separator
            [separator.topAnchor constraintEqualToAnchor:_feedScrollView.bottomAnchor constant:10],
            [separator.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [separator.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],
            [separator.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],

            // Metadata stack
            [_metadataStack.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:10],
            [_metadataStack.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [_metadataStack.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],

            // Cancel button
            [_cancelButton.topAnchor constraintEqualToAnchor:_metadataStack.bottomAnchor constant:16],
            [_cancelButton.centerXAnchor constraintEqualToAnchor:_cardView.centerXAnchor],
            [_cancelButton.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-16],
        ]];

        // Hide feed list if no new feeds to subscribe
        if (feedTitles.count == 0) {
            _feedScrollView.hidden = YES;
            separator.hidden = YES;
        }

        // Hide metadata section if no categories selected (besides NewPodcasts)
        if (self.metadataRows.count == 0) {
            separator.hidden = YES;
            _metadataStack.hidden = YES;
        }
    }
    return self;
}

- (NSString *)titleForCategory:(ICBackupImportCategory)cat {
    switch (cat) {
        case ICBackupImportNewPodcasts:   return @"New Podcasts".ls;
        case ICBackupImportEpisodeStatus: return @"Episode Status".ls;
        case ICBackupImportFeedSettings:  return @"Podcast Settings".ls;
        case ICBackupImportBookmarks:     return @"Bookmarks".ls;
        case ICBackupImportUpNext:        return @"Up Next".ls;
        case ICBackupImportNowPlaying:    return @"Now Playing".ls;
        case ICBackupImportPlaylists:     return @"Playlists".ls;
        case ICBackupImportSettings:      return @"App Settings".ls;
        case ICBackupImportSortOrder:     return @"Podcast Sort Order".ls;
        case ICBackupImportDownloads:     return @"Re-download Episodes".ls;
        default: return @"";
    }
}

#pragma mark - Feed Progress

- (void)setCurrentFeedAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.feedRows.count) return;
    _ICFeedRowView *row = self.feedRows[index];
    [row setActiveState];
    [self _scrollToFeedAtIndex:index];
}

- (void)setFeedProgress:(float)progress detail:(NSString *)detail atIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.feedRows.count) return;
    _ICFeedRowView *row = self.feedRows[index];
    [row setProgress:progress detail:detail];
}

- (void)setFeedCompletedAtIndex:(NSInteger)index episodeCount:(NSInteger)count {
    if (index < 0 || index >= (NSInteger)self.feedRows.count) return;
    _ICFeedRowView *row = self.feedRows[index];
    [row setCompletedWithEpisodeCount:count];
    self.completedFeedCount++;
}

- (void)setFeedErrorAtIndex:(NSInteger)index message:(NSString *)message {
    if (index < 0 || index >= (NSInteger)self.feedRows.count) return;
    _ICFeedRowView *row = self.feedRows[index];
    [row setErrorWithMessage:message];
    self.completedFeedCount++;
}

- (void)setFeedSkippedAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.feedRows.count) return;
    _ICFeedRowView *row = self.feedRows[index];
    [row setSkippedState];
    self.completedFeedCount++;
}

- (void)_scrollToFeedAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.feedRows.count) return;
    _ICFeedRowView *row = self.feedRows[index];
    CGRect rowFrame = [row convertRect:row.bounds toView:self.feedScrollView];
    [self.feedScrollView scrollRectToVisible:rowFrame animated:YES];
}

#pragma mark - Total Progress

- (void)setTotalProgress:(float)progress {
    self.totalProgressBar.progress = progress;
    self.totalProgressLabel.text = [NSString stringWithFormat:@"%d%%", (int)(progress * 100)];
}

- (void)setStatusText:(NSString *)text {
    self.statusLabel.text = text;
}

#pragma mark - Metadata Categories

- (void)setMetadataCategoryActive:(ICBackupImportCategory)category {
    _ICMetadataRowView *row = self.metadataRows[@(category)];
    [row setActive];
}

- (void)setMetadataCategoryCompleted:(ICBackupImportCategory)category detail:(NSString *)detail {
    _ICMetadataRowView *row = self.metadataRows[@(category)];
    [row setCompletedWithDetail:detail];
}

#pragma mark - Completion

- (void)showCompletionWithSummary:(NSString *)summary {
    [self.timerUpdate invalidate];
    self.timerUpdate = nil;

    self.titleLabel.text = @"Import Complete".ls;
    self.statusLabel.text = summary;
    [self setTotalProgress:1.0];
    self.cancelButton.hidden = YES;
}

#pragma mark - Timer

- (void)_startTimer {
    self.startTime = [NSDate timeIntervalSinceReferenceDate];
    self.timerUpdate = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(_updateTimer)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)_updateTimer {
    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.startTime;
    NSString *elapsedStr = [self _formatDuration:elapsed];

    // Estimate remaining time after 2+ feeds completed
    if (self.completedFeedCount >= 2 && self.totalFeedCount > 0) {
        NSTimeInterval perFeed = elapsed / self.completedFeedCount;
        NSTimeInterval estimated = perFeed * self.totalFeedCount;
        NSString *estimatedStr = [self _formatDuration:estimated];
        self.timerLabel.text = [NSString stringWithFormat:@"%@ / ~%@", elapsedStr, estimatedStr];
    } else {
        self.timerLabel.text = elapsedStr;
    }
}

- (NSString *)_formatDuration:(NSTimeInterval)duration {
    NSInteger minutes = (NSInteger)duration / 60;
    NSInteger seconds = (NSInteger)duration % 60;
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)seconds];
}

#pragma mark - Cancel

- (void)_cancelTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cancel Import".ls
                                                                  message:nil
                                                           preferredStyle:UIAlertControllerStyleActionSheet];

    if (self.onCancelCurrentFeed) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Skip Current Podcast".ls
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            if (self.onCancelCurrentFeed) self.onCancelCurrentFeed();
        }]];
    }

    if (self.onCancelImport) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel Entire Import".ls
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(UIAlertAction *action) {
            if (self.onCancelImport) self.onCancelImport();
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Back".ls
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    // For iPad: source view for popover
    alert.popoverPresentationController.sourceView = self.cancelButton;
    alert.popoverPresentationController.sourceRect = self.cancelButton.bounds;

    UIViewController *presenter = [self _topViewController];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (UIViewController *)_topViewController {
    UIViewController *vc = App.ic_keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

#pragma mark - Show / Close

- (void)show {
    self.parentWindow = App.ic_keyWindow;

    self.cardView.transform = CGAffineTransformMakeScale(0.85, 0.85);
    self.cardView.alpha = 0;
    self.backgroundColor = [UIColor clearColor];

    [App.ic_keyWindow addSubview:self];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        self.cardView.transform = CGAffineTransformIdentity;
        self.cardView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self _startTimer];
    }];
}

- (void)close {
    [self closeWithCompletion:nil];
}

- (void)closeWithCompletion:(void (^)(void))completion {
    [self.timerUpdate invalidate];
    self.timerUpdate = nil;

    [UIView animateWithDuration:0.2 animations:^{
        self.cardView.transform = CGAffineTransformMakeScale(0.9, 0.9);
        self.cardView.alpha = 0;
        self.backgroundColor = [UIColor clearColor];
    } completion:^(BOOL finished) {
        self.parentWindow = nil;
        [self removeFromSuperview];
        if (completion) completion();
    }];
}

@end
