//
//  TranscriptionQueueViewController.h
//  Instacast
//
//  Displays the transcription queue with progress.
//

#import <UIKit/UIKit.h>

@class CDEpisode;

@interface TranscriptionQueueViewController : UITableViewController
+ (void)startServerTranscriptionForEpisode:(CDEpisode*)episode fromViewController:(UIViewController*)presenter NS_SWIFT_NAME(startServerTranscription(episode:presenter:));
+ (void)showServerStatusForEpisodeHash:(NSString*)hash title:(NSString*)title fromViewController:(UIViewController*)presenter;
@end
