//
//  ICListEditorPodcastCell.m
//  Instacast
//
//  Created by Martin Hering on 21.08.14.
//
//

#import "ICListEditorPodcastCell.h"
#import "ImageCacheManager.h"

@implementation ICListEditorPodcastCell

- (void)prepareForReuse
{
    [super prepareForReuse];
    [[ImageCacheManager sharedImageCacheManager] cancelImageCacheOperationsWithSender:self];
    self.representedFeedIdentifier = nil;
    self.imageView.image = [UIImage imageNamed:@"Podcast Placeholder 56"];
}

- (void) layoutSubviews
{
    [super layoutSubviews];
    
    self.imageView.frame = CGRectMake(15, 0, 44, 44);
}
@end
