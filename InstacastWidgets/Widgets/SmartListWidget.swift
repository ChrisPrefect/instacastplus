import WidgetKit
import SwiftUI
import AppIntents

struct SmartListWidget: Widget {
    let kind = ICWidgetConstants.smartListWidgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SmartListConfigIntent.self, provider: SmartListProvider()) { entry in
            SmartListWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.smartlist.name", comment: ""))
        .description(NSLocalizedString("widget.smartlist.description", comment: ""))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Views

struct SmartListWidgetView: View {
    let entry: SmartListEntry
    @Environment(\.widgetFamily) var family

    /// Max rows in non-compact (full-width) list mode
    private var maxListRows: Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 2
        case .systemLarge: return 6
        default: return 2
        }
    }

    private var maxEpisodes: Int {
        if entry.compact {
            switch family {
            case .systemSmall: return 4
            case .systemMedium: return 6   // 2 columns × 3 rows
            case .systemLarge: return 14   // 2 columns × 7 rows
            default: return 6
            }
        }
        return maxListRows
    }

    /// Always opens player and starts playback
    private func episodeTapURL(for episode: WEpisode) -> URL {
        ICWidgetConstants.episodeURL(objectHash: episode.id, action: "openplay")
    }

    var body: some View {
        Group {
            if entry.needsData {
                WidgetEmptyStateView(icon: "arrow.down.circle",
                                     message: NSLocalizedString("widget.needsdata", comment: ""),
                                     hint: NSLocalizedString("widget.needsdata.hint", comment: ""))
                    .widgetURL(ICWidgetConstants.refreshWidgetsURL())
            } else if entry.episodes.isEmpty {
                WidgetEmptyStateView(icon: "tray", message: NSLocalizedString("widget.empty.noepisodes", comment: ""))
            } else {
                switch family {
                case .systemSmall:
                    if !entry.compact || entry.episodes.count <= 1 {
                        smallView
                    } else if entry.episodes.count <= 2 {
                        smallListView
                    } else {
                        smallCompactView
                    }
                default:
                    if entry.compact && entry.episodes.count > maxListRows {
                        compactGridView
                    } else {
                        listView
                    }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: - Small (1 episode)

    private var smallView: some View {
        Group {
            if let episode = entry.episodes.first {
                Link(destination: episodeTapURL(for: episode)) {
                    VStack(alignment: .leading, spacing: 6) {
                        Spacer(minLength: 0)

                        if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .overlay(
                                    Image(systemName: "mic.fill")
                                        .foregroundColor(.gray.opacity(0.5))
                                        .font(.system(size: 16))
                                )
                                .frame(width: 44, height: 44)
                        }

                        Text(episode.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(3)
                            .foregroundColor(.primary)

                        Text(episode.feedTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .foregroundColor(.secondary)

                        Spacer(minLength: 0)
                    }
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Small List (2 episodes, full width)

    private var smallListView: some View {
        let items = Array(entry.episodes.prefix(2))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.id) { episode in
                Link(destination: episodeTapURL(for: episode)) {
                    EpisodeRowView(
                        episode: episode,
                        showFeedTitle: true,
                        feedTitleAbove: true,
                        showProgress: false,
                        widgetFamily: family
                    )
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Small Compact (3-4 episodes with small artwork)

    private var smallCompactView: some View {
        let items = Array(entry.episodes.prefix(4))
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.id) { episode in
                Link(destination: episodeTapURL(for: episode)) {
                    HStack(spacing: 8) {
                        Group {
                            if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.2))
                                    .overlay(
                                        Image(systemName: "mic.fill")
                                            .foregroundColor(.gray.opacity(0.5))
                                            .font(.system(size: 9))
                                    )
                            }
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                        Text(episode.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(2)
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Medium / Large (list)

    private var listView: some View {
        let items = Array(entry.episodes.prefix(maxEpisodes))
        let rowSpacing: CGFloat = family == .systemLarge ? 8 : 6

        return VStack(alignment: .leading, spacing: rowSpacing) {
            ForEach(items, id: \.id) { episode in
                Link(destination: episodeTapURL(for: episode)) {
                    EpisodeRowView(
                        episode: episode,
                        showFeedTitle: true,
                        feedTitleAbove: true,
                        showProgress: false,
                        widgetFamily: family
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, family == .systemLarge ? 12 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }

    // MARK: - Compact Grid (2 columns, no header)

    private var compactGridView: some View {
        GeometryReader { geometry in
            let items = Array(entry.episodes.prefix(maxEpisodes))
            let rowCount = max(1, (items.count + 1) / 2)
            let contentHeight = max(0, geometry.size.height - 16)  // vertical padding 8+8
            let rowSpacing: CGFloat = 3
            let rowsSpacingTotal = CGFloat(max(0, rowCount - 1)) * rowSpacing
            let cellHeight = max(26, (contentHeight - rowsSpacingTotal) / CGFloat(rowCount))

            VStack(spacing: rowSpacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 6) {
                        let leftIdx = compactGridIndex(row: row, column: 0, rowCount: rowCount)
                        let rightIdx = compactGridIndex(row: row, column: 1, rowCount: rowCount)

                        if leftIdx < items.count {
                            Link(destination: episodeTapURL(for: items[leftIdx])) {
                                compactEpisodeCell(episode: items[leftIdx], height: cellHeight)
                            }
                        }

                        if rightIdx < items.count {
                            Link(destination: episodeTapURL(for: items[rightIdx])) {
                                compactEpisodeCell(episode: items[rightIdx], height: cellHeight)
                            }
                        } else {
                            Spacer()
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .clipped()
    }

    private func compactGridIndex(row: Int, column: Int, rowCount: Int) -> Int {
        switch entry.order {
        case .columns:
            return column * rowCount + row
        case .rows:
            return row * 2 + column
        }
    }

    /// Compact episode cell for 2-column layout
    private func compactEpisodeCell(episode: WEpisode, height: CGFloat) -> some View {
        let artworkSize = max(30, min(42, height - 2))

        return HStack(spacing: 6) {
            // Artwork
            Group {
                if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: "mic.fill")
                                .foregroundColor(.gray.opacity(0.5))
                                .font(.system(size: 12))
                        )
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 1) {
                Text(episode.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                Text(episode.formattedTimeLeft)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
    }
}
