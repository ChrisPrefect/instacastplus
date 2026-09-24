#import <UIKit/UIKit.h>

@class CDEpisode;

@interface ICShareItem : NSObject <UIActivityItemSource>

+ (instancetype)itemWithURL:(NSURL *)url title:(NSString *)title image:(UIImage *)image;
+ (UIActivityViewController*)activityViewControllerForEpisode:(CDEpisode*)episode;
+ (UIAction*)shareActionForEpisode:(CDEpisode*)episode fromViewController:(UIViewController*)controller sourceView:(UIView*)sourceView sourceRect:(CGRect)sourceRect;

@end
