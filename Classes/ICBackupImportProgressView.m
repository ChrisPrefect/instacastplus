//
//  ICBackupImportProgressView.m
//  Instacast
//

#import "ICBackupImportProgressView.h"

// Ordered list of all categories for display
static ICBackupImportCategory const kAllCategories[] = {
    ICBackupImportNewPodcasts,
    ICBackupImportEpisodeStatus,
    ICBackupImportFeedSettings,
    ICBackupImportBookmarks,
    ICBackupImportUpNext,
    ICBackupImportNowPlaying,
    ICBackupImportPlaylists,
    ICBackupImportSettings,
    ICBackupImportSortOrder,
};
static const NSInteger kAllCategoriesCount = 9;

#pragma mark - Row View

@interface _ICImportRowView : UIView
@property (nonatomic, strong) UIImageView *statusImageView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@end

@implementation _ICImportRowView

- (instancetype)initWithTitle:(NSString *)title detail:(NSString *)detail {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _statusImageView = [[UIImageView alloc] init];
        _statusImageView.contentMode = UIViewContentModeScaleAspectFit;
        _statusImageView.tintColor = [UIColor tertiaryLabelColor];
        UIImage *circle = [UIImage systemImageNamed:@"circle"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular]];
        _statusImageView.image = circle;
        _statusImageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_statusImageView];

        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        _spinner.hidesWhenStopped = YES;
        [self addSubview:_spinner];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.font = [UIFont systemFontOfSize:15];
        _titleLabel.textColor = [UIColor secondaryLabelColor];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];

        _detailLabel = [[UILabel alloc] init];
        _detailLabel.text = detail;
        _detailLabel.font = [UIFont systemFontOfSize:13];
        _detailLabel.textColor = [UIColor tertiaryLabelColor];
        _detailLabel.textAlignment = NSTextAlignmentRight;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_detailLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [_detailLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self addSubview:_detailLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_statusImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_statusImageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_statusImageView.widthAnchor constraintEqualToConstant:24],
            [_statusImageView.heightAnchor constraintEqualToConstant:24],

            [_spinner.centerXAnchor constraintEqualToAnchor:_statusImageView.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:_statusImageView.centerYAnchor],

            [_titleLabel.leadingAnchor constraintEqualToAnchor:_statusImageView.trailingAnchor constant:10],
            [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [_detailLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_titleLabel.trailingAnchor constant:8],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_detailLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

            [self.heightAnchor constraintEqualToConstant:32],
        ]];
    }
    return self;
}

- (void)setActive {
    self.statusImageView.hidden = YES;
    [self.spinner startAnimating];
    self.titleLabel.textColor = [UIColor labelColor];
    self.detailLabel.textColor = [UIColor secondaryLabelColor];
}

- (void)setCompleted {
    [self.spinner stopAnimating];
    self.statusImageView.hidden = NO;
    UIImage *check = [UIImage systemImageNamed:@"checkmark.circle.fill"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular]];
    self.statusImageView.image = check;
    self.statusImageView.tintColor = [UIColor systemGreenColor];
    self.titleLabel.textColor = [UIColor labelColor];
    self.detailLabel.textColor = [UIColor secondaryLabelColor];
}

@end

#pragma mark - Progress View

@interface ICBackupImportProgressView ()
@property (nonatomic, strong) UIView *cardView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, _ICImportRowView *> *rowViews;
@property (nonatomic, strong) UIWindow *parentWindow;
@end

@implementation ICBackupImportProgressView

- (instancetype)initWithCategories:(ICBackupImportCategory)categories
                      descriptions:(NSDictionary<NSNumber *, NSString *> *)descriptions
{
    self = [super initWithFrame:[UIScreen mainScreen].bounds];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        self.rowViews = [NSMutableDictionary dictionary];

        // Card
        BOOL isDark = [ICAppearanceManager sharedManager].nightSettingMode;
        _cardView = [[UIView alloc] init];
        _cardView.backgroundColor = isDark ? [UIColor colorWithWhite:0.15 alpha:0.95] : [UIColor colorWithWhite:1.0 alpha:0.95];
        _cardView.layer.cornerRadius = 14;
        _cardView.layer.cornerCurve = kCACornerCurveContinuous;
        _cardView.layer.shadowColor = [UIColor blackColor].CGColor;
        _cardView.layer.shadowOpacity = 0.2;
        _cardView.layer.shadowRadius = 20;
        _cardView.layer.shadowOffset = CGSizeMake(0, 4);
        _cardView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_cardView];

        // Title
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = @"Importing Data…".ls;
        _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _titleLabel.textColor = isDark ? [UIColor whiteColor] : [UIColor labelColor];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:_titleLabel];

        // Separator
        UIView *separator = [[UIView alloc] init];
        separator.backgroundColor = [UIColor separatorColor];
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:separator];

        // Build rows for active categories
        UIStackView *stack = [[UIStackView alloc] init];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 4;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_cardView addSubview:stack];

        for (NSInteger i = 0; i < kAllCategoriesCount; i++) {
            ICBackupImportCategory cat = kAllCategories[i];
            if (!(categories & cat)) continue;

            NSString *title = [self titleForCategory:cat];
            NSString *detail = descriptions[@(cat)] ?: @"";

            _ICImportRowView *row = [[_ICImportRowView alloc] initWithTitle:title detail:detail];
            [stack addArrangedSubview:row];
            self.rowViews[@(cat)] = row;
        }

        // Layout
        [NSLayoutConstraint activateConstraints:@[
            [_cardView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_cardView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-20],
            [_cardView.widthAnchor constraintEqualToConstant:300],

            [_titleLabel.topAnchor constraintEqualToAnchor:_cardView.topAnchor constant:18],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],

            [separator.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:14],
            [separator.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [separator.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],
            [separator.heightAnchor constraintEqualToConstant:1.0 / [UIScreen mainScreen].scale],

            [stack.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:14],
            [stack.leadingAnchor constraintEqualToAnchor:_cardView.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:_cardView.trailingAnchor constant:-20],
            [stack.bottomAnchor constraintEqualToAnchor:_cardView.bottomAnchor constant:-18],
        ]];
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
        default: return @"";
    }
}

#pragma mark - State Updates

- (void)setCategoryActive:(ICBackupImportCategory)category {
    _ICImportRowView *row = self.rowViews[@(category)];
    [row setActive];
}

- (void)setCategoryCompleted:(ICBackupImportCategory)category detail:(NSString *)detail {
    _ICImportRowView *row = self.rowViews[@(category)];
    row.detailLabel.text = detail;
    [row setCompleted];
}

- (void)setCategory:(ICBackupImportCategory)category detail:(NSString *)detail {
    _ICImportRowView *row = self.rowViews[@(category)];
    row.detailLabel.text = detail;
}

- (void)setTitleText:(NSString *)title {
    self.titleLabel.text = title;
}

#pragma mark - Show / Close

- (void)show {
    self.parentWindow = App.ic_keyWindow;
    self.parentWindow.userInteractionEnabled = NO;

    self.cardView.transform = CGAffineTransformMakeScale(0.8, 0.8);
    self.cardView.alpha = 0;
    self.backgroundColor = [UIColor clearColor];

    [App.ic_keyWindow addSubview:self];

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
        self.cardView.transform = CGAffineTransformIdentity;
        self.cardView.alpha = 1.0;
    } completion:nil];
}

- (void)close {
    [self closeWithCompletion:nil];
}

- (void)closeWithCompletion:(void (^)(void))completion {
    [UIView animateWithDuration:0.2 animations:^{
        self.cardView.transform = CGAffineTransformMakeScale(0.9, 0.9);
        self.cardView.alpha = 0;
        self.backgroundColor = [UIColor clearColor];
    } completion:^(BOOL finished) {
        self.parentWindow.userInteractionEnabled = YES;
        self.parentWindow = nil;
        [self removeFromSuperview];
        if (completion) completion();
    }];
}

@end
