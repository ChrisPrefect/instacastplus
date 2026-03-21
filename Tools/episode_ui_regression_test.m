#import <Foundation/Foundation.h>
#import <math.h>

#import "../Classes/ICEpisodeUIConfig.h"

static void ICAssert(BOOL condition, NSString* message)
{
    if (!condition) {
        fprintf(stderr, "%s\n", [message UTF8String]);
        exit(1);
    }
}

int main(void)
{
    @autoreleasepool {
        ICAssert([ICEpisodePlayNextMenuSymbolName() isEqualToString:@"list.bullet.indent"], @"Play Next menu icon regressed.");
        ICAssert([ICEpisodeDownloadActionStartIconName() isEqualToString:@"Menu Downloads"], @"Download action should use the shared square-arrow icon.");
        ICAssert(ICEpisodeDownloadActionStartUsesAssetImage() == YES, @"Download action should use the shared asset image.");
        ICAssert([ICEpisodeSelectionToggleTitleKey(0, 4) isEqualToString:@"All"], @"Selection toggle should start with All.");
        ICAssert([ICEpisodeSelectionToggleTitleKey(4, 4) isEqualToString:@"None Selection"], @"Selection toggle should switch to None when all rows are selected.");
        ICAssert(fabs(ICEpisodePlayNextOverlayDisplayDuration() - 3.0) < DBL_EPSILON, @"Play Next overlay should stay visible for 3 seconds.");
    }

    return 0;
}
