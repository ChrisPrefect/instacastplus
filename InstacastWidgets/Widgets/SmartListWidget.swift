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
    }
}

// MARK: - Views

struct SmartListWidgetView: View {
    let entry: SmartListEntry
    @Environment(\.widgetFamily) var family

    private var maxEpisodes: Int {
        if entry.compact {
            switch family {
            case .systemSmall: return 1
            case .systemMedium: return 6   // 2 columns × 3 rows
            case .systemLarge: return 14   // 2 columns × 7 rows
            default: return 6
            }
        }
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 2
        case .systemLarge: return 6
        default: return 2
        }
    }

    /// Always opens player and starts playback
    private func episodeTapURL(for episode: WEpisode) -> URL {
        ICWidgetConstants.episodeURL(objectHash: episode.id, action: "openplay")
    }

    var body: some View {
        Group {
            if entry.episodes.isEmpty {
                WidgetEmptyStateView(icon: "tray", message: NSLocalizedString("widget.empty.noepisodes", comment: ""))
            } else {
                switch family {
                case .systemSmall:
                    smallView
                default:
                    if entry.compact {
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
                        if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.2))
                                .overlay(
                                    Image(systemName: "mic.fill")
                                        .foregroundColor(.gray.opacity(0.5))
                                        .font(.system(size: 18))
                                )
                                .frame(width: 50, height: 50)
                        }

                        Text(episode.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(2)
                            .foregroundColor(.primary)

                        Text(episode.feedTitle)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .foregroundColor(.secondary)

                        Spacer(minLength: 0)
                    }
                    .padding(2)
                }
            }
        }
    }

    // MARK: - Medium / Large (list)

    private var listView: some View {
        VStack(alignment: .leading, spacing: 0) {
            let items = Array(entry.episodes.prefix(maxEpisodes))
            ForEach(Array(items.enumerated()), id: \.element.id) { index, episode in
                Link(destination: episodeTapURL(for: episode)) {
                    EpisodeRowView(
                        episode: episode,
                        showFeedTitle: true,
                        feedTitleAbove: true,
                        showProgress: false,
                        widgetFamily: family
                    )
                }

                if index < items.count - 1 {
                    Divider()
                        .padding(.leading, 54)
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Compact Grid (2 columns, no header)

    private var compactGridView: some View {
        GeometryReader { geometry in
            let items = Array(entry.episodes.prefix(maxEpisodes))
            let rowCount = max(1, (items.count + 1) / 2)
            let contentHeight = max(0, geometry.size.height - 8)  // minimal vertical padding
            let rowSpacing: CGFloat = 3
            let rowsSpacingTotal = CGFloat(max(0, rowCount - 1)) * rowSpacing
            let cellHeight = max(26, (contentHeight - rowsSpacingTotal) / CGFloat(rowCount))

            VStack(spacing: rowSpacing) {
                ForEach(0..<rowCount, id: \.self) { row in
                    HStack(spacing: 6) {
                        let leftIdx = row * 2
                        let rightIdx = row * 2 + 1

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
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .clipped()
    }

    /// Compact episode cell for 2-column layout
    private func compactEpisodeCell(episode: WEpisode, height: CGFloat) -> some View {
        let artworkSize = max(26, min(36, height - 4))

        return HStack(spacing: 6) {
            // Artwork
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
                                .font(.system(size: 11))
                        )
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 1) {
                Text(episode.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
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
