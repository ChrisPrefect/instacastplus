import WidgetKit
import SwiftUI
import AppIntents

struct PodcastGridWidget: Widget {
    let kind = "PodcastGridWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: PodcastGridConfigIntent.self, provider: PodcastGridProvider()) { entry in
            PodcastGridWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.podcastgrid.name", comment: ""))
        .description(NSLocalizedString("widget.podcastgrid.description", comment: ""))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry + Provider

struct PodcastGridEntry: TimelineEntry, Sendable {
    let date: Date
    let feeds: [WFeed]
}

struct PodcastGridProvider: AppIntentTimelineProvider {
    typealias Entry = PodcastGridEntry
    typealias Intent = PodcastGridConfigIntent

    func placeholder(in context: Context) -> PodcastGridEntry {
        PodcastGridEntry(date: Date(), feeds: [])
    }

    func snapshot(for configuration: PodcastGridConfigIntent, in context: Context) async -> PodcastGridEntry {
        let feeds = resolveFeeds(configuration: configuration, family: context.family)
        return PodcastGridEntry(date: Date(), feeds: feeds)
    }

    func timeline(for configuration: PodcastGridConfigIntent, in context: Context) async -> Timeline<PodcastGridEntry> {
        let feeds = resolveFeeds(configuration: configuration, family: context.family)
        let entry = PodcastGridEntry(date: Date(), feeds: feeds)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60)))
    }

    // MARK: - Helpers

    private func maxItems(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall:  return 4
        case .systemMedium: return 8
        case .systemLarge:  return 16
        default:            return 8
        }
    }

    private func resolveFeeds(configuration: PodcastGridConfigIntent, family: WidgetFamily) -> [WFeed] {
        let limit = maxItems(for: family)
        guard let allFeeds = SharedContainerReader.readFeeds() else { return [] }

        // User picked specific podcasts → respect that order
        if let selected = configuration.feeds, !selected.isEmpty {
            let selectedIds = selected.map { $0.id }
            let filtered = allFeeds.filter { selectedIds.contains($0.id) }
            // Sort by the user's selection order
            let ordered = selectedIds.compactMap { id in filtered.first { $0.id == id } }
            return Array(ordered.prefix(limit))
        }

        // No selection → top N by rank
        return Array(allFeeds.sorted { $0.rank < $1.rank }.prefix(limit))
    }
}

// MARK: - Views

struct PodcastGridWidgetView: View {
    let entry: PodcastGridEntry
    @Environment(\.widgetFamily) var family

    private var accentColor: Color { WidgetAccentColor.color }

    /// Maximum grid dimensions for each widget family
    private var gridConfig: (columns: Int, rows: Int) {
        switch family {
        case .systemSmall:  return (2, 2)   // 4 covers max
        case .systemMedium: return (4, 2)   // 8 covers max
        case .systemLarge:  return (4, 4)   // 16 covers max
        default:            return (4, 2)
        }
    }

    /// Adaptive grid that makes icons larger when few podcasts are available.
    /// For landscape (medium): single row maximizes icon height.
    /// For square (small/large): halving columns+rows doubles the icon size.
    private func adaptiveGridConfig(feedCount: Int) -> (columns: Int, rows: Int) {
        guard feedCount > 0 else { return gridConfig }
        switch family {
        case .systemSmall:
            // 2×2 max — icons are always the same size for square layout
            if feedCount <= 1 { return (1, 1) }
            return (2, 2)

        case .systemMedium:
            // 4×2 max — landscape: single row makes icons ~2× taller
            if feedCount <= 1 { return (1, 1) }
            if feedCount <= 4 { return (min(feedCount, 4), 1) }
            return (4, 2)

        case .systemLarge:
            // 4×4 max — square: halving grid dimensions doubles icon size
            if feedCount <= 1 { return (1, 1) }
            if feedCount <= 4 { return (2, 2) }
            if feedCount <= 9 { return (3, 3) }
            return (4, 4)

        default:
            return gridConfig
        }
    }

    var body: some View {
        Group {
            if entry.feeds.isEmpty {
                WidgetEmptyStateView(icon: "square.grid.2x2",
                                    message: NSLocalizedString("widget.empty.nosubscriptions", comment: ""))
            } else {
                gridView
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - Grid

    private var gridView: some View {
        let config = adaptiveGridConfig(feedCount: entry.feeds.count)
        let maxItems = config.columns * config.rows
        let feeds = Array(entry.feeds.prefix(maxItems))
        let spacing: CGFloat = family == .systemSmall ? 5 : 7

        return GeometryReader { geo in
            let totalHPad = spacing * CGFloat(config.columns - 1) + 6
            let totalVPad = spacing * CGFloat(config.rows - 1) + 6
            let coverW = (geo.size.width  - totalHPad) / CGFloat(config.columns)
            let coverH = (geo.size.height - totalVPad) / CGFloat(config.rows)
            let coverSize = min(coverW, coverH)

            VStack(spacing: spacing) {
                ForEach(0..<config.rows, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<config.columns, id: \.self) { col in
                            let index = row * config.columns + col
                            if index < feeds.count {
                                let feed = feeds[index]
                                Link(destination: tapURL(for: feed)) {
                                    podcastCover(feed: feed, size: coverSize)
                                }
                            } else {
                                // Empty cell — fill space so grid stays aligned
                                Color.clear
                                    .frame(width: coverSize, height: coverSize)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(3)
        }
    }

    // MARK: - Tap URL

    /// Tap plays the newest unplayed episode of the podcast.
    /// Falls back to opening the feed detail if no episode hash is available.
    private func tapURL(for feed: WFeed) -> URL {
        if let hash = feed.latestEpisodeHash, !hash.isEmpty {
            return ICWidgetConstants.episodeURL(objectHash: hash, action: "play")
        }
        return ICWidgetConstants.feedURL(feedUID: feed.id)
    }

    // MARK: - Podcast Cover Tile

    private func podcastCover(feed: WFeed, size: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            // Artwork
            Group {
                if let image = WidgetImageLoader.loadImage(relativePath: feed.localImagePath) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.15)
                        .fill(Color.gray.opacity(0.25))
                        .overlay(
                            Image(systemName: "mic.fill")
                                .foregroundColor(.gray.opacity(0.5))
                                .font(.system(size: size * 0.32))
                        )
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.15))

            // Unplayed badge
            if feed.unplayedCount > 0 {
                Text(feed.unplayedCount < 100 ? "\(feed.unplayedCount)" : "99+")
                    .font(.system(size: max(9, size * 0.16), weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(accentColor)
                    .clipShape(Capsule())
                    .offset(x: 3, y: -3)
            }
        }
        .accessibilityLabel(feed.title)
        .accessibilityHint(NSLocalizedString("widget.podcastgrid.playhint", comment: ""))
    }
}
