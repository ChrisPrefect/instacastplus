import WidgetKit
import SwiftUI

@main
struct InstacastWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        SmartListWidget()
        StatsWidget()
        PodcastGridWidget()
        LockScreenCircularWidget()
        LockScreenRectangularWidget()
        LockScreenInlineWidget()
    }
}
