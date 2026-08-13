import SwiftUI
import WidgetKit

@main
struct InstacastWatchWidgets: WidgetBundle {
    var body: some Widget {
        WatchComplicationWidget(style: .standard)
        WatchComplicationWidget(style: .core)
        WatchComplicationWidget(style: .icon1)
        WatchComplicationWidget(style: .icon4)
        WatchComplicationWidget(style: .icon2)
        WatchComplicationWidget(style: .icon3)
        WatchComplicationWidget(style: .icon5)
        WatchComplicationWidget(style: .icon6)
        WatchComplicationWidget(style: .icon7)
        WatchComplicationWidget(style: .classicAlt1)
        WatchComplicationWidget(style: .classicAlt2)
        WatchComplicationWidget(style: .classicAlt3)
        WatchComplicationWidget(style: .classicAlt4)
    }
}

private enum WatchComplicationStyle {
    case standard
    case core
    case icon1
    case icon4
    case icon2
    case icon3
    case icon5
    case icon6
    case icon7
    case classicAlt1
    case classicAlt2
    case classicAlt3
    case classicAlt4

    var kind: String {
        switch self {
        case .standard: "InstacastWatchComplication"
        case .core: "InstacastWatchComplication.Core"
        case .icon1: "InstacastWatchComplication.Icon1"
        case .icon4: "InstacastWatchComplication.Icon4"
        case .icon2: "InstacastWatchComplication.Icon2"
        case .icon3: "InstacastWatchComplication.Icon3"
        case .icon5: "InstacastWatchComplication.Icon5"
        case .icon6: "InstacastWatchComplication.Icon6"
        case .icon7: "InstacastWatchComplication.Icon7"
        case .classicAlt1: "InstacastWatchComplication.ClassicAlt1"
        case .classicAlt2: "InstacastWatchComplication.ClassicAlt2"
        case .classicAlt3: "InstacastWatchComplication.ClassicAlt3"
        case .classicAlt4: "InstacastWatchComplication.ClassicAlt4"
        }
    }

    var iconName: String {
        switch self {
        case .standard: "ComplicationIcon"
        case .core: "ComplicationIconCore"
        case .icon1: "ComplicationIcon1"
        case .icon4: "ComplicationIcon4"
        case .icon2: "ComplicationIcon2"
        case .icon3: "ComplicationIcon3"
        case .icon5: "ComplicationIcon5"
        case .icon6: "ComplicationIcon6"
        case .icon7: "ComplicationIcon7"
        case .classicAlt1: "ComplicationIconClassicAlt1"
        case .classicAlt2: "ComplicationIconClassicAlt2"
        case .classicAlt3: "ComplicationIconClassicAlt3"
        case .classicAlt4: "ComplicationIconClassicAlt4"
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .standard: "WATCH_COMPLICATION_STANDARD_TITLE"
        case .core: "WATCH_COMPLICATION_CORE_TITLE"
        case .icon1: "WATCH_COMPLICATION_ICON_1_TITLE"
        case .icon4: "WATCH_COMPLICATION_ICON_4_TITLE"
        case .icon2: "WATCH_COMPLICATION_ICON_2_TITLE"
        case .icon3: "WATCH_COMPLICATION_ICON_3_TITLE"
        case .icon5: "WATCH_COMPLICATION_ICON_5_TITLE"
        case .icon6: "WATCH_COMPLICATION_ICON_6_TITLE"
        case .icon7: "WATCH_COMPLICATION_ICON_7_TITLE"
        case .classicAlt1: "WATCH_COMPLICATION_CLASSIC_1_TITLE"
        case .classicAlt2: "WATCH_COMPLICATION_CLASSIC_2_TITLE"
        case .classicAlt3: "WATCH_COMPLICATION_CLASSIC_3_TITLE"
        case .classicAlt4: "WATCH_COMPLICATION_CLASSIC_4_TITLE"
        }
    }
}

private struct WatchComplicationWidget: Widget {
    let style: WatchComplicationStyle

    init() {
        style = .standard
    }

    init(style: WatchComplicationStyle) {
        self.style = style
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: style.kind, provider: WatchComplicationProvider()) { entry in
            WatchComplicationView(entry: entry, iconName: style.iconName)
        }
        .configurationDisplayName(style.displayName)
        .description("WATCH_COMPLICATION_DESCRIPTION")
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
    let iconName: String

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label {
                Text("InstacastPlus")
            } icon: {
                Image(iconName)
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
        Image(iconName)
            .resizable()
            .scaledToFit()
    }
}
