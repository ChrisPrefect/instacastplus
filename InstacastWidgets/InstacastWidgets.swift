import WidgetKit
import SwiftUI

@main
struct InstacastWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        SmartListWidget()
        StatsWidget()
        LockScreenCircularWidget()
        LockScreenRectangularWidget()
        LockScreenInlineWidget()
    }
}
