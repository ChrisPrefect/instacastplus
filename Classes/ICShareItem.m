#import "ICShareItem.h"
#import <LinkPresentation/LinkPresentation.h>
#import "InstacastPlus-Swift.h"

@interface ICShareItem ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) UIImage *image;
@end

@implementation ICShareItem

+ (UIActivityViewController*)activityViewControllerForEpisode:(CDEpisode*)episode
{
    NSURL* feedURL = episode.feed.sourceURL;
    if (!feedURL || episode.guid.length == 0 || episode.objectHash.length == 0) return nil;

    NSURLComponents* components = [NSURLComponents componentsWithString:@"https://instacast.ch/share/episode"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:feedURL.absoluteString],
                             [NSURLQueryItem queryItemWithName:@"guid" value:episode.guid]];
    NSItemProvider* provider = [[ICSharePlayCoordinator sharedCoordinator]
        activityItemProviderForEpisodeIdentifier:episode.objectHash
                                         feedURL:feedURL
                                     episodeGUID:episode.guid
                                    episodeTitle:episode.title ?: @""
                                    podcastTitle:episode.feed.displayTitle ?: episode.feed.title ?: @""
                                      fallbackURL:components.URL];
    UIActivityViewController* controller = [[UIActivityViewController alloc] initWithActivityItems:@[provider] applicationActivities:nil];
    controller.allowsProminentActivity = YES;
    return controller;
}

+ (UIAction*)shareActionForEpisode:(CDEpisode*)episode fromViewController:(UIViewController*)controller sourceView:(UIView*)sourceView sourceRect:(CGRect)sourceRect
{
    __weak UIViewController* weakController = controller;
    __weak UIView* weakSourceView = sourceView;
    UIAction* action = [UIAction actionWithTitle:@"Share".ls image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__unused UIAction* action) {
        UIActivityViewController* shareController = [self activityViewControllerForEpisode:episode];
        if (!shareController) return;
        shareController.popoverPresentationController.sourceView = weakSourceView;
        shareController.popoverPresentationController.sourceRect = sourceRect;
        [weakController presentViewController:shareController animated:YES completion:nil];
    }];
    if (!episode.feed.sourceURL || episode.guid.length == 0 || episode.objectHash.length == 0) {
        action.attributes = UIMenuElementAttributesDisabled;
    }
    return action;
}

+ (instancetype)itemWithURL:(NSURL *)url title:(NSString *)title image:(UIImage *)image
{
    ICShareItem *item = [[ICShareItem alloc] init];
    item.url = url;
    item.title = title;
    item.image = image;
    return item;
}

#pragma mark - UIActivityItemSource

- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)activityViewController
{
    return self.url;
}

- (id)activityViewController:(UIActivityViewController *)activityViewController itemForActivityType:(UIActivityType)activityType
{
    return self.url;
}

- (LPLinkMetadata *)activityViewControllerLinkMetadata:(UIActivityViewController *)activityViewController
{
    LPLinkMetadata *metadata = [[LPLinkMetadata alloc] init];
    metadata.originalURL = self.url;
    metadata.URL = self.url;
    metadata.title = self.title;
    if (self.image) {
        metadata.imageProvider = [[NSItemProvider alloc] initWithObject:self.image];
    }
    return metadata;
}

@end
