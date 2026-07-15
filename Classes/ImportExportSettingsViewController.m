//
//  ImportExportSettingsViewController.m
//  Instacast
//

#import "ImportExportSettingsViewController.h"
#import "UITableViewController+Settings.h"
#import "SubscriptionManager.h"
#import "XPFF.h"
#import "VDModalInfo.h"
#import "CDPlaylist.h"
#import "CDEpisodeList.h"
#import "InstacastAppDelegate.h"
#import "InstacastBackupParser.h"
#import "InstacastBackupImportViewController.h"
#import "CacheManager.h"
#import "AppleWatchSyncManager.h"
#import "AppleWatchEpisodeState.h"
#import "CDFeedProperty.h"
#import "InstacastPlus-Swift.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/runtime.h>
#import <string.h>

static NSString *ICBackupKnownFeedPropertyType(NSString *key) {
    if ([key isEqualToString:kUserDefinedFeedName] ||
        [key isEqualToString:kFeedPropertyAutoTranscribe] ||
        [key isEqualToString:kFeedPropertyAutoChapters] ||
        [key isEqualToString:kFeedPropertyAutoSkipSponsors] ||
        [key isEqualToString:@"preferredTranscriptLanguage"] ||
        [key isEqualToString:@"preferredTranscriptURL"] ||
        [key isEqualToString:@"cachedPlayerTintColor"] ||
        [key hasSuffix:@"_auto_skip_chapter_name"]) {
        return @"string";
    }
    if ([key hasSuffix:@"_auto_skip_start_period"] ||
        [key hasSuffix:@"_auto_skip_end_period"] ||
        [key rangeOfString:@"_auto_skip_start_chapter_"].location != NSNotFound ||
        [key rangeOfString:@"_auto_skip_end_chapter_"].location != NSNotFound) {
        return @"double";
    }
    if ([key hasSuffix:@"_old_episode_delete_days"] ||
        [key isEqualToString:PlayerNearChapterEndForwardSkipMode] ||
        [key isEqualToString:PlayerNearChapterEndForwardSkipWindow]) {
        return @"integer";
    }
    return nil;
}

static NSString *ICBackupFeedPropertyType(CDFeedProperty *property) {
    NSString *knownType = ICBackupKnownFeedPropertyType(property.key);
    if (knownType) return knownType;

    id defaultValue = [USER_DEFAULTS objectForKey:property.key];
    if ([defaultValue isKindOfClass:[NSString class]]) return @"string";
    if ([defaultValue isKindOfClass:[NSNumber class]]) {
        NSNumber *number = defaultValue;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) return @"bool";
        const char *objCType = number.objCType;
        if (strcmp(objCType, @encode(double)) == 0 || strcmp(objCType, @encode(float)) == 0) return @"double";
        return @"integer";
    }

    if (property.stringValue != nil) return @"string";
    if (property.doubleValue != 0.0) return @"double";
    if (property.int32Value != 0) return @"integer";
    return @"bool";
}

static NSString* ICSafeExportFilenameComponent(NSString* value)
{
    NSMutableCharacterSet* forbidden = [NSMutableCharacterSet controlCharacterSet];
    [forbidden addCharactersInString:@"/\\:?%*|\"<>"];
    NSArray<NSString*>* parts = [value componentsSeparatedByCharactersInSet:forbidden];
    NSString* sanitized = [parts componentsJoinedByString:@"_"];
    sanitized = [sanitized stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([sanitized hasPrefix:@"."] || [sanitized hasSuffix:@"."]) {
        sanitized = [sanitized stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]];
    }
    if (sanitized.length == 0) {
        sanitized = @"InstacastPlus";
    }
    if (sanitized.length > 80) {
        NSRange range = [sanitized rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 80)];
        sanitized = [sanitized substringWithRange:range];
    }
    return sanitized;
}

static const NSUInteger ICBackupFetchBatchSize = 400;

typedef NS_ENUM(NSInteger, ImportExportSections) {
    kExportSection = 0,
    kImportSection,
    kResetAppSection,
    kNumberOfSections,
};

@interface ICImportExportSceneState : NSObject
@property (nonatomic) BOOL fullExportInProgress;
@property (nonatomic, strong) NSURL* pendingFullExportURL;
@property (nonatomic, strong) NSError* pendingFullExportError;
@property (nonatomic) BOOL subscriptionsExportInProgress;
@property (nonatomic, strong) NSURL* pendingSubscriptionsExportURL;
@property (nonatomic, strong) NSError* pendingSubscriptionsExportError;
@property (nonatomic) BOOL bookmarksExportInProgress;
@property (nonatomic, strong) NSURL* pendingBookmarksExportURL;
@property (nonatomic, strong) NSError* pendingBookmarksExportError;
@end

@implementation ICImportExportSceneState
@end

static const void* ICImportExportSceneStateAssociationKey = &ICImportExportSceneStateAssociationKey;

@interface ImportExportSettingsViewController () <UIDocumentInteractionControllerDelegate, UIDocumentPickerDelegate>
@property (nonatomic, strong) UIDocumentInteractionController* interactionController;
@property (nonatomic, strong) VDModalInfo* mInfo;
@property (nonatomic) NSInteger selectedImportRow;
@property (nonatomic) BOOL importInProgress;
@property (nonatomic) BOOL fullExportInProgress;
@property (nonatomic, strong) NSURL *pendingFullExportURL;
@property (nonatomic, strong) NSError *pendingFullExportError;
@property (nonatomic) BOOL subscriptionsExportInProgress;
@property (nonatomic, strong) NSURL *pendingSubscriptionsExportURL;
@property (nonatomic, strong) NSError *pendingSubscriptionsExportError;
@property (nonatomic) BOOL bookmarksExportInProgress;
@property (nonatomic, strong) NSURL *pendingBookmarksExportURL;
@property (nonatomic, strong) NSError *pendingBookmarksExportError;
@property (nonatomic, strong) ICImportExportSceneState* retainedSceneExportState;
@property (nonatomic, readonly) ICImportExportSceneState* sceneExportState;
@end

@implementation ImportExportSettingsViewController

- (ICImportExportSceneState*)sceneExportState
{
    if (self.retainedSceneExportState) return self.retainedSceneExportState;

    UIWindow* window = self.viewIfLoaded.window ?: self.navigationController.viewIfLoaded.window;
    UIWindowScene* windowScene = window.windowScene;
    if (!windowScene) return nil;

    ICImportExportSceneState* state = objc_getAssociatedObject(windowScene, ICImportExportSceneStateAssociationKey);
    if (!state) {
        state = [[ICImportExportSceneState alloc] init];
        objc_setAssociatedObject(windowScene, ICImportExportSceneStateAssociationKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self.retainedSceneExportState = state;
    return state;
}

- (BOOL)fullExportInProgress { return self.sceneExportState.fullExportInProgress; }
- (void)setFullExportInProgress:(BOOL)inProgress { self.sceneExportState.fullExportInProgress = inProgress; }
- (NSURL*)pendingFullExportURL { return self.sceneExportState.pendingFullExportURL; }
- (void)setPendingFullExportURL:(NSURL*)url { self.sceneExportState.pendingFullExportURL = url; }
- (NSError*)pendingFullExportError { return self.sceneExportState.pendingFullExportError; }
- (void)setPendingFullExportError:(NSError*)error { self.sceneExportState.pendingFullExportError = error; }
- (BOOL)subscriptionsExportInProgress { return self.sceneExportState.subscriptionsExportInProgress; }
- (void)setSubscriptionsExportInProgress:(BOOL)inProgress { self.sceneExportState.subscriptionsExportInProgress = inProgress; }
- (NSURL*)pendingSubscriptionsExportURL { return self.sceneExportState.pendingSubscriptionsExportURL; }
- (void)setPendingSubscriptionsExportURL:(NSURL*)url { self.sceneExportState.pendingSubscriptionsExportURL = url; }
- (NSError*)pendingSubscriptionsExportError { return self.sceneExportState.pendingSubscriptionsExportError; }
- (void)setPendingSubscriptionsExportError:(NSError*)error { self.sceneExportState.pendingSubscriptionsExportError = error; }
- (BOOL)bookmarksExportInProgress { return self.sceneExportState.bookmarksExportInProgress; }
- (void)setBookmarksExportInProgress:(BOOL)inProgress { self.sceneExportState.bookmarksExportInProgress = inProgress; }
- (NSURL*)pendingBookmarksExportURL { return self.sceneExportState.pendingBookmarksExportURL; }
- (void)setPendingBookmarksExportURL:(NSURL*)url { self.sceneExportState.pendingBookmarksExportURL = url; }
- (NSError*)pendingBookmarksExportError { return self.sceneExportState.pendingBookmarksExportError; }
- (void)setPendingBookmarksExportError:(NSError*)error { self.sceneExportState.pendingBookmarksExportError = error; }

+ (ImportExportSettingsViewController*) viewController
{
    return [[self alloc] initWithStyle:UITableViewStyleGrouped];
}

- (id)initWithStyle:(UITableViewStyle)style
{
    self = [super initWithStyle:style];
    if (self) {
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupSettingsTableViewSpacing];
    [self setScrollView:self.tableView contentInsets:UIEdgeInsetsZero byAdjustingForStandardBars:YES];

    self.clearsSelectionOnViewWillAppear = YES;
    self.navigationItem.title = @"Import / Export".ls;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAppearance)
                                                 name:ICAppearanceManagerDidUpdateAppearanceNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    self.importInProgress = NO;
    [self updateAppearance];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableView reloadData];
    [self presentPendingFullExportResultIfNeeded];
    [self presentPendingSubscriptionsExportResultIfNeeded];
    [self presentPendingBookmarksExportResultIfNeeded];
}

- (void) updateAppearance {
    self.tableView.backgroundColor = ICBackgroundColor;
    self.tableView.separatorColor = ICGroupCellSelectedBackgroundColor;

    if (self.tableView.window && !self.transitionCoordinator) {
        [self.tableView reloadData];
    }
}

- (void) dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    return kNumberOfSections;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case kExportSection:
            return 3;
        case kImportSection:
            return 2;
        case kResetAppSection:
            return 1;
    }
    return 0;
}

- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return 80;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath
{
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

    cell.textLabel.textColor = ICTextColor;
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
    cell.backgroundColor = ICGroupCellBackgroundColor;
    cell.imageView.tintColor = [[ICAppearanceManager sharedManager] appearance].tintColor;

    UIView* selectedView = [[UIView alloc] init];
    selectedView.backgroundColor = ICGroupCellSelectedBackgroundColor;
    cell.selectedBackgroundView = selectedView;

    switch (indexPath.section) {
        case kExportSection:
            if (indexPath.row == 0) {
                cell.textLabel.text = @"All InstacastPlus Data".ls;
                cell.detailTextLabel.text = self.fullExportInProgress
                    ? @"Backup wird exportiert…".ls
                    : @"For exchanging data between InstacastPlus apps. Contains all data including subscriptions, bookmarks, playback status and settings.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
                if (self.fullExportInProgress) {
                    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                    spinner.color = [[ICAppearanceManager sharedManager] appearance].tintColor;
                    [spinner startAnimating];
                    cell.accessoryView = spinner;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                }
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Subscriptions (OPML)".ls;
                cell.detailTextLabel.text = self.subscriptionsExportInProgress
                    ? @"Subscriptions are being exported…".ls
                    : @"The OPML file can be read by other podcast apps but only contains the subscriptions without any additional data.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
                if (self.subscriptionsExportInProgress) {
                    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                    spinner.color = [[ICAppearanceManager sharedManager] appearance].tintColor;
                    [spinner startAnimating];
                    cell.accessoryView = spinner;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                }
            } else {
                cell.textLabel.text = @"Bookmarks".ls;
                cell.detailTextLabel.text = self.bookmarksExportInProgress
                    ? @"Bookmarks are being exported…".ls
                    : @"Export all bookmarks as a file.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"bookmark"];
                if (self.bookmarksExportInProgress) {
                    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
                    spinner.color = [[ICAppearanceManager sharedManager] appearance].tintColor;
                    [spinner startAnimating];
                    cell.accessoryView = spinner;
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                }
            }
            break;
        case kImportSection:
            if (indexPath.row == 0) {
                cell.textLabel.text = @"All InstacastPlus Data".ls;
                cell.detailTextLabel.text = @"Import all data from an InstacastPlus backup file.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
            } else {
                cell.textLabel.text = @"Subscriptions (OPML)".ls;
                cell.detailTextLabel.text = @"Import subscriptions from an OPML file.".ls;
                cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            }
            break;
        case kResetAppSection:
            cell.textLabel.text = @"Reset App".ls;
            cell.textLabel.textColor = [UIColor redColor];
            cell.detailTextLabel.text = @"Delete all data and reset the app to factory settings.".ls;
            cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            cell.imageView.tintColor = [UIColor redColor];
            break;
    }

    return cell;
}

- (NSString*) tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case kExportSection:
            return @"Export".ls;
        case kImportSection:
            return @"Import".ls;
    }
    return nil;
}

- (NSString*) tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    if (section == kImportSection) {
        return @"You can also open .opml or .xml files from Mail or the Files app in InstacastPlus to import data.".ls;
    }
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section
{
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    [header.textLabel setTextColor:[UIColor grayColor]];
}

- (void)tableView:(UITableView *)tableView willDisplayFooterView:(UIView *)view forSection:(NSInteger)section
{
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *footerView = (UITableViewHeaderFooterView *)view;
        footerView.textLabel.textColor = [UIColor grayColor];
        footerView.textLabel.font = [UIFont systemFontOfSize:ICFontSize(13)];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section
{
    NSString* text = [self tableView:tableView titleForFooterInSection:section];
    return [self heightForFooterText:text];
}

#pragma mark - Table view delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    BOOL anyExportInProgress = [self anyExportInProgress];

    switch (indexPath.section) {
        case kExportSection:
            if (indexPath.row == 0) {
                if (self.fullExportInProgress) return;
                [self exportEverything];
            } else if (indexPath.row == 1) {
                [self exportSubscriptions];
            } else {
                [self exportBookmarks];
            }
            break;
        case kImportSection:
            if (anyExportInProgress || self.importInProgress) return;
            self.selectedImportRow = indexPath.row;
            [self showImportDocumentPicker];
            break;
        case kResetAppSection:
            if (anyExportInProgress || self.importInProgress) return;
            [self resetApp];
            break;
    }
}

#pragma mark - Export

- (BOOL)anyExportInProgress
{
    return self.fullExportInProgress || self.subscriptionsExportInProgress || self.bookmarksExportInProgress;
}

- (void)_commitExportBusyAppearance
{
    if (!self.isViewLoaded) return;
    [self.tableView layoutIfNeeded];
    [self.tableView.window layoutIfNeeded];
    [CATransaction flush];
}

- (void) exportSubscriptions
{
    if (self.importInProgress || [self anyExportInProgress]) {
        return;
    }
    [self setSubscriptionsExportBusy:YES];
    [self _commitExportBusyAppearance];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _beginSubscriptionsExportAfterBusyState];
    });
}

- (void)_beginSubscriptionsExportAfterBusyState
{
    if (!self.subscriptionsExportInProgress) return;
    NSError* saveError = [DMANAGER saveReturningError];
    if (saveError) {
        [self finishSubscriptionsExportWithURL:nil error:saveError];
        return;
    }
    NSString* fileName = [NSString stringWithFormat:@"%@.opml", ICSafeExportFilenameComponent([NSString stringWithFormat:@"%@-%@", @"Subscriptions".ls, [UIDevice currentDevice].name])];
    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];

    [[SubscriptionManager sharedSubscriptionManager] opmlDataWithCompletion:^(NSData* data, NSError* exportError) {
        if (!data || exportError) {
            NSError* resultError = exportError ?: [NSError errorWithDomain:@"OPMLExport"
                                                                      code:3
                                                                  userInfo:@{NSLocalizedDescriptionKey: @"The OPML document could not be created.".ls}];
            [self finishSubscriptionsExportWithURL:nil error:resultError];
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSError* writeError = nil;
            BOOL didWrite = [data writeToURL:url options:NSDataWritingAtomic error:&writeError];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError* resultError = didWrite ? nil : (writeError ?: [NSError errorWithDomain:@"OPMLExport"
                                                                                           code:4
                                                                                       userInfo:@{NSLocalizedDescriptionKey: @"The OPML file could not be written.".ls}]);
                [self finishSubscriptionsExportWithURL:didWrite ? url : nil error:resultError];
            });
        });
    }];
}

- (void)setSubscriptionsExportBusy:(BOOL)busy
{
    self.subscriptionsExportInProgress = busy;
    if (self.isViewLoaded) {
        NSIndexPath* indexPath = [NSIndexPath indexPathForRow:1 inSection:kExportSection];
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentPendingSubscriptionsExportResultIfNeeded
{
    if (!self.pendingSubscriptionsExportURL && !self.pendingSubscriptionsExportError) return;
    if (!self.viewIfLoaded.window || self.navigationController.topViewController != self) return;
    if (self.presentedViewController) return;

    NSURL* url = self.pendingSubscriptionsExportURL;
    NSError* error = self.pendingSubscriptionsExportError;
    self.pendingSubscriptionsExportURL = nil;
    self.pendingSubscriptionsExportError = nil;

    if (!url || error) {
        NSString* message = error.localizedDescription.length > 0
            ? error.localizedDescription
            : @"The subscriptions could not be exported. Check the available storage and try again.".ls;
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Export Error".ls
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
    self.interactionController.delegate = self;
    self.interactionController.name = url.lastPathComponent;
    self.interactionController.UTI = @"instacast.opml";
    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
        self.interactionController = nil;
        [self _presentShareUnavailableError];
    }
}

- (void)finishSubscriptionsExportWithURL:(NSURL*)url error:(NSError*)error
{
    NSAssert([NSThread isMainThread], @"Export UI completion must run on the main thread");
    [self setSubscriptionsExportBusy:NO];
    if (error) {
        ErrLog(@"OPML export failed: %@", error.localizedDescription);
    }
    self.pendingSubscriptionsExportURL = url;
    self.pendingSubscriptionsExportError = error;
    [self presentPendingSubscriptionsExportResultIfNeeded];
}

- (void) exportBookmarks
{
    if (self.importInProgress || [self anyExportInProgress]) {
        return;
    }
    [self setBookmarksExportBusy:YES];
    [self _commitExportBusyAppearance];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _beginBookmarksExportAfterBusyState];
    });
}

- (void)_beginBookmarksExportAfterBusyState
{
    if (!self.bookmarksExportInProgress) return;
    NSError* saveError = [DMANAGER saveReturningError];
    if (saveError) {
        [self finishBookmarksExportWithURL:nil error:saveError];
        return;
    }
    NSString* fileName = [NSString stringWithFormat:@"%@.xpff", ICSafeExportFilenameComponent([NSString stringWithFormat:@"%@-%@", @"Bookmarks".ls, [UIDevice currentDevice].name])];
    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __block NSError* exportError = nil;
        __block NSData* data = nil;
        NSManagedObjectContext* context = [DMANAGER newExportBackgroundContext];
        if (!context) {
            exportError = [NSError errorWithDomain:@"BookmarksExport"
                                              code:1
                                          userInfo:@{NSLocalizedDescriptionKey: @"The bookmark database could not be opened for export.".ls}];
        }
        else {
            [context performBlockAndWait:^{
                NSFetchRequest* request = [[NSFetchRequest alloc] initWithEntityName:@"Bookmark"];
                request.sortDescriptors = @[
                    [[NSSortDescriptor alloc] initWithKey:@"episodeHash" ascending:YES],
                    [[NSSortDescriptor alloc] initWithKey:@"position" ascending:YES],
                ];
                NSArray<CDBookmark*>* bookmarks = [context executeFetchRequest:request error:&exportError];
                if (!bookmarks || exportError) {
                    return;
                }
                data = XPFFDataWithBookmarks(bookmarks);
                if (data.length == 0) {
                    exportError = [NSError errorWithDomain:@"BookmarksExport"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"The bookmark document could not be created.".ls}];
                }
            }];
        }

        BOOL didWrite = NO;
        if (data && !exportError) {
            didWrite = [data writeToURL:url options:NSDataWritingAtomic error:&exportError];
            if (!didWrite && !exportError) {
                exportError = [NSError errorWithDomain:@"BookmarksExport"
                                                  code:3
                                              userInfo:@{NSLocalizedDescriptionKey: @"The bookmark file could not be written.".ls}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self finishBookmarksExportWithURL:didWrite ? url : nil error:exportError];
        });
    });
}

- (void)setBookmarksExportBusy:(BOOL)busy
{
    self.bookmarksExportInProgress = busy;
    if (self.isViewLoaded) {
        NSIndexPath* indexPath = [NSIndexPath indexPathForRow:2 inSection:kExportSection];
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentPendingBookmarksExportResultIfNeeded
{
    if (!self.pendingBookmarksExportURL && !self.pendingBookmarksExportError) return;
    if (!self.viewIfLoaded.window || self.navigationController.topViewController != self) return;
    if (self.presentedViewController) return;

    NSURL* url = self.pendingBookmarksExportURL;
    NSError* error = self.pendingBookmarksExportError;
    self.pendingBookmarksExportURL = nil;
    self.pendingBookmarksExportError = nil;

    if (!url || error) {
        NSString* message = error.localizedDescription.length > 0
            ? error.localizedDescription
            : @"The bookmarks could not be exported. Check the available storage and try again.".ls;
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Export Error".ls
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
    self.interactionController.delegate = self;
    self.interactionController.name = url.lastPathComponent;
    self.interactionController.UTI = @"com.vemedio.xpff";
    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
        self.interactionController = nil;
        [self _presentShareUnavailableError];
    }
}

- (void)finishBookmarksExportWithURL:(NSURL*)url error:(NSError*)error
{
    NSAssert([NSThread isMainThread], @"Export UI completion must run on the main thread");
    [self setBookmarksExportBusy:NO];
    if (error) {
        ErrLog(@"Bookmark export failed: %@", error.localizedDescription);
    }
    self.pendingBookmarksExportURL = url;
    self.pendingBookmarksExportError = error;
    [self presentPendingBookmarksExportResultIfNeeded];
}

- (NSString*) xmlEscape:(NSString*)string
{
    return [string stringByEncodingStandardHTMLEntities] ?: @"";
}

- (NSString *)_hexColorForDefaults:(NSUserDefaults *)defaults hexKey:(NSString *)hexKey colorDataKey:(NSString *)colorDataKey
{
    return [UIColor ic_colorHexFromDefaults:defaults hexKey:hexKey legacyArchiveKey:colorDataKey];
}

- (NSDictionary<NSString *, id> *)exportSnapshotForEpisode:(CDEpisode *)episode
{
    if (!episode) return nil;
    return @{
        @"media": [episode.preferedMedium.fileURL absoluteString] ?: @"",
        @"guid": episode.guid ?: @"",
        @"feedUrl": [episode.feed.sourceURL absoluteString] ?: @"",
        @"position": @(episode.position),
    };
}

- (void)setFullExportBusy:(BOOL)busy
{
    self.fullExportInProgress = busy;
    if (self.isViewLoaded) {
        NSIndexPath *indexPath = [NSIndexPath indexPathForRow:0 inSection:kExportSection];
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)presentPendingFullExportResultIfNeeded
{
    if (!self.pendingFullExportURL && !self.pendingFullExportError) return;
    if (!self.viewIfLoaded.window || self.navigationController.topViewController != self) return;
    if (self.presentedViewController) return;

    NSURL *url = self.pendingFullExportURL;
    NSError *error = self.pendingFullExportError;
    self.pendingFullExportURL = nil;
    self.pendingFullExportError = nil;

    if (!url || error) {
        NSString* message = error.localizedDescription.length > 0
            ? error.localizedDescription
            : @"Das Backup konnte nicht exportiert werden. Prüfe den freien Speicherplatz und versuche es erneut.".ls;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Export Error".ls
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    self.interactionController = [UIDocumentInteractionController interactionControllerWithURL:url];
    self.interactionController.delegate = self;
    self.interactionController.name = url.lastPathComponent;
    self.interactionController.UTI = @"public.xml";
    if (![self.interactionController presentOpenInMenuFromRect:CGRectZero inView:self.navigationController.view animated:YES]) {
        self.interactionController = nil;
        [self _presentShareUnavailableError];
    }
}

- (void)_presentShareUnavailableError
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Share Unavailable".ls
                                                                   message:@"The exported file was created, but the share menu could not be opened. Try again from the export settings.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)finishFullExportWithURL:(NSURL *)url error:(NSError *)error
{
    NSAssert([NSThread isMainThread], @"Export UI completion must run on the main thread");
    [self setFullExportBusy:NO];
    if (error) {
        ErrLog(@"Full backup export failed: %@", error.localizedDescription);
    }
    self.pendingFullExportURL = url;
    self.pendingFullExportError = error;
    [self presentPendingFullExportResultIfNeeded];
}

- (NSSet<NSString *> *)cachedEpisodeHashesAtStoragePath:(NSString *)storagePath
                                                  error:(NSError **)error
{
    NSArray<NSString *> *filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:storagePath error:error];
    if (!filenames) return nil;

    NSMutableSet<NSString *> *hashes = [NSMutableSet set];
    for (NSString *filename in filenames) {
        NSString *nameWithoutExtension = [filename stringByDeletingPathExtension];
        NSRange lastSeparator = [nameWithoutExtension rangeOfString:@" - " options:NSBackwardsSearch];
        NSString *episodeHash = lastSeparator.location == NSNotFound
            ? nameWithoutExtension
            : [nameWithoutExtension substringFromIndex:NSMaxRange(lastSeparator)];
        if (episodeHash.length > 0) {
            [hashes addObject:episodeHash];
        }
    }
    return [hashes copy];
}

- (void) exportEverything
{
    if (self.importInProgress || [self anyExportInProgress]) return;
    [self setFullExportBusy:YES];
    [self _commitExportBusyAppearance];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _beginFullExportAfterBusyState];
    });
}

- (void)_beginFullExportAfterBusyState
{
    if (!self.fullExportInProgress) return;

    // Persist current UI-context edits before the independent read-only coordinator
    // takes its snapshot. Only immutable values cross to the export queue.
    NSError* saveError = [DMANAGER saveReturningError];
    if (saveError) {
        [self finishFullExportWithURL:nil error:saveError];
        return;
    }

    AudioSession *session = [AudioSession sharedAudioSession];
    NSMutableArray<NSDictionary<NSString *, id> *> *upNextSnapshots = [NSMutableArray array];
    for (CDEpisode *episode in session.playlist) {
        NSDictionary *snapshot = [self exportSnapshotForEpisode:episode];
        if (snapshot) [upNextSnapshots addObject:snapshot];
    }
    NSDictionary<NSString *, id> *nowPlayingSnapshot = [self exportSnapshotForEpisode:session.episode];
    NSDictionary<NSString *, NSString *> *credentialValues = [[ICRemoteChapterCredentialStore backupCredentialValues] copy];
    NSString *alternateIconName = [[[UIApplication sharedApplication] alternateIconName] copy];
    NSString *deviceName = ICSafeExportFilenameComponent([UIDevice currentDevice].name);
    NSArray<NSDictionary<NSString *, id> *> *upNextSnapshot = [upNextSnapshots copy];
    NSString *downloadStoragePath = [DMANAGER.fileCacheURL.path copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *cacheSnapshotError = nil;
        NSSet<NSString *> *verifiedCachedHashes = [self cachedEpisodeHashesAtStoragePath:downloadStoragePath
                                                                                  error:&cacheSnapshotError];
        if (!verifiedCachedHashes) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishFullExportWithURL:nil error:cacheSnapshotError];
            });
            return;
        }

        NSManagedObjectContext *context = [DMANAGER newExportBackgroundContext];
        if (!context) {
            NSError *error = [NSError errorWithDomain:@"InstacastBackupExport"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"The backup could not be exported because the local podcast database could not be opened. Check the available storage, restart InstacastPlus, and try again.".ls}];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishFullExportWithURL:nil error:error];
            });
            return;
        }

        [context performBlock:^{
            @autoreleasepool {
                NSError* generationError = nil;
                if (![context setQueryGenerationFromToken:[NSQueryGenerationToken currentQueryGenerationToken]
                                                    error:&generationError]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self finishFullExportWithURL:nil error:generationError];
                    });
                    return;
                }
                NSError *error = nil;
                NSURL *url = [self createEverythingBackupWithContext:context
                                                 cachedEpisodeHashes:verifiedCachedHashes
                                                     upNextSnapshots:upNextSnapshot
                                                  nowPlayingSnapshot:nowPlayingSnapshot
                                                    credentialValues:credentialValues
                                                   alternateIconName:alternateIconName
                                                           deviceName:deviceName
                                                                error:&error];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self finishFullExportWithURL:url error:error];
                });
            }
        }];
    });
}

- (NSURL *)createEverythingBackupWithContext:(NSManagedObjectContext *)context
                         cachedEpisodeHashes:(NSSet<NSString *> *)cachedEpisodeHashes
                             upNextSnapshots:(NSArray<NSDictionary<NSString *, id> *> *)upNextSnapshots
                          nowPlayingSnapshot:(NSDictionary<NSString *, id> *)nowPlayingSnapshot
                            credentialValues:(NSDictionary<NSString *, NSString *> *)credentialValues
                           alternateIconName:(NSString *)alternateIconName
                                  deviceName:(NSString *)deviceName
                                       error:(NSError **)error
{
    NSMutableString* xml = [NSMutableString string];
    NSDateFormatter* dateFormatter = [[NSDateFormatter alloc] init];
    dateFormatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    [dateFormatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ssZ"];

    // XML Header
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendFormat:@"<instacast version=\"1\" date=\"%@\">\n", [dateFormatter stringFromDate:[NSDate date]]];

    // Podcasts
    NSFetchRequest* fetchRequest = [[NSFetchRequest alloc] initWithEntityName:@"Feed"];
    fetchRequest.predicate = [NSPredicate predicateWithFormat:@"subscribed == YES"];
    fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
    fetchRequest.relationshipKeyPathsForPrefetching = @[@"properties"];
    fetchRequest.fetchBatchSize = ICBackupFetchBatchSize;
    NSArray* feeds = [context executeFetchRequest:fetchRequest error:error];
    if (!feeds) return nil;

    NSMutableDictionary<NSManagedObjectID*, NSMutableArray<CDEpisode*>*>* stateEpisodesByFeedObjectID = [NSMutableDictionary dictionary];
    NSMutableSet<NSManagedObjectID*>* indexedEpisodeObjectIDs = [NSMutableSet set];
    void (^indexEpisode)(CDEpisode*) = ^(CDEpisode* episode) {
        if (!episode.feed || [indexedEpisodeObjectIDs containsObject:episode.objectID]) return;
        [indexedEpisodeObjectIDs addObject:episode.objectID];
        NSMutableArray<CDEpisode*>* feedEpisodes = stateEpisodesByFeedObjectID[episode.feed.objectID];
        if (!feedEpisodes) {
            feedEpisodes = [NSMutableArray array];
            stateEpisodesByFeedObjectID[episode.feed.objectID] = feedEpisodes;
        }
        [feedEpisodes addObject:episode];
    };

    NSFetchRequest* stateEpisodesRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
    stateEpisodesRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND (consumed == YES OR starred == YES OR archived == YES OR position > 0)"];
    stateEpisodesRequest.relationshipKeyPathsForPrefetching = @[@"feed", @"media"];
    stateEpisodesRequest.fetchBatchSize = ICBackupFetchBatchSize;
    NSArray<CDEpisode*>* stateEpisodes = [context executeFetchRequest:stateEpisodesRequest error:error];
    if (!stateEpisodes) return nil;
    for (CDEpisode* episode in stateEpisodes) {
        indexEpisode(episode);
    }

    NSArray<NSString*>* cachedHashes = cachedEpisodeHashes.allObjects;
    for (NSUInteger offset = 0; offset < cachedHashes.count; offset += ICBackupFetchBatchSize) {
        @autoreleasepool {
            NSArray<NSString*>* hashBatch = [cachedHashes subarrayWithRange:NSMakeRange(offset, MIN(ICBackupFetchBatchSize, cachedHashes.count - offset))];
            NSFetchRequest* cachedEpisodesRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
            cachedEpisodesRequest.predicate = [NSPredicate predicateWithFormat:@"feed.subscribed == YES AND objectHash IN %@", hashBatch];
            cachedEpisodesRequest.relationshipKeyPathsForPrefetching = @[@"feed", @"media"];
            cachedEpisodesRequest.fetchBatchSize = ICBackupFetchBatchSize;
            NSArray<CDEpisode*>* cachedEpisodes = [context executeFetchRequest:cachedEpisodesRequest error:error];
            if (!cachedEpisodes) return nil;
            for (CDEpisode* episode in cachedEpisodes) {
                indexEpisode(episode);
            }
        }
    }

    [xml appendString:@"  <podcasts>\n"];
    for (CDFeed* feed in feeds) {
        NSMutableString *podcastAttrs = [NSMutableString stringWithFormat:@"url=\"%@\" rank=\"%d\" title=\"%@\"",
            [self xmlEscape:[feed.sourceURL absoluteString]], feed.rank, [self xmlEscape:feed.title ?: @""]];
        if (feed.parked) {
            [podcastAttrs appendString:@" parked=\"true\""];
        }
        if (feed.username.length > 0) {
            [podcastAttrs appendFormat:@" username=\"%@\"", [self xmlEscape:feed.username]];
        }
        if (feed.password.length > 0) {
            [podcastAttrs appendFormat:@" password=\"%@\"", [self xmlEscape:feed.password]];
        }
        [xml appendFormat:@"    <podcast %@>\n", podcastAttrs];

        // Custom properties (skip internal keys)
        NSArray* propertyKeys = [feed propertyKeys];
        BOOL hasTranscriptPrefs = [propertyKeys containsObject:@"preferredTranscriptLanguage"] || [propertyKeys containsObject:@"preferredTranscriptURL"];
        if ([feed hasCustomProperties] || hasTranscriptPrefs) {
            NSSet* internalKeys = [NSSet setWithObjects:@"episodeLoadingComplete", @"loadedEpisodeCount", @"totalExpectedEpisodes", nil];
            [xml appendString:@"      <settings>\n"];
            for (NSString* key in propertyKeys) {
                if ([internalKeys containsObject:key]) continue;
                NSString* escapedKey = [self xmlEscape:key];
                CDFeedProperty *property = [feed propertyForKey:key insertOnDemand:NO];
                if (!property) continue;
                NSString *type = ICBackupFeedPropertyType(property);
                if ([type isEqualToString:@"string"]) {
                    [xml appendFormat:@"        <setting key=\"%@\" type=\"string\" value=\"%@\"/>\n",
                        escapedKey, [self xmlEscape:property.stringValue ?: @""]];
                } else if ([type isEqualToString:@"double"]) {
                    [xml appendFormat:@"        <setting key=\"%@\" type=\"double\" value=\"%@\"/>\n",
                        escapedKey, [NSString stringWithFormat:@"%.17g", property.doubleValue]];
                } else if ([type isEqualToString:@"integer"]) {
                    [xml appendFormat:@"        <setting key=\"%@\" type=\"integer\" value=\"%ld\"/>\n",
                        escapedKey, (long)property.int32Value];
                } else {
                    [xml appendFormat:@"        <setting key=\"%@\" type=\"bool\" value=\"%@\"/>\n", escapedKey,
                        property.boolValue ? @"true" : @"false"];
                }
            }
            [xml appendString:@"      </settings>\n"];
        }

        // Episodes with state
        BOOL hasEpisodes = NO;
        for (CDEpisode* episode in stateEpisodesByFeedObjectID[feed.objectID] ?: @[]) {
            BOOL isCached = [cachedEpisodeHashes containsObject:episode.objectHash ?: @""];
            if (episode.consumed || episode.starred || episode.archived || episode.position > 0 || isCached) {
                if (!hasEpisodes) {
                    [xml appendString:@"      <episodes>\n"];
                    hasEpisodes = YES;
                }
                CDMedium* medium = [episode preferedMedium];
                [xml appendFormat:@"        <episode media=\"%@\" guid=\"%@\">\n",
                    [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                    [self xmlEscape:episode.guid ?: @""]];
                if (episode.consumed) [xml appendString:@"          <played>true</played>\n"];
                if (episode.starred) [xml appendString:@"          <starred>true</starred>\n"];
                if (episode.archived) [xml appendString:@"          <archived>true</archived>\n"];
                if (isCached) [xml appendString:@"          <downloaded>true</downloaded>\n"];
                if (episode.position > 0) [xml appendFormat:@"          <position>%d</position>\n", episode.position];
                if (episode.duration > 0) [xml appendFormat:@"          <duration>%d</duration>\n", episode.duration];
                [xml appendString:@"        </episode>\n"];
            }
        }
        if (hasEpisodes) [xml appendString:@"      </episodes>\n"];
        [xml appendString:@"    </podcast>\n"];
    }
    [xml appendString:@"  </podcasts>\n"];

    // Bookmarks
    NSFetchRequest *bookmarksRequest = [[NSFetchRequest alloc] initWithEntityName:@"Bookmark"];
    NSArray* bookmarks = [context executeFetchRequest:bookmarksRequest error:error];
    if (!bookmarks) return nil;
    if (bookmarks.count > 0) {
        [xml appendString:@"  <bookmarks>\n"];
        for (CDBookmark* bookmark in bookmarks) {
            [xml appendFormat:@"    <bookmark position=\"%.0f\" title=\"%@\" episodeGuid=\"%@\" feedUrl=\"%@\"/>\n",
                bookmark.position,
                [self xmlEscape:bookmark.title ?: @""],
                [self xmlEscape:bookmark.episodeGuid ?: @""],
                [self xmlEscape:[bookmark.feedURL absoluteString] ?: @""]];
        }
        [xml appendString:@"  </bookmarks>\n"];
    }

    // Up Next
    if (upNextSnapshots.count > 0) {
        [xml appendString:@"  <upnext>\n"];
        for (NSDictionary<NSString *, id> *episode in upNextSnapshots) {
            [xml appendFormat:@"    <episode media=\"%@\" guid=\"%@\" feedUrl=\"%@\"/>\n",
                [self xmlEscape:episode[@"media"]],
                [self xmlEscape:episode[@"guid"]],
                [self xmlEscape:episode[@"feedUrl"]]];
        }
        [xml appendString:@"  </upnext>\n"];
    }

    // Now Playing
    if (nowPlayingSnapshot) {
        [xml appendFormat:@"  <nowplaying media=\"%@\" guid=\"%@\" feedUrl=\"%@\" position=\"%d\"/>\n",
            [self xmlEscape:nowPlayingSnapshot[@"media"]],
            [self xmlEscape:nowPlayingSnapshot[@"guid"]],
            [self xmlEscape:nowPlayingSnapshot[@"feedUrl"]],
            [nowPlayingSnapshot[@"position"] intValue]];
    }

    // Apple Watch episode selection
    NSFetchRequest *watchRequest = [[NSFetchRequest alloc] initWithEntityName:@"AppleWatchEpisodeState"];
    watchRequest.predicate = [NSPredicate predicateWithFormat:@"watchStatus == nil OR watchStatus != %@", ICAppleWatchStatusRemoving];
    watchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"watchAddedDate" ascending:NO]];
    watchRequest.fetchBatchSize = ICBackupFetchBatchSize;
    NSArray<AppleWatchEpisodeState *> *watchStates = [context executeFetchRequest:watchRequest error:error];
    if (!watchStates) return nil;
    NSMutableDictionary<NSString*, CDEpisode*>* watchEpisodesByHash = [NSMutableDictionary dictionary];
    NSMutableOrderedSet<NSString*>* watchEpisodeHashes = [NSMutableOrderedSet orderedSet];
    for (AppleWatchEpisodeState* state in watchStates) {
        if (state.episodeHash.length > 0) [watchEpisodeHashes addObject:state.episodeHash];
    }
    NSArray<NSString*>* allWatchEpisodeHashes = watchEpisodeHashes.array;
    for (NSUInteger offset = 0; offset < allWatchEpisodeHashes.count; offset += ICBackupFetchBatchSize) {
        NSArray<NSString*>* hashBatch = [allWatchEpisodeHashes subarrayWithRange:NSMakeRange(offset, MIN(ICBackupFetchBatchSize, allWatchEpisodeHashes.count - offset))];
        NSFetchRequest* episodeRequest = [[NSFetchRequest alloc] initWithEntityName:@"Episode"];
        episodeRequest.predicate = [NSPredicate predicateWithFormat:@"objectHash IN %@", hashBatch];
        episodeRequest.relationshipKeyPathsForPrefetching = @[@"feed", @"media"];
        episodeRequest.fetchBatchSize = ICBackupFetchBatchSize;
        NSArray<CDEpisode*>* watchEpisodes = [context executeFetchRequest:episodeRequest error:error];
        if (!watchEpisodes) return nil;
        for (CDEpisode* episode in watchEpisodes) {
            if (episode.objectHash.length > 0) watchEpisodesByHash[episode.objectHash] = episode;
        }
    }
    BOOL hasAppleWatchEpisodes = NO;
    for (AppleWatchEpisodeState *state in watchStates) {
        if (state.episodeHash.length == 0) continue;
        CDEpisode *episode = watchEpisodesByHash[state.episodeHash];
        if (!episode || episode.video || episode.archived || [episode.preferedMedium.fileURL absoluteString].length == 0) {
            continue;
        }

        if (!hasAppleWatchEpisodes) {
            [xml appendString:@"  <appleWatchEpisodes>\n"];
            hasAppleWatchEpisodes = YES;
        }

        NSString *feedURL = [episode.feed.sourceURL absoluteString] ?: @"";
        NSString *feedIdentifier = state.feedIdentifier ?: feedURL ?: episode.feed.uid ?: @"";
        NSMutableString *attrs = [NSMutableString stringWithFormat:@"episodeHash=\"%@\" guid=\"%@\" feedUrl=\"%@\" feedIdentifier=\"%@\" selectionSource=\"%@\"",
            [self xmlEscape:state.episodeHash ?: episode.objectHash ?: @""],
            [self xmlEscape:episode.guid ?: @""],
            [self xmlEscape:feedURL],
            [self xmlEscape:feedIdentifier],
            [self xmlEscape:state.selectionSource ?: @"manual"]];

        if (state.watchAddedDate) [attrs appendFormat:@" watchAddedDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.watchAddedDate]]];
        if (state.lastPhonePosition > 0) [attrs appendFormat:@" lastPhonePosition=\"%d\"", state.lastPhonePosition];
        if (state.lastPhonePositionDate) [attrs appendFormat:@" lastPhonePositionDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.lastPhonePositionDate]]];
        if (state.lastWatchPosition > 0) [attrs appendFormat:@" lastWatchPosition=\"%d\"", state.lastWatchPosition];
        if (state.lastWatchPositionDate) [attrs appendFormat:@" lastWatchPositionDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.lastWatchPositionDate]]];
        if (state.watchConsumed) [attrs appendString:@" watchConsumed=\"true\""];
        if (state.watchConsumedDate) [attrs appendFormat:@" watchConsumedDate=\"%@\"", [self xmlEscape:[dateFormatter stringFromDate:state.watchConsumedDate]]];

        [xml appendFormat:@"    <episode %@/>\n", attrs];
    }
    if (hasAppleWatchEpisodes) [xml appendString:@"  </appleWatchEpisodes>\n"];

    // Playlists
    NSFetchRequest *playlistsRequest = [[NSFetchRequest alloc] initWithEntityName:@"Playlist"];
    playlistsRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
    playlistsRequest.relationshipKeyPathsForPrefetching = @[
        @"playlistEpisodes",
        @"playlistEpisodes.episode",
        @"playlistEpisodes.episode.feed",
        @"playlistEpisodes.episode.media",
    ];
    playlistsRequest.fetchBatchSize = ICBackupFetchBatchSize;
    NSArray *fetchedPlaylists = [context executeFetchRequest:playlistsRequest error:error];
    if (!fetchedPlaylists) return nil;

    NSFetchRequest *episodeListsRequest = [[NSFetchRequest alloc] initWithEntityName:@"EpisodeList"];
    episodeListsRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]];
    episodeListsRequest.relationshipKeyPathsForPrefetching = @[@"includedFeeds"];
    episodeListsRequest.fetchBatchSize = ICBackupFetchBatchSize;
    NSArray *fetchedEpisodeLists = [context executeFetchRequest:episodeListsRequest error:error];
    if (!fetchedEpisodeLists) return nil;

    NSArray *fetchedLists = [[fetchedPlaylists arrayByAddingObjectsFromArray:fetchedEpisodeLists]
        sortedArrayUsingDescriptors:@[[[NSSortDescriptor alloc] initWithKey:@"rank" ascending:YES]]];
    NSMutableArray *lists = [NSMutableArray array];
    NSMutableSet<NSString *> *seenListUIDs = [NSMutableSet set];
    for (CDList *list in fetchedLists) {
        if (list.uid.length == 0 || [seenListUIDs containsObject:list.uid]) continue;
        [seenListUIDs addObject:list.uid];
        [lists addObject:list];
    }
    BOOL hasPlaylists = NO;
    for (CDList* list in lists) {
        if ([list isKindOfClass:[CDPlaylist class]]) {
            if (!hasPlaylists) {
                [xml appendString:@"  <playlists>\n"];
                hasPlaylists = YES;
            }
            CDPlaylist* playlist = (CDPlaylist*)list;
            [xml appendFormat:@"    <playlist name=\"%@\" rank=\"%d\">\n",
                [self xmlEscape:playlist.name], playlist.rank];
            for (CDEpisode* episode in playlist.sortedEpisodes) {
                CDMedium* medium = [episode preferedMedium];
                [xml appendFormat:@"      <episode media=\"%@\" guid=\"%@\" feedUrl=\"%@\"/>\n",
                    [self xmlEscape:[medium.fileURL absoluteString] ?: @""],
                    [self xmlEscape:episode.guid ?: @""],
                    [self xmlEscape:[episode.feed.sourceURL absoluteString] ?: @""]];
            }
            [xml appendString:@"    </playlist>\n"];
        }
    }
    if (hasPlaylists) [xml appendString:@"  </playlists>\n"];

    // Episode Lists (default filter lists like Unplayed, Favorites, etc.)
    BOOL hasEpisodeLists = NO;
    for (CDList* list in lists) {
        if ([list isKindOfClass:[CDEpisodeList class]]) {
            CDEpisodeList* episodeList = (CDEpisodeList*)list;
            if (!episodeList.uid) continue;
            if (!hasEpisodeLists) {
                [xml appendString:@"  <episodeLists>\n"];
                hasEpisodeLists = YES;
            }
            [xml appendFormat:@"    <episodeList uid=\"%@\" name=\"%@\" icon=\"%@\" rank=\"%d\">\n",
                [self xmlEscape:episodeList.uid],
                [self xmlEscape:episodeList.name ?: @""],
                [self xmlEscape:episodeList.icon ?: @""],
                episodeList.rank];
            [xml appendFormat:@"      <audio>%@</audio>\n", episodeList.audio ? @"true" : @"false"];
            [xml appendFormat:@"      <video>%@</video>\n", episodeList.video ? @"true" : @"false"];
            [xml appendFormat:@"      <downloaded>%@</downloaded>\n", episodeList.downloaded ? @"true" : @"false"];
            [xml appendFormat:@"      <downloading>%@</downloading>\n", episodeList.downloading ? @"true" : @"false"];
            [xml appendFormat:@"      <notDownloaded>%@</notDownloaded>\n", episodeList.notDownloaded ? @"true" : @"false"];
            [xml appendFormat:@"      <unplayed>%@</unplayed>\n", episodeList.unplayed ? @"true" : @"false"];
            [xml appendFormat:@"      <unfinished>%@</unfinished>\n", episodeList.unfinished ? @"true" : @"false"];
            [xml appendFormat:@"      <played>%@</played>\n", episodeList.played ? @"true" : @"false"];
            [xml appendFormat:@"      <starred>%@</starred>\n", episodeList.starred ? @"true" : @"false"];
            [xml appendFormat:@"      <notStarred>%@</notStarred>\n", episodeList.notStarred ? @"true" : @"false"];
            if (episodeList.orderBy) [xml appendFormat:@"      <orderBy>%@</orderBy>\n", [self xmlEscape:episodeList.orderBy]];
            [xml appendFormat:@"      <descending>%@</descending>\n", episodeList.descending ? @"true" : @"false"];
            [xml appendFormat:@"      <groupByPodcast>%@</groupByPodcast>\n", episodeList.groupByPodcast ? @"true" : @"false"];
            [xml appendFormat:@"      <continuousPlayback>%@</continuousPlayback>\n", episodeList.continuousPlayback ? @"true" : @"false"];
            if (episodeList.includedFeeds.count > 0) {
                [xml appendString:@"      <includedFeeds>\n"];
                for (CDFeed* feed in episodeList.includedFeeds) {
                    [xml appendFormat:@"        <feedUrl>%@</feedUrl>\n", [self xmlEscape:[feed.sourceURL absoluteString] ?: @""]];
                }
                [xml appendString:@"      </includedFeeds>\n"];
            }
            [xml appendString:@"    </episodeList>\n"];
        }
    }
    if (hasEpisodeLists) [xml appendString:@"  </episodeLists>\n"];

    // Settings
    NSUserDefaults* defaults = USER_DEFAULTS;
    [xml appendString:@"  <settings>\n"];
    // Playback
    if ([defaults objectForKey:DefaultPlaybackSpeed]) [xml appendFormat:@"    <playbackSpeed>%ld</playbackSpeed>\n", (long)[defaults integerForKey:DefaultPlaybackSpeed]];
    if ([defaults objectForKey:PlayerSkipBackPeriod]) [xml appendFormat:@"    <skipBack>%ld</skipBack>\n", (long)[defaults integerForKey:PlayerSkipBackPeriod]];
    if ([defaults objectForKey:PlayerSkipForwardPeriod]) [xml appendFormat:@"    <skipForward>%ld</skipForward>\n", (long)[defaults integerForKey:PlayerSkipForwardPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipStartPeriod]) [xml appendFormat:@"    <autoSkipStart>%ld</autoSkipStart>\n", (long)[defaults integerForKey:PlayerAutoSkipStartPeriod]];
    if ([defaults objectForKey:PlayerAutoSkipEndPeriod]) [xml appendFormat:@"    <autoSkipEnd>%ld</autoSkipEnd>\n", (long)[defaults integerForKey:PlayerAutoSkipEndPeriod]];
    if ([defaults objectForKey:PlayerReplayAfterPause]) [xml appendFormat:@"    <replayAfterPause>%ld</replayAfterPause>\n", (long)[defaults integerForKey:PlayerReplayAfterPause]];
    if ([defaults objectForKey:kDefaultPlayerControls]) [xml appendFormat:@"    <playerControls>%ld</playerControls>\n", (long)[defaults integerForKey:kDefaultPlayerControls]];
    if ([defaults objectForKey:kDefaultDontDeleteUpNextWhenChangingEpisode]) [xml appendFormat:@"    <dontDeleteUpNext>%@</dontDeleteUpNext>\n", [defaults boolForKey:kDefaultDontDeleteUpNextWhenChangingEpisode] ? @"true" : @"false"];
    if ([defaults objectForKey:ContinuousPlayFromFeed]) [xml appendFormat:@"    <continuousPlay>%@</continuousPlay>\n", [defaults boolForKey:ContinuousPlayFromFeed] ? @"true" : @"false"];
    if ([defaults objectForKey:DefaultIntelligentSleepTimer]) [xml appendFormat:@"    <defaultSleepTimer>%ld</defaultSleepTimer>\n", (long)[defaults integerForKey:DefaultIntelligentSleepTimer]];
    // Downloads
    if ([defaults objectForKey:AutoCacheNewAudioEpisodes]) [xml appendFormat:@"    <autoCacheAudio>%@</autoCacheAudio>\n", [defaults boolForKey:AutoCacheNewAudioEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoCacheNewVideoEpisodes]) [xml appendFormat:@"    <autoCacheVideo>%@</autoCacheVideo>\n", [defaults boolForKey:AutoCacheNewVideoEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteAfterFinishedPlaying]) [xml appendFormat:@"    <autoDeletePlayed>%@</autoDeletePlayed>\n", [defaults boolForKey:AutoDeleteAfterFinishedPlaying] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteAfterMarkedAsPlayed]) [xml appendFormat:@"    <autoDeleteMarkedPlayed>%@</autoDeleteMarkedPlayed>\n", [defaults boolForKey:AutoDeleteAfterMarkedAsPlayed] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoDeleteNewsMode]) [xml appendFormat:@"    <autoDeleteNews>%@</autoDeleteNews>\n", [defaults boolForKey:AutoDeleteNewsMode] ? @"true" : @"false"];
    if ([defaults objectForKey:PodcastRefreshOnAppStart]) [xml appendFormat:@"    <podcastRefreshOnAppStart>%@</podcastRefreshOnAppStart>\n", [defaults boolForKey:PodcastRefreshOnAppStart] ? @"true" : @"false"];
    if ([defaults objectForKey:AutoCacheStorageLimit]) [xml appendFormat:@"    <autoCacheStorageLimit>%ld</autoCacheStorageLimit>\n", (long)[defaults integerForKey:AutoCacheStorageLimit]];
    if ([defaults objectForKey:AutoDownloadWhileStreaming]) [xml appendFormat:@"    <autoDownloadWhileStreaming>%@</autoDownloadWhileStreaming>\n", [defaults boolForKey:AutoDownloadWhileStreaming] ? @"true" : @"false"];
    // Cellular
    if ([defaults objectForKey:EnableCachingOver3G]) [xml appendFormat:@"    <enableCachingOver3G>%@</enableCachingOver3G>\n", [defaults boolForKey:EnableCachingOver3G] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableRefreshingOver3G]) [xml appendFormat:@"    <enableRefreshingOver3G>%@</enableRefreshingOver3G>\n", [defaults boolForKey:EnableRefreshingOver3G] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableStreamingOver3G]) [xml appendFormat:@"    <enableStreamingOver3G>%@</enableStreamingOver3G>\n", [defaults boolForKey:EnableStreamingOver3G] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableCachingImagesOver3G]) [xml appendFormat:@"    <enableCachingImagesOver3G>%@</enableCachingImagesOver3G>\n", [defaults boolForKey:EnableCachingImagesOver3G] ? @"true" : @"false"];
    // General
    if ([defaults objectForKey:DisableAutoLock]) [xml appendFormat:@"    <disableAutoLock>%@</disableAutoLock>\n", [defaults boolForKey:DisableAutoLock] ? @"true" : @"false"];
    if ([defaults objectForKey:UISoundEnabled]) [xml appendFormat:@"    <uiSoundEnabled>%@</uiSoundEnabled>\n", [defaults boolForKey:UISoundEnabled] ? @"true" : @"false"];
    if ([defaults objectForKey:UIHapticsEnabled]) [xml appendFormat:@"    <uiHapticsEnabled>%@</uiHapticsEnabled>\n", [defaults boolForKey:UIHapticsEnabled] ? @"true" : @"false"];
    if ([defaults objectForKey:ShowApplicationBadgeForUnseen]) [xml appendFormat:@"    <showBadge>%@</showBadge>\n", [defaults boolForKey:ShowApplicationBadgeForUnseen] ? @"true" : @"false"];
    if ([defaults objectForKey:kDefaultShowUnavailableEpisodes]) [xml appendFormat:@"    <showUnavailable>%@</showUnavailable>\n", [defaults boolForKey:kDefaultShowUnavailableEpisodes] ? @"true" : @"false"];
    if ([defaults objectForKey:OpenLinksInExternalBrowser]) [xml appendFormat:@"    <openLinksExternal>%@</openLinksExternal>\n", [defaults boolForKey:OpenLinksInExternalBrowser] ? @"true" : @"false"];
    if ([defaults objectForKey:AllowSendingDiagnostics]) [xml appendFormat:@"    <allowDiagnostics>%ld</allowDiagnostics>\n", (long)[defaults integerForKey:AllowSendingDiagnostics]];
    if ([defaults objectForKey:AmazonAffiliateEnabled]) [xml appendFormat:@"    <amazonAffiliateEnabled>%@</amazonAffiliateEnabled>\n", [defaults boolForKey:AmazonAffiliateEnabled] ? @"true" : @"false"];
    // Notifications
    if ([defaults objectForKey:EnableNewEpisodeNotification]) [xml appendFormat:@"    <notifyNewEpisode>%@</notifyNewEpisode>\n", [defaults boolForKey:EnableNewEpisodeNotification] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableManualRefreshFinishedNotification]) [xml appendFormat:@"    <notifyRefreshFinished>%@</notifyRefreshFinished>\n", [defaults boolForKey:EnableManualRefreshFinishedNotification] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableRefreshFailureNotification]) [xml appendFormat:@"    <notifyRefreshFailure>%@</notifyRefreshFailure>\n", [defaults boolForKey:EnableRefreshFailureNotification] ? @"true" : @"false"];
    if ([defaults objectForKey:EnableManualDownloadFinishedNotification]) [xml appendFormat:@"    <notifyDownloadFinished>%@</notifyDownloadFinished>\n", [defaults boolForKey:EnableManualDownloadFinishedNotification] ? @"true" : @"false"];
    // Appearance
    if ([defaults objectForKey:kDefaultAppearanceMode]) [xml appendFormat:@"    <appearanceMode>%ld</appearanceMode>\n", (long)[defaults integerForKey:kDefaultAppearanceMode]];
    if ([defaults objectForKey:InterfaceThemeDefaultActive]) [xml appendFormat:@"    <themeDefaultActive>%@</themeDefaultActive>\n", [defaults boolForKey:InterfaceThemeDefaultActive] ? @"true" : @"false"];
    NSString *interfaceColorHex = [self _hexColorForDefaults:defaults hexKey:InterfaceThemeColorHexCode colorDataKey:InterfaceThemeColorCode];
    if (interfaceColorHex.length > 0) [xml appendFormat:@"    <themeColorHex>%@</themeColorHex>\n", [self xmlEscape:interfaceColorHex]];
    if ([defaults objectForKey:PlayerColorPerPodcastActive]) [xml appendFormat:@"    <playerPerPodcastColor>%@</playerPerPodcastColor>\n", [defaults boolForKey:PlayerColorPerPodcastActive] ? @"true" : @"false"];
    NSString *playerColorHex = [self _hexColorForDefaults:defaults hexKey:PlayerThemeColorHexCode colorDataKey:PlayerThemeColorCode];
    if (playerColorHex.length > 0) [xml appendFormat:@"    <playerColorHex>%@</playerColorHex>\n", [self xmlEscape:playerColorHex]];
    if ([defaults objectForKey:WidgetThemeDefaultActive]) [xml appendFormat:@"    <widgetThemeDefaultActive>%@</widgetThemeDefaultActive>\n", [defaults boolForKey:WidgetThemeDefaultActive] ? @"true" : @"false"];
    NSString *widgetColorHex = [self _hexColorForDefaults:defaults hexKey:WidgetThemeColorHexCode colorDataKey:WidgetThemeColorCode];
    if (widgetColorHex.length > 0) [xml appendFormat:@"    <widgetColorHex>%@</widgetColorHex>\n", [self xmlEscape:widgetColorHex]];
    if ([defaults objectForKey:kDefaultTranscriptHighlightStyle]) [xml appendFormat:@"    <transcriptHighlightStyle>%ld</transcriptHighlightStyle>\n", (long)[defaults integerForKey:kDefaultTranscriptHighlightStyle]];
    // Sleep Timer
    if ([defaults objectForKey:ScreenTimerAlwaysActive]) [xml appendFormat:@"    <sleepTimerAlways>%@</sleepTimerAlways>\n", [defaults boolForKey:ScreenTimerAlwaysActive] ? @"true" : @"false"];
    if ([defaults objectForKey:IntelligentSleepTimerAlwaysActive]) [xml appendFormat:@"    <intelligentSleepAlways>%@</intelligentSleepAlways>\n", [defaults boolForKey:IntelligentSleepTimerAlwaysActive] ? @"true" : @"false"];
    if ([defaults objectForKey:DisableSleepTimerInCarPlay]) [xml appendFormat:@"    <disableSleepTimerCarPlay>%@</disableSleepTimerCarPlay>\n", [defaults boolForKey:DisableSleepTimerInCarPlay] ? @"true" : @"false"];
    if ([defaults objectForKey:LastSelectedSleepTimer]) [xml appendFormat:@"    <lastSleepTimer>%ld</lastSleepTimer>\n", (long)[defaults integerForKey:LastSelectedSleepTimer]];
    // Sleep Timer Motion/Touch/Volume Detection
    if ([defaults objectForKey:DeviceMovementIntelligentSleep]) [xml appendFormat:@"    <deviceMovementIntelligentSleep>%@</deviceMovementIntelligentSleep>\n", [defaults boolForKey:DeviceMovementIntelligentSleep] ? @"true" : @"false"];
    if ([defaults objectForKey:DeviceMovementSensitivity]) [xml appendFormat:@"    <deviceMovementSensitivity>%.3f</deviceMovementSensitivity>\n", [defaults doubleForKey:DeviceMovementSensitivity]];
    if ([defaults objectForKey:ScreenTouchIntelligentSleep]) [xml appendFormat:@"    <screenTouchIntelligentSleep>%@</screenTouchIntelligentSleep>\n", [defaults boolForKey:ScreenTouchIntelligentSleep] ? @"true" : @"false"];
    if ([defaults objectForKey:VolumeChangeIntelligentSleep]) [xml appendFormat:@"    <volumeChangeIntelligentSleep>%@</volumeChangeIntelligentSleep>\n", [defaults boolForKey:VolumeChangeIntelligentSleep] ? @"true" : @"false"];
    // App Icon
    if (alternateIconName) {
        [xml appendFormat:@"    <appIcon>%@</appIcon>\n", [self xmlEscape:alternateIconName]];
    }
    // SmartHome
    if ([defaults objectForKey:SmarthomeMQTTEnabled]) [xml appendFormat:@"    <smarthomeMQTTEnabled>%@</smarthomeMQTTEnabled>\n", [defaults boolForKey:SmarthomeMQTTEnabled] ? @"true" : @"false"];
    if ([defaults objectForKey:SmarthomeMQTTHost]) [xml appendFormat:@"    <smarthomeMQTTHost>%@</smarthomeMQTTHost>\n", [self xmlEscape:[defaults stringForKey:SmarthomeMQTTHost]]];
    if ([defaults objectForKey:SmarthomeMQTTPort]) [xml appendFormat:@"    <smarthomeMQTTPort>%ld</smarthomeMQTTPort>\n", (long)[defaults integerForKey:SmarthomeMQTTPort]];
    if ([defaults objectForKey:SmarthomeMQTTUsername]) [xml appendFormat:@"    <smarthomeMQTTUsername>%@</smarthomeMQTTUsername>\n", [self xmlEscape:[defaults stringForKey:SmarthomeMQTTUsername]]];
    if ([defaults objectForKey:SmarthomeMQTTPassword]) [xml appendFormat:@"    <smarthomeMQTTPassword>%@</smarthomeMQTTPassword>\n", [self xmlEscape:[defaults stringForKey:SmarthomeMQTTPassword]]];
    if ([defaults objectForKey:SmarthomeAllowControl]) [xml appendFormat:@"    <smarthomeAllowControl>%@</smarthomeAllowControl>\n", [defaults boolForKey:SmarthomeAllowControl] ? @"true" : @"false"];
    if ([defaults objectForKey:SmarthomeWiFiOnly]) [xml appendFormat:@"    <smarthomeWiFiOnly>%@</smarthomeWiFiOnly>\n", [defaults boolForKey:SmarthomeWiFiOnly] ? @"true" : @"false"];
    if ([defaults objectForKey:SmarthomeDeviceName]) [xml appendFormat:@"    <smarthomeDeviceName>%@</smarthomeDeviceName>\n", [self xmlEscape:[defaults stringForKey:SmarthomeDeviceName]]];
    // MainMenuListUIDs
    NSArray* mainMenuUIDs = [defaults objectForKey:@"MainMenuListUIDs"];
    if (mainMenuUIDs.count > 0) {
        [xml appendString:@"    <mainMenuListUIDs>\n"];
        for (NSString* uid in mainMenuUIDs) {
            [xml appendFormat:@"      <uid>%@</uid>\n", [self xmlEscape:uid]];
        }
        [xml appendString:@"    </mainMenuListUIDs>\n"];
    }
    // Sort order
    if ([defaults objectForKey:FeedListSortMode]) [xml appendFormat:@"    <feedListSortMode>%@</feedListSortMode>\n", [self xmlEscape:[defaults stringForKey:FeedListSortMode]]];
    if ([defaults objectForKey:FeedSortOrder]) [xml appendFormat:@"    <feedSortOrder>%@</feedSortOrder>\n", [self xmlEscape:[defaults stringForKey:FeedSortOrder]]];
    if ([defaults objectForKey:SelectedAppLanguage]) [xml appendFormat:@"    <selectedAppLanguage>%@</selectedAppLanguage>\n", [self xmlEscape:[defaults stringForKey:SelectedAppLanguage]]];
    // Swipe Actions
    if ([defaults objectForKey:EpisodeSwipeRightAction]) [xml appendFormat:@"    <episodeSwipeRightAction>%ld</episodeSwipeRightAction>\n", (long)[defaults integerForKey:EpisodeSwipeRightAction]];
    if ([defaults objectForKey:EpisodeSwipeLeftAction]) [xml appendFormat:@"    <episodeSwipeLeftAction>%ld</episodeSwipeLeftAction>\n", (long)[defaults integerForKey:EpisodeSwipeLeftAction]];
    if ([defaults objectForKey:AppleWatchSendLatestCount]) [xml appendFormat:@"    <appleWatchSendLatestCount>%ld</appleWatchSendLatestCount>\n", (long)[defaults integerForKey:AppleWatchSendLatestCount]];
    if ([defaults objectForKey:AppleWatchOnlyUnplayed]) [xml appendFormat:@"    <appleWatchOnlyUnplayed>%@</appleWatchOnlyUnplayed>\n", [defaults boolForKey:AppleWatchOnlyUnplayed] ? @"true" : @"false"];
    if ([defaults objectForKey:ICiCloudSyncEpisodesEnabled]) [xml appendFormat:@"    <iCloudSyncEpisodes>%@</iCloudSyncEpisodes>\n", [defaults boolForKey:ICiCloudSyncEpisodesEnabled] ? @"true" : @"false"];
    if ([defaults objectForKey:ICiCloudSyncSubscriptionsEnabled]) [xml appendFormat:@"    <iCloudSyncSubscriptions>%@</iCloudSyncSubscriptions>\n", [defaults boolForKey:ICiCloudSyncSubscriptionsEnabled] ? @"true" : @"false"];
    if ([defaults objectForKey:ICiCloudSyncSettingsEnabled]) [xml appendFormat:@"    <iCloudSyncSettings>%@</iCloudSyncSettings>\n", [defaults boolForKey:ICiCloudSyncSettingsEnabled] ? @"true" : @"false"];
    // Display
    if ([defaults objectForKey:kDefaultDarkModePureBlack]) [xml appendFormat:@"    <darkModePureBlack>%@</darkModePureBlack>\n", [defaults boolForKey:kDefaultDarkModePureBlack] ? @"true" : @"false"];
    if ([defaults objectForKey:kDefaultFontSizeLarger]) [xml appendFormat:@"    <fontSizeLarger>%ld</fontSizeLarger>\n", (long)[defaults integerForKey:kDefaultFontSizeLarger]];
    if ([defaults objectForKey:TapOnEpisodeAction]) [xml appendFormat:@"    <tapOnEpisodeAction>%ld</tapOnEpisodeAction>\n", (long)[defaults integerForKey:TapOnEpisodeAction]];
    if ([defaults objectForKey:@"MediaFilesSortMode"]) [xml appendFormat:@"    <mediaFilesSortMode>%ld</mediaFilesSortMode>\n", (long)[defaults integerForKey:@"MediaFilesSortMode"]];
    // Transcription & Chapters
    if ([defaults objectForKey:kTranscriptionEngine]) [xml appendFormat:@"    <transcriptionEngine>%@</transcriptionEngine>\n", [self xmlEscape:[defaults stringForKey:kTranscriptionEngine]]];
    if ([defaults objectForKey:kTranscriptionWhisperModel]) [xml appendFormat:@"    <transcriptionWhisperModel>%@</transcriptionWhisperModel>\n", [self xmlEscape:[defaults stringForKey:kTranscriptionWhisperModel]]];
    if ([defaults objectForKey:@"ChapterGenerationModel"]) [xml appendFormat:@"    <chapterGenerationModel>%@</chapterGenerationModel>\n", [self xmlEscape:[defaults stringForKey:@"ChapterGenerationModel"]]];
    if ([defaults objectForKey:kTranscriptionAutoDefault]) [xml appendFormat:@"    <transcriptionAutoDefault>%@</transcriptionAutoDefault>\n", [defaults boolForKey:kTranscriptionAutoDefault] ? @"true" : @"false"];
    if ([defaults objectForKey:kChapterAutoDefault]) [xml appendFormat:@"    <chapterAutoDefault>%@</chapterAutoDefault>\n", [defaults boolForKey:kChapterAutoDefault] ? @"true" : @"false"];
    if ([defaults objectForKey:kAutoSkipSponsors]) [xml appendFormat:@"    <autoSkipSponsors>%@</autoSkipSponsors>\n", [defaults boolForKey:kAutoSkipSponsors] ? @"true" : @"false"];
    if ([defaults objectForKey:kTranscriptionEverActivated]) [xml appendFormat:@"    <transcriptionEverActivated>%@</transcriptionEverActivated>\n", [defaults boolForKey:kTranscriptionEverActivated] ? @"true" : @"false"];
    if ([defaults objectForKey:kTranscriptionFirstRunShown]) [xml appendFormat:@"    <transcriptionFirstRunShown>%@</transcriptionFirstRunShown>\n", [defaults boolForKey:kTranscriptionFirstRunShown] ? @"true" : @"false"];
    if ([defaults objectForKey:@"TranscriptVisiblePreference"]) [xml appendFormat:@"    <transcriptVisiblePreference>%@</transcriptVisiblePreference>\n", [defaults boolForKey:@"TranscriptVisiblePreference"] ? @"true" : @"false"];
    NSArray *credentialKeys = @[@"openAIAPIKey", @"anthropicAPIKey", @"kimiAPIKey", @"openAIOAuthAccessToken", @"openAIOAuthRefreshToken", @"openAIOAuthIDToken", @"openAIOAuthAccountID", @"openAIOAuthAccountEmail", @"openAIOAuthFedRAMP"];
    for (NSString *key in credentialKeys) {
        NSString *value = credentialValues[key];
        if ([value isKindOfClass:[NSString class]] && value.length > 0) {
            [xml appendFormat:@"    <%@>%@</%@>\n", key, [self xmlEscape:value], key];
        }
    }
    // Enabled Playback Speeds
    if ([defaults objectForKey:EnabledPlaybackSpeedsKey]) {
        NSArray* speeds = [defaults objectForKey:EnabledPlaybackSpeedsKey];
        [xml appendString:@"    <enabledPlaybackSpeeds>\n"];
        for (NSNumber* speed in speeds) {
            [xml appendFormat:@"      <speed>%ld</speed>\n", (long)[speed integerValue]];
        }
        [xml appendString:@"    </enabledPlaybackSpeeds>\n"];
    }
    if ([defaults objectForKey:@"ManualFeedOrder"]) {
        NSArray* manualOrder = [defaults objectForKey:@"ManualFeedOrder"];
        [xml appendString:@"    <manualFeedOrder>\n"];
        for (NSString* url in manualOrder) {
            [xml appendFormat:@"      <feedUrl>%@</feedUrl>\n", [self xmlEscape:url]];
        }
        [xml appendString:@"    </manualFeedOrder>\n"];
    }
    [xml appendString:@"  </settings>\n"];

    [xml appendString:@"</instacast>\n"];

    // Write file
    NSData* data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSString* fileName = [NSString stringWithFormat:@"Instacast-Backup-%@.xml", deviceName];
    NSString* documentsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSURL* url = [NSURL fileURLWithPath:[documentsDir stringByAppendingPathComponent:fileName]];

    if (![data writeToURL:url options:NSDataWritingAtomic error:error]) return nil;
    return url;
}

#pragma mark - Import

- (void) showImportDocumentPicker
{
    NSArray *documentTypes;
    if (self.selectedImportRow == 0) {
        documentTypes = @[@"public.xml"];
    } else {
        documentTypes = @[@"public.xml", @"org.opml.opml", @"instacast.opml"];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initWithDocumentTypes:documentTypes inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.shouldShowFileExtensions = YES;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSURL *url = urls.firstObject;
    if (!url) return;

    [self importFileFromURL:url];
}

- (void)importFileFromURL:(NSURL *)url
{
    if (self.importInProgress) return;
    self.importInProgress = YES;

    self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Analyzing backup…".ls];
    [self.mInfo showInWindow:self.view.window];
    NSInteger selectedImportRow = self.selectedImportRow;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError* readError = nil;
        NSData *data = [ICXMLImportLimits readDataFromURL:url error:&readError];

        if (!data || data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError* importError = readError ?: [NSError errorWithDomain:@"Import"
                                                                          code:1
                                                                      userInfo:@{NSLocalizedDescriptionKey: @"The selected file is empty.".ls}];
                [self _finishImportWithError:importError];
            });
            return;
        }

        BOOL isInstacastBackup = [InstacastBackupParser isInstacastBackupData:data];
        if (selectedImportRow == 0 && !isInstacastBackup) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError* formatError = [NSError errorWithDomain:@"Import"
                                                            code:2
                                                        userInfo:@{NSLocalizedDescriptionKey: @"This XML file is not an InstacastPlus backup.".ls}];
                [self _finishImportWithError:formatError];
            });
            return;
        }
        if (selectedImportRow == 1 && isInstacastBackup) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError* formatError = [NSError errorWithDomain:@"Import"
                                                            code:3
                                                        userInfo:@{NSLocalizedDescriptionKey: @"This file is an InstacastPlus backup. Choose All InstacastPlus Data to import it.".ls}];
                [self _finishImportWithError:formatError];
            });
            return;
        }

        if (isInstacastBackup) {
            [self importInstacastBackupFromData:data];
        } else {
            [self importOPMLFromData:data];
        }
    });
}

- (void)_finishImportWithError:(NSError*)error
{
    NSAssert([NSThread isMainThread], @"Import UI completion must run on the main thread");
    [self.mInfo close];
    self.mInfo = nil;
    self.importInProgress = NO;
    if (!error) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Import Error".ls
                                                                   message:error.localizedDescription ?: @"Could not parse backup file.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importInstacastBackupFromData:(NSData *)data
{
    [InstacastBackupParser parseData:data completion:^(InstacastBackupData *backupData, NSError *error) {
        if (error || !backupData) {
            [self _finishImportWithError:error ?: [NSError errorWithDomain:@"Import" code:4 userInfo:nil]];
            return;
        }

        [self _finishImportWithError:nil];
        InstacastBackupImportViewController *importVC = [InstacastBackupImportViewController viewControllerWithBackupData:backupData];
        [self.navigationController pushViewController:importVC animated:YES];
    }];
}

- (void)importOPMLFromData:(NSData *)data
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.mInfo close];
        self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Importing\u2026".ls];
        [self.mInfo showInWindow:self.view.window];

        [[SubscriptionManager sharedSubscriptionManager] importOPMLData:data completion:^(NSError* error) {
            [self _finishImportWithError:error];
        } progress:^(float progress) {
            if (progress > 0.03) {
                [self.mInfo setProgress:progress];
            }
        }];
    });
}

#pragma mark - UIDocumentInteractionControllerDelegate

- (void) documentInteractionControllerDidDismissOpenInMenu:(UIDocumentInteractionController *)controller
{
    self.interactionController = nil;
    [self presentPendingFullExportResultIfNeeded];
    [self presentPendingSubscriptionsExportResultIfNeeded];
    [self presentPendingBookmarksExportResultIfNeeded];
}


#pragma mark - Reset App

- (void) resetApp
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Reset App".ls
                                                                   message:@"Are you sure you want to delete all data and reset the app? This action cannot be undone.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel".ls
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Reset".ls
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * action) {
        [self performAppReset];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void) performAppReset
{
    self.mInfo = [VDModalInfo modalInfoWithProgressLabel:@"Resetting…".ls];
    [self.mInfo showInWindow:self.view.window];

    [[CacheManager sharedCacheManager] cancelDownloadsAndClearCacheWithCompletion:^(NSError *cacheError) {
        if (cacheError) {
            [self _showResetError:cacheError];
            return;
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BOOL clearedImages = [[ImageCacheManager sharedImageCacheManager] cancelImageDownloadsAndClearCache];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!clearedImages) {
                    NSError *imageError = [NSError errorWithDomain:@"AppReset"
                                                              code:1
                                                          userInfo:@{NSLocalizedDescriptionKey: @"Cached images could not be deleted. No local database data was reset.".ls}];
                    [self _showResetError:imageError];
                    return;
                }

                [[ICiCloudSyncManager sharedManager] prepareForLocalAppResetWithCompletion:^(NSError *syncError) {
                    if (syncError) {
                        [self _showResetError:syncError];
                        return;
                    }

                    [DMANAGER resetAllUserDataWithCompletion:^(NSError *databaseError) {
                        if (databaseError) {
                            BOOL canRecoverSync = [databaseError.domain isEqualToString:@"DatabaseManager"] &&
                                (databaseError.code == 30 || databaseError.code == 32);
                            if (canRecoverSync) {
                                [[ICiCloudSyncManager sharedManager] recoverAfterLocalAppResetFailure:databaseError];
                            }
                            [self _showResetError:databaseError];
                            return;
                        }

                        [[ICiCloudSyncManager sharedManager] completeLocalAppReset];
                        NSString *appDomain = [[NSBundle mainBundle] bundleIdentifier];
                        [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:appDomain];
                        [[NSUserDefaults standardUserDefaults] synchronize];

                        [self.mInfo close];
                        self.mInfo = nil;

                        // Reset app icon if needed, then show confirmation
                        if ([UIApplication sharedApplication].alternateIconName != nil) {
                            [[UIApplication sharedApplication] setAlternateIconName:nil completionHandler:^(NSError * _Nullable error) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (error) {
                                        [self _showResetError:error];
                                    } else {
                                        [self _showResetCompleteAlert];
                                    }
                                });
                            }];
                        } else {
                            [self _showResetCompleteAlert];
                        }
                    }];
                }];
            });
        });
    }];
}

- (void)_showResetError:(NSError *)error
{
    [self.mInfo close];
    self.mInfo = nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Failed".ls
                                                                   message:error.localizedDescription ?: @"The app could not be reset. No success was reported.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)_showResetCompleteAlert
{
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Reset Complete".ls
                                                                   message:@"Please restart the app.".ls
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK".ls
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
