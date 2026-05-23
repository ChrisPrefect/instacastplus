import SwiftUI
import WidgetKit

@main
struct InstacastWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchComplicationWidget()
    }
}

struct WatchComplicationWidget: Widget {
    private let kind = "InstacastWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationView(entry: entry)
        }
        .configurationDisplayName("InstacastPlus")
        .description("InstacastPlus")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryCorner, .accessoryRectangular])
    }
}

private struct WatchComplicationEntry: TimelineEntry {
    let date: Date
}

private struct WatchComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchComplicationEntry) -> Void) {
        completion(WatchComplicationEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchComplicationEntry>) -> Void) {
        completion(Timeline(entries: [WatchComplicationEntry(date: Date())], policy: .never))
    }
}

private struct WatchComplicationView: View {
    let entry: WatchComplicationEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("InstacastPlus", systemImage: "play.circle.fill")
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "play.circle.fill")
                Text("InstacastPlus")
                    .lineLimit(1)
            }
        case .accessoryCorner:
            Image(systemName: "play.circle.fill")
                .widgetLabel("InstacastPlus")
        default:
            Image(systemName: "play.circle.fill")
        }
    }
}
