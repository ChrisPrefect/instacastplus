// Test-only driver: exercises real navigation and reports rendered UIKit geometry.
// No production methods are replaced and no device geometry is simulated.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <CoreData/CoreData.h>

@interface NSObject (AdaptiveLayoutProductionAPI)
+ (id)sharedDatabaseManager;
+ (id)playbackViewControllerWithEpisode:(id)episode;
- (void)presentFromParentViewController:(UIViewController*)parent autostart:(BOOL)autostart completion:(void(^)(void))completion;
- (void)save;
- (void)showShowNotesOfEpisode:(id)episode animated:(BOOL)animated;
- (NSInteger)settingsRowForIndexPath:(NSIndexPath*)indexPath;
- (void)_pushShowNotesOfEpisode:(id)episode animated:(BOOL)animated inAppearanceTransition:(BOOL)transition;
+ (id)sharedAudioSession;
- (void)appendToUpNext:(NSArray *)episodes;
- (void)playNow:(id)sender;
@end

static NSString *directory;
static id fixtureEpisode;
static BOOL captureGlyphs;
static UIViewController *mainController(void) {
    return [(id)UIApplication.sharedApplication.delegate valueForKey:@"mainViewController"];
}
static UIWindow *window(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in scene.windows) if (candidate.isKeyWindow) return candidate;
    }
    return mainController().view.window;
}
static NSArray *rect(CGRect r) { return @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)]; }
static NSArray *insets(UIEdgeInsets i) { return @[@(i.top), @(i.left), @(i.bottom), @(i.right)]; }
static NSArray *alphaSize(UIImage *image, NSString *name) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat new];
    format.scale = 4;
    format.opaque = NO;
    UIImage *raster = [[[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawAtPoint:CGPointZero];
    }];
    if (captureGlyphs) [UIImagePNGRepresentation(raster) writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingString:@".png"]] atomically:YES];
    size_t width = CGImageGetWidth(raster.CGImage), height = CGImageGetHeight(raster.CGImage);
    uint8_t *pixels = calloc(width * height, 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), raster.CGImage);
    size_t minX = width, minY = height, maxX = 0, maxY = 0;
    for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
        if (pixels[(y * width + x) * 4 + 3] < 128) continue;
        minX = MIN(minX, x); maxX = MAX(maxX, x);
        minY = MIN(minY, y); maxY = MAX(maxY, y);
    }
    CGContextRelease(context); CGColorSpaceRelease(space); free(pixels);
    return minX <= maxX ? @[@((maxX - minX + 1) / 4.0), @((maxY - minY + 1) / 4.0)] : @[@0, @0];
}
static void views(UIView *view, NSMutableArray *result) {
    if (view.hidden || view.alpha < .01) return;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (id)view;
        if (label.text.length) [result addObject:@{@"text": label.text, @"frame": rect([view convertRect:view.bounds toView:window()])}];
    }
    for (UIView *child in view.subviews) views(child, result);
}
static void controllers(UIViewController *vc, NSMutableArray *result) {
    if (!vc) return;
    NSMutableDictionary *entry = [@{@"class": NSStringFromClass(vc.class), @"title": vc.title ?: @"",
        @"frame": rect([vc.view convertRect:vc.view.bounds toView:window()]), @"safeArea": insets(vc.view.safeAreaInsets),
        @"orientations": @([vc supportedInterfaceOrientations])} mutableCopy];
    if ([vc isKindOfClass:UITableViewController.class]) {
        UITableView *table = ((UITableViewController*)vc).tableView;
        NSMutableArray *rows = [NSMutableArray array];
        for (NSInteger s = 0; s < table.numberOfSections; s++) {
            for (NSInteger r = 0; r < [table numberOfRowsInSection:s]; r++) {
                NSIndexPath *path = [NSIndexPath indexPathForRow:r inSection:s];
                UITableViewCell *cell = [table cellForRowAtIndexPath:path];
                CGRect frame = [table convertRect:[table rectForRowAtIndexPath:path] toView:window()];
                NSMutableDictionary *rowState = [@{@"section": @(s), @"row": @(r), @"title": cell.textLabel.text ?: @"", @"frame": rect(frame)} mutableCopy];
                if (cell) {
                    rowState[@"cellClass"] = NSStringFromClass(cell.class);
                    NSMutableArray *visuals = [NSMutableArray array];
                    for (NSString *key in @[@"titleLabel", @"textLabel", @"detailTextLabel", @"numberLabel", @"numLabel", @"timeLabel", @"dateLabel", @"playAccessoryButton", @"linkButton"]) {
                        if (![cell respondsToSelector:NSSelectorFromString(key)]) continue;
                        UIView *visual = [cell valueForKey:key];
                        if (!visual || visual.hidden || visual.alpha < .01) continue;
                        if ([visual isKindOfClass:UILabel.class] && !((UILabel *)visual).text.length) continue;
                        [visuals addObject:@{@"key": key, @"frame": rect([visual convertRect:visual.bounds toView:window()])}];
                    }
                    rowState[@"visuals"] = visuals;
                }
                if (cell && [vc isKindOfClass:NSClassFromString(@"MainSidebarController")]) {
                    CGPoint point = CGPointMake(120, CGRectGetMidY(frame));
                    UIView *hit = [window() hitTest:point withEvent:nil];
                    rowState[@"hitInCell"] = @(hit == cell || [hit isDescendantOfView:cell]);
                    rowState[@"hitClass"] = hit ? NSStringFromClass(hit.class) : @"";
                }
                [rows addObject:rowState];
            }
        }
        entry[@"rows"] = rows;
        entry[@"scrollEnabled"] = @(table.scrollEnabled);
        entry[@"contentInset"] = insets(table.contentInset);
        entry[@"adjustedInset"] = insets(table.adjustedContentInset);
        entry[@"offset"] = @[@(table.contentOffset.x), @(table.contentOffset.y)];
        entry[@"contentHeight"] = @(table.contentSize.height);
    }
    if ([vc isKindOfClass:NSClassFromString(@"PlaybackControlsViewController")]) {
        UIView *tools = [vc valueForKey:@"toolsView"];
        NSMutableArray *buttons = [NSMutableArray array];
        for (UIView *button in tools.subviews) {
            if (!button.hidden) [buttons addObject:@{@"class": NSStringFromClass(button.class),
                @"frame": rect([button convertRect:button.bounds toView:window()])}];
        }
        entry[@"tools"] = buttons;
        NSMutableArray *playerGlyphs = [NSMutableArray array];
        NSMutableArray *glyphButtons = [NSMutableArray array];
        for (NSString *key in @[@"backButton", @"forwardButton", @"playButton", @"volumeMinButton", @"volumeMaxButton", @"bookmarkButton", @"transcriptButton"]) {
            UIButton *button = [vc valueForKey:key];
            if (button && !button.hidden) [glyphButtons addObject:@{@"key":key, @"button":button}];
        }
        for (UIButton *button in tools.subviews) {
            if ([button isKindOfClass:NSClassFromString(@"PlayerTimerButton")] || [button isKindOfClass:NSClassFromString(@"PlayerSpeedButton")])
                [glyphButtons addObject:@{@"key":NSStringFromClass(button.class), @"button":button}];
        }
        for (NSDictionary *item in glyphButtons) {
            UIButton *button = item[@"button"]; NSString *key = item[@"key"];
            UIImageView *view = button.imageView; UIImage *source = view.image;
            if (!source) continue;
            CGSize rendered = view.bounds.size;
            if (view.contentMode == UIViewContentModeScaleAspectFit || view.contentMode == UIViewContentModeScaleAspectFill) {
                CGFloat sx = rendered.width / source.size.width, sy = rendered.height / source.size.height;
                CGFloat scale = view.contentMode == UIViewContentModeScaleAspectFit ? MIN(sx, sy) : MAX(sx, sy);
                rendered = CGSizeMake(source.size.width * scale, source.size.height * scale);
            } else if (view.contentMode >= UIViewContentModeCenter) rendered = source.size;
            NSMutableDictionary *state = [@{@"key":key, @"imageSize":@[@(source.size.width), @(source.size.height)],
                @"renderedSize":@[@(rendered.width), @(rendered.height)], @"frame":rect([view convertRect:view.bounds toView:window()]), @"contentMode":@(view.contentMode),
                @"sourceAlphaSize":alphaSize(source, [@"glyph-" stringByAppendingString:key])} mutableCopy];
            if ([key isEqual:@"backButton"] || [key isEqual:@"forwardButton"]) {
                BOOL chapter = [key isEqual:@"forwardButton"] && [[vc valueForKey:@"forwardChapterSkipActive"] boolValue];
                NSString *name = [key isEqual:@"backButton"] ? @"gobackward" : (chapter ? @"forward.end" : @"goforward");
                UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:source.size.width * (chapter ? .62 : .82) weight:UIImageSymbolWeightRegular];
                UIImage *reference = [UIImage systemImageNamed:name withConfiguration:config];
                state[@"referenceAlphaSize"] = alphaSize(reference, [[@"glyph-" stringByAppendingString:key] stringByAppendingString:@"-reference"]);
            }
            [playerGlyphs addObject:state];
        }
        entry[@"playerGlyphs"] = playerGlyphs;
        UIButton *transcriptButton = [vc valueForKey:@"transcriptButton"];
        UIImageView *glyph = transcriptButton.imageView;
        UIImage *symbol = glyph.image;
        if (symbol) {
            CGSize imageSize = symbol.size;
            CGSize renderedSize = glyph.bounds.size;
            if (glyph.contentMode == UIViewContentModeScaleAspectFit || glyph.contentMode == UIViewContentModeScaleAspectFill) {
                CGFloat scaleX = renderedSize.width / imageSize.width;
                CGFloat scaleY = renderedSize.height / imageSize.height;
                CGFloat scale = glyph.contentMode == UIViewContentModeScaleAspectFit ? MIN(scaleX, scaleY) : MAX(scaleX, scaleY);
                renderedSize = CGSizeMake(imageSize.width * scale, imageSize.height * scale);
            } else if (glyph.contentMode >= UIViewContentModeCenter) {
                renderedSize = imageSize;
            }
            entry[@"transcriptGlyph"] = @{@"imageSize": @[@(imageSize.width), @(imageSize.height)],
                @"imageViewSize": @[@(glyph.bounds.size.width), @(glyph.bounds.size.height)],
                @"renderedSize": @[@(renderedSize.width), @(renderedSize.height)], @"contentMode": @(glyph.contentMode),
                @"visible": @(!transcriptButton.hidden), @"active": [vc valueForKey:@"transcriptVisible"]};
        }
        NSMutableDictionary *controlFrames = [NSMutableDictionary dictionary];
        for (NSString *key in @[@"timeSlider", @"elapsedTimeLabel", @"remainingTimeLabel", @"chapterTitleLabel", @"controllerButtonGroup", @"backButton", @"forwardButton", @"playButton", @"volumeMinButton", @"volumeMaxButton", @"volumeHitView", @"toolsView"]) {
            UIView *control = [vc valueForKey:key];
            if (control) controlFrames[key] = rect([control convertRect:control.bounds toView:window()]);
        }
        entry[@"controlFrames"] = controlFrames;
        UIView *volume = [vc valueForKey:@"volumeView"];
        NSMutableArray *volumeChildren = [NSMutableArray array];
        for (UIView *child in volume.subviews) {
            NSMutableDictionary *state = [@{@"class": NSStringFromClass(child.class), @"hidden": @(child.hidden), @"alpha": @(child.alpha), @"frame": rect([child convertRect:child.bounds toView:window()])} mutableCopy];
            if ([child isKindOfClass:UISlider.class]) {
                UISlider *slider = (id)child;
                state[@"value"] = @(slider.value);
                state[@"trackFrame"] = rect([slider convertRect:[slider trackRectForBounds:slider.bounds] toView:window()]);
                state[@"thumbFrame"] = rect([slider convertRect:[slider thumbRectForBounds:slider.bounds trackRect:[slider trackRectForBounds:slider.bounds] value:slider.value] toView:window()]);
            }
            [volumeChildren addObject:state];
        }
        entry[@"systemVolume"] = @{@"hidden": @(volume.hidden), @"alpha": @(volume.alpha), @"frame": rect([volume convertRect:volume.bounds toView:window()]), @"children": volumeChildren};
        entry[@"transcriptAvailable"] = [vc valueForKey:@"transcriptAvailable"];
        UIButton *play = [vc valueForKey:@"playButton"];
        entry[@"playFrame"] = rect([play convertRect:play.bounds toView:window()]);
        if (@available(iOS 27.1, *)) {
            NSMutableArray *regions = [NSMutableArray array];
            for (UIViewReservedRegion *region in [vc.view reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind]) {
                if (region.active) [regions addObject:rect([vc.view convertRect:region.frame toView:window()])];
            }
            entry[@"divisionRegions"] = regions;
        }
    }
    if ([vc isKindOfClass:NSClassFromString(@"PlayerInfoViewController_v5")]) {
        UITableView *table = ((UITableViewController *)vc).tableView;
        UIView *chevron = [vc valueForKey:@"chevronIndicatorView"];
        entry[@"chevronFrame"] = rect([chevron convertRect:chevron.bounds toView:window()]);
        entry[@"chevronInteractive"] = @(chevron.userInteractionEnabled);
        CGPoint chevronCenter = [chevron convertPoint:CGPointMake(CGRectGetMidX(chevron.bounds), CGRectGetMidY(chevron.bounds)) toView:window()];
        UIView *chevronHit = [window() hitTest:chevronCenter withEvent:nil];
        entry[@"chevronHittable"] = @(chevronHit == chevron || [chevronHit isDescendantOfView:chevron]);
        entry[@"listHeaderFrame"] = rect([table convertRect:[table rectForHeaderInSection:0] toView:window()]);
        entry[@"artworkHeaderHeight"] = @(CGRectGetHeight(table.tableHeaderView.frame));
        NSMutableArray *headers = [NSMutableArray array];
        for (NSInteger section = 0; section < table.numberOfSections; section++) {
            UITableViewHeaderFooterView *header = [table headerViewForSection:section];
            if (!header) continue;
            NSMutableArray *visuals = [NSMutableArray array];
            for (NSString *key in @[@"textLabel", @"editButton", @"doneButton"]) {
                UIView *visual = [header valueForKey:key];
                if (visual.hidden || visual.alpha < .01) continue;
                [visuals addObject:@{@"key":key, @"frame":rect([visual convertRect:visual.bounds toView:window()])}];
            }
            [headers addObject:@{@"frame":rect([header convertRect:header.bounds toView:window()]),
                @"safeArea":insets(header.safeAreaInsets), @"contentFrame":rect(header.contentView.frame),
                @"contentSafeArea":insets(header.contentView.safeAreaInsets), @"visuals":visuals}];
        }
        entry[@"listHeaders"] = headers;
        UIView *artwork = [vc valueForKey:@"chapterImagesCollection"];
        entry[@"artworkFrame"] = rect([artwork convertRect:artwork.bounds toView:window()]);
        UICollectionView *collection = (id)artwork;
        entry[@"artworkAdjustedInset"] = insets(collection.adjustedContentInset);
        NSMutableArray *artworkCells = [NSMutableArray array];
        for (UICollectionViewCell *cell in collection.visibleCells) {
            [artworkCells addObject:rect([cell convertRect:cell.bounds toView:window()])];
        }
        entry[@"artworkCells"] = artworkCells;
        entry[@"bottomScrollInset"] = [vc valueForKey:@"bottomScrollInset"];
        UITextView *transcript = [vc valueForKey:@"transcriptTextView"];
        entry[@"transcriptVisible"] = [vc valueForKey:@"transcriptVisible"];
        entry[@"transcriptText"] = transcript.text ?: @"";
        entry[@"transcriptFrame"] = rect([transcript convertRect:transcript.bounds toView:window()]);
        UIView *search = [vc valueForKey:@"transcriptSearchButton"];
        entry[@"transcriptSearchFrame"] = rect([search convertRect:search.bounds toView:window()]);
    }
    [result addObject:entry];
    for (UIViewController *child in vc.childViewControllers) controllers(child, result);
    if (vc.presentedViewController.presentingViewController == vc) controllers(vc.presentedViewController, result);
}
static UIViewController *top(void) {
    UIViewController *vc = mainController();
    while (YES) {
        if (vc.presentedViewController) vc = vc.presentedViewController;
        else if ([vc isKindOfClass:UINavigationController.class]) vc = ((UINavigationController*)vc).topViewController;
        else if ([vc respondsToSelector:NSSelectorFromString(@"contentViewController")]) vc = [vc valueForKey:@"contentViewController"];
        else if ([vc isKindOfClass:UITableViewController.class]) return vc;
        else if (vc.childViewControllers.count) vc = vc.childViewControllers.lastObject;
        else return vc;
    }
}
@interface ICAdaptiveLayoutProbe : NSObject @end
@implementation ICAdaptiveLayoutProbe
- (void)poll {
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"command.json"]] ?: NSData.data options:0 error:nil];
    static NSString *last;
    if (!request || !window() || [last isEqual:request[@"id"]]) return;
    last = request[@"id"];
    captureGlyphs = [request[@"capture"] boolValue];
    NSMutableDictionary *reply = [@{@"id":last} mutableCopy];
    @try {
        UIViewController *main = mainController();
        NSString *action = request[@"action"];
        if ([action isEqual:@"fixture"]) {
            id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
            NSManagedObjectContext *context = [database valueForKey:@"objectContext"];
            NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Episode"];
            fetch.predicate = [NSPredicate predicateWithFormat:@"title == %@", @"Eine längere Episode zur Prüfung schmaler Fenster und breiter Displays"];
            fetch.fetchLimit = 1;
            fixtureEpisode = [[context executeFetchRequest:fetch error:nil] firstObject];
            if (!fixtureEpisode) {
            id feed = [NSEntityDescription insertNewObjectForEntityForName:@"Feed" inManagedObjectContext:context];
            [feed setValue:@"Layout-Testpodcast mit einem langen Namen" forKey:@"title"];
            [feed setValue:[NSURL URLWithString:@"https://example.invalid/adaptive-layout"] forKey:@"sourceURL"];
            [feed setValue:@YES forKey:@"subscribed"];
            id episode = [NSEntityDescription insertNewObjectForEntityForName:@"Episode" inManagedObjectContext:context];
            [episode setValue:NSUUID.UUID.UUIDString forKey:@"objectHash"];
            [episode setValue:NSUUID.UUID.UUIDString forKey:@"guid"];
            [episode setValue:@"Eine längere Episode zur Prüfung schmaler Fenster und breiter Displays" forKey:@"title"];
            [episode setValue:NSDate.date forKey:@"pubDate"];
            [episode setValue:@180 forKey:@"duration"];
            [episode setValue:feed forKey:@"feed"];
            [episode setValue:@"<h1>Layoutprüfung</h1><p>Shownotes mit Text, Links und einem langen Episodentitel.</p>" forKey:@"summary"];
            id medium = [NSEntityDescription insertNewObjectForEntityForName:@"Medium" inManagedObjectContext:context];
            [medium setValue:episode forKey:@"episode"];
            [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
            [medium setValue:@"audio/wav" forKey:@"mimeType"];
            [database save];
            fixtureEpisode = episode;
            }
            NSString *srt = @"1\n00:00:00,000 --> 00:00:10,000\nEin Beispieltranskript zur Layoutprüfung.\n\n2\n00:00:10,000 --> 00:00:20,000\nDer Text bleibt auch in schmalen Fenstern lesbar.\n";
            NSString *srtPath = [directory stringByAppendingPathComponent:@"fixture.srt"];
            [srt writeToFile:srtPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [fixtureEpisode setValue:@[@{@"url": [NSURL fileURLWithPath:srtPath].absoluteString, @"type": @"application/x-subrip", @"language": @"de"}] forKey:@"transcripts"];
            [fixtureEpisode setValue:@NO forKey:@"consumed"];
            [fixtureEpisode setValue:@YES forKey:@"starred"];
            [fixtureEpisode setValue:@60 forKey:@"position"];
            [fixtureEpisode setValue:NSDate.date forKey:@"lastPlayed"];
            for (id medium in [fixtureEpisode valueForKey:@"media"]) {
                [medium setValue:[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"fixture.wav"]] forKey:@"fileURL"];
            }
            NSFetchRequest *bookmarks = [NSFetchRequest fetchRequestWithEntityName:@"Bookmark"];
            bookmarks.predicate = [NSPredicate predicateWithFormat:@"episodeHash == %@", [fixtureEpisode valueForKey:@"objectHash"]];
            if ([context countForFetchRequest:bookmarks error:nil] == 0) {
                id bookmark = [NSEntityDescription insertNewObjectForEntityForName:@"Bookmark" inManagedObjectContext:context];
                [bookmark setValue:[fixtureEpisode valueForKey:@"objectHash"] forKey:@"episodeHash"];
                [bookmark setValue:@"Ein längeres Test-Lesezeichen für schmale Fenster" forKey:@"title"];
                [bookmark setValue:@"Layout-Testpodcast mit einem langen Namen" forKey:@"feedTitle"];
                [bookmark setValue:[fixtureEpisode valueForKey:@"title"] forKey:@"episodeTitle"];
                [bookmark setValue:[fixtureEpisode valueForKey:@"guid"] forKey:@"episodeGuid"];
                [bookmark setValue:[NSURL URLWithString:@"https://example.invalid/adaptive-layout"] forKey:@"feedURL"];
                [bookmark setValue:@15 forKey:@"position"];
            }
            [database save];
        } else if ([action isEqual:@"extendedFixture"]) {
            id database = [NSClassFromString(@"DatabaseManager") sharedDatabaseManager];
            NSManagedObjectContext *context = [database valueForKey:@"objectContext"];
            if (![[fixtureEpisode valueForKey:@"chapters"] count]) {
                for (NSInteger i = 0; i < 2; i++) {
                    id chapter = [NSEntityDescription insertNewObjectForEntityForName:@"Chapter" inManagedObjectContext:context];
                    [chapter setValue:fixtureEpisode forKey:@"episode"];
                    [chapter setValue:@(i) forKey:@"index"];
                    [chapter setValue:@(i * 90) forKey:@"timecode"];
                    [chapter setValue:@90 forKey:@"duration"];
                    [chapter setValue:@"Ein längerer Kapiteltitel für die Prüfung schmaler geteilter Fenster" forKey:@"title"];
                }
            }
            [database save];
            [[NSClassFromString(@"AudioSession") sharedAudioSession] appendToUpNext:@[fixtureEpisode]];
        } else if ([action isEqual:@"miniPlayer"]) {
            [(id)main playNow:nil];
        } else if ([action isEqual:@"player"]) {
            id player = [NSClassFromString(@"PlaybackViewController") playbackViewControllerWithEpisode:fixtureEpisode];
            [player presentFromParentViewController:main autostart:NO completion:nil];
        } else if ([action isEqual:@"transcript"]) {
            UIViewController *player = top().parentViewController;
            id controls = [player valueForKey:@"controller"];
            UIButton *button = [controls valueForKey:@"transcriptButton"];
            [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        } else if ([action isEqual:@"chapterList"]) {
            UIButton *button = [top() valueForKey:@"chevronIndicatorView"];
            [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        } else if ([action isEqual:@"episode"]) {
            [(id)main showShowNotesOfEpisode:fixtureEpisode animated:NO];
        } else if ([action isEqual:@"showNotes"]) {
            [(id)top() _pushShowNotesOfEpisode:fixtureEpisode animated:NO inAppearanceTransition:NO];
        } else if ([action isEqual:@"podcastRoot"]) {
            [top().navigationController popToRootViewControllerAnimated:NO];
        } else if ([action isEqual:@"barButton"]) {
            UIBarButtonItem *button = [request[@"side"] isEqual:@"left"] ? top().navigationItem.leftBarButtonItem : top().navigationItem.rightBarButtonItem;
            [UIApplication.sharedApplication sendAction:button.action to:button.target from:button forEvent:nil];
        } else if ([action isEqual:@"menu"]) {
            ((void(*)(id,SEL,BOOL,BOOL))objc_msgSend)(main, NSSelectorFromString(@"setSidebarShown:animated:"), YES, NO);
        } else if ([action isEqual:@"select"]) {
            NSInteger tag = [request[@"tag"] integerValue];
            BOOL applied = ((BOOL(*)(id,SEL,NSInteger))objc_msgSend)(main, NSSelectorFromString(@"_selectMainSidebarItemWithTag:"), tag);
            reply[@"selectionApplied"] = @(applied);
            if (applied) [[main valueForKey:@"sidebarController"] setValue:@(tag) forKey:@"selectedItemTag"];
            ((void(*)(id,SEL,BOOL,BOOL))objc_msgSend)(main, NSSelectorFromString(@"setSidebarShown:animated:"), NO, NO);
        } else if ([action isEqual:@"settingsRow"]) {
            UITableViewController *vc = (id)top();
            for (NSInteger row = 0; row < [vc.tableView numberOfRowsInSection:0]; row++) {
                NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
                if ([(id)vc settingsRowForIndexPath:path] == [request[@"row"] integerValue]) {
                    [vc.tableView.delegate tableView:vc.tableView didSelectRowAtIndexPath:path];
                    break;
                }
            }
        } else if ([action isEqual:@"row"]) {
            UITableViewController *vc = (id)top();
            NSIndexPath *path = [NSIndexPath indexPathForRow:[request[@"row"] integerValue] inSection:[request[@"section"] integerValue]];
            [vc.tableView.delegate tableView:vc.tableView didSelectRowAtIndexPath:path];
        } else if ([action isEqual:@"back"]) {
            [top().navigationController popViewControllerAnimated:NO];
        } else if ([action isEqual:@"dismiss"]) {
            [main dismissViewControllerAnimated:NO completion:nil];
#if TARGET_OS_MACCATALYST
        } else if ([action isEqual:@"resize"]) {
            UIWindowSceneGeometryPreferencesMac *preferences = [[UIWindowSceneGeometryPreferencesMac alloc] initWithSystemFrame:CGRectMake(200, 100, [request[@"width"] doubleValue], [request[@"height"] doubleValue])];
            [window().windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                [error.description writeToFile:[directory stringByAppendingPathComponent:@"resize-error.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }];
#endif
        } else if ([action isEqual:@"scrollMenu"] || [action isEqual:@"scrollContent"]) {
            UITableViewController *vc = [action isEqual:@"scrollMenu"] ? [main valueForKey:@"sidebarController"] : (id)top();
            CGFloat y = [request[@"end"] boolValue] ? MAX(-vc.tableView.adjustedContentInset.top, vc.tableView.contentSize.height - vc.tableView.bounds.size.height + vc.tableView.adjustedContentInset.bottom) : -vc.tableView.adjustedContentInset.top;
            [vc.tableView setContentOffset:CGPointMake(0,y) animated:NO];
        }
        [window() layoutIfNeeded];
        NSMutableArray *tree = [NSMutableArray array], *labels = [NSMutableArray array];
        controllers(window().rootViewController, tree);
        views(window(), labels);
        reply[@"controllers"] = tree;
        reply[@"labels"] = labels;
        reply[@"window"] = rect(window().bounds);
        reply[@"safeArea"] = insets(window().safeAreaInsets);
        UIWindowScene *scene = window().windowScene;
        UIScreen *screen = scene.screen;
        CGPoint origin = [window() convertPoint:CGPointZero toCoordinateSpace:screen.fixedCoordinateSpace];
        CGPoint axis = [window() convertPoint:CGPointMake(100, 0) toCoordinateSpace:screen.fixedCoordinateSpace];
        reply[@"orientation"] = @{@"device": @(UIDevice.currentDevice.orientation),
            @"interface": @(scene.effectiveGeometry.interfaceOrientation),
            @"appMask": @([UIApplication.sharedApplication supportedInterfaceOrientationsForWindow:window()]),
            @"bundleOrientations": [NSBundle.mainBundle objectForInfoDictionaryKey:@"UISupportedInterfaceOrientations"] ?: @[],
            @"locked": @(scene.effectiveGeometry.interfaceOrientationLocked),
            @"screenBounds": rect(screen.bounds), @"fixedBounds": rect(screen.fixedCoordinateSpace.bounds),
            @"windowXAxisInFixedSpace": @[@(axis.x - origin.x), @(axis.y - origin.y)],
            @"rootTransform": NSStringFromCGAffineTransform(window().rootViewController.view.transform)};
        reply[@"idiom"] = @(UIDevice.currentDevice.userInterfaceIdiom);
        reply[@"appGroupAvailable"] = @([NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:@"group.com.iteconomy.instacastplus"] != nil);
        reply[@"sizeMinimum"] = @[@(window().windowScene.sizeRestrictions.minimumSize.width), @(window().windowScene.sizeRestrictions.minimumSize.height)];
        reply[@"top"] = NSStringFromClass(top().class) ?: @"";
        if (request[@"capture"]) {
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window().bounds];
            UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [window() drawViewHierarchyInRect:window().bounds afterScreenUpdates:YES];
            }];
            [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"screen.png"] atomically:YES];
        }
    } @catch (NSException *e) { reply[@"error"] = e.description; }
    [[NSJSONSerialization dataWithJSONObject:reply options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[directory stringByAppendingPathComponent:@"reply.json"] atomically:YES];
}
@end
__attribute__((constructor)) static void start(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/AdaptiveLayoutProbe"];
        [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
        ICAdaptiveLayoutProbe *probe = [ICAdaptiveLayoutProbe new];
        [NSTimer scheduledTimerWithTimeInterval:.1 target:probe selector:@selector(poll) userInfo:nil repeats:YES];
    });
}
