import WidgetKit
import SwiftUI

struct FavoritesGridWidget: Widget {
    let kind = ICWidgetConstants.favoritesGridWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FavoritesGridProvider()) { entry in
            FavoritesGridWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.favorites.name", comment: ""))
        .description(NSLocalizedString("widget.favorites.description", comment: ""))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct FavoritesGridWidgetView: View {
    let entry: FavoritesGridEntry
    @Environment(\.widgetFamily) var family

    private var gridConfig: (columns: Int, rows: Int) {
        switch family {
        case .systemSmall:  return (2, 2)   // 4 covers
        case .systemMedium: return (3, 2)   // 6 covers
        case .systemLarge:  return (4, 3)   // 12 covers
        default:            return (3, 2)
        }
    }

    var body: some View {
        Group {
            if entry.feeds.isEmpty {
                WidgetEmptyStateView(icon: "square.grid.2x2", message: NSLocalizedString("widget.empty.nosubscriptions", comment: ""))
            } else {
                gridView
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var gridView: some View {
        let config = gridConfig
        let maxItems = config.columns * config.rows
        let feeds = Array(entry.feeds.sorted { $0.rank < $1.rank }.prefix(maxItems))

        return GeometryReader { geo in
            let spacing: CGFloat = family == .systemSmall ? 4 : 6
            let totalHSpacing = spacing * CGFloat(config.columns - 1) + 4  // + padding
            let totalVSpacing = spacing * CGFloat(config.rows - 1) + 4
            let availableW = geo.size.width - totalHSpacing
            let availableH = geo.size.height - totalVSpacing
            let coverSize = min(availableW / CGFloat(config.columns), availableH / CGFloat(config.rows))

            VStack(spacing: spacing) {
                ForEach(0..<config.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<config.columns, id: \.self) { col in
                            let index = row * config.columns + col
                            if index < feeds.count {
                                let feed = feeds[index]
                                Link(destination: ICWidgetConstants.feedURL(feedUID: feed.id)) {
                                    PodcastCoverView(feed: feed, size: coverSize)
                                }
                            } else {
                                Color.clear
                                    .frame(width: coverSize, height: coverSize)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(2)
        }
    }
}
