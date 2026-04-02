import WidgetKit
import SwiftUI

@main
struct InstacastWidgets: WidgetBundle {
    var body: some Widget {
        // NowPlayingWidget() — disabled until WidgetKit supports reliable interactive controls
        SmartListWidget()
        StatsWidget()
        LockScreenCircularWidget()
        LockScreenRectangularWidget()
        LockScreenInlineWidget()
    }
}
