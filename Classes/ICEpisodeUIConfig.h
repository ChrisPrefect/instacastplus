#import <Foundation/Foundation.h>

NS_INLINE NSString* ICEpisodePlayNextMenuSymbolName(void)
{
    return @"list.bullet.indent";
}

NS_INLINE NSString* ICEpisodeDownloadActionStartIconName(void)
{
    return @"Menu Downloads";
}

NS_INLINE BOOL ICEpisodeDownloadActionStartUsesAssetImage(void)
{
    return YES;
}

NS_INLINE NSString* ICEpisodeSelectionToggleTitleKey(NSUInteger selectedCount, NSUInteger rowCount)
{
    if (rowCount > 0 && selectedCount >= rowCount) {
        return @"None Selection";
    }

    return @"All";
}

NS_INLINE NSTimeInterval ICEpisodePlayNextOverlayDisplayDuration(void)
{
    return 3.0;
}
