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
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryInline, .accessoryCorner, .accessoryRectangular]
        #else
        [.accessoryCircular, .accessoryInline, .accessoryRectangular]
        #endif
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
            Label {
                Text("InstacastPlus")
            } icon: {
                Image("ComplicationIcon")
            }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                complicationIcon
                    .frame(width: 18, height: 18)
                Text("InstacastPlus")
                    .lineLimit(1)
            }
        #if os(watchOS)
        case .accessoryCorner:
            complicationIcon
                .widgetLabel("InstacastPlus")
        #endif
        default:
            complicationIcon
        }
    }

    private var complicationIcon: some View {
        Image("ComplicationIcon")
            .resizable()
            .scaledToFit()
    }
}
