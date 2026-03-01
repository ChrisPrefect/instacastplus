import WidgetKit
import SwiftUI

@main
struct InstacastWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        UpNextWidget()
        SmartListWidget()
        StatsWidget()
        PodcastGridWidget()
        LockScreenCircularWidget()
        LockScreenRectangularWidget()
        LockScreenInlineWidget()
    }
}
