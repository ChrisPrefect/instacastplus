#import "ICShareItem.h"
#import <LinkPresentation/LinkPresentation.h>

@interface ICShareItem ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) UIImage *image;
@end

@implementation ICShareItem

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
