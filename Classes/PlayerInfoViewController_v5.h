//
//  PlayInfoViewController2.h
//  Instacast
//
//  Created by Martin Hering on 02.08.14.
//
//

#import <UIKit/UIKit.h>

@class PlayerVideoViewController;

@interface PlayerInfoViewController_v5 : UITableViewController
{
    NSArray* chapterImagesArray;
    NSTimer *currentImageTimer;
}

+ (instancetype) viewController;

@property (nonatomic, strong) PlayerVideoViewController* videoViewController;

@property (nonatomic, strong) UIImage* image;
@property (nonatomic) CGFloat bottomScrollInset;
@property (nonatomic) CGRect rectCollection;
@property (nonatomic, strong) UIView* chapterView;
@property (nonatomic, strong) UIPageControl* pageControl;
@property (nonatomic, strong) UICollectionView* chapterImagesCollection;

- (void) layoutHeaderView;
- (void) reload;
- (void)updateCollectionsImage:(NSArray *)images atIndex:(NSUInteger)indexNumber;
- (void)changeChapterImageIndex:(NSUInteger)indexNumber;
@end
