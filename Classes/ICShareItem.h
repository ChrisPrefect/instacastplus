#import <UIKit/UIKit.h>

@interface ICShareItem : NSObject <UIActivityItemSource>

+ (instancetype)itemWithURL:(NSURL *)url title:(NSString *)title image:(UIImage *)image;

@end
