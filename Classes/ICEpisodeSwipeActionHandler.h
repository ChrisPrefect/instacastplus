#import <UIKit/UIKit.h>

@class CDEpisode;

@interface ICEpisodeSwipeActionHandler : NSObject

+ (UIContextualAction*)configuredRightSwipeActionForEpisode:(CDEpisode*)episode
                                    presentingViewController:(UIViewController*)viewController
                                                 willPerform:(void (^)(void))willPerform
                                                   didPerform:(void (^)(void))didPerform;

@end
