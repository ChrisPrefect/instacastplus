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

    private var accentColor: Color { WidgetAccentColor.color }

    private var maxEpisodes: Int {
        switch family {
        case .systemSmall: return 1
        case .systemMedium: return 2   // 3 rows at 52pt each don't fit in ~141pt medium height
        case .systemLarge: return 5
        default: return 2
        }
    }

    /// Build the URL for tapping an episode, based on the configured tap action
    private func episodeTapURL(for episode: WEpisode) -> URL {
        return ICWidgetConstants.episodeURL(objectHash: episode.id, action: "play")
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
                    listView
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
                        HStack {
                            Text(entry.listName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
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
            // Header — fixed height
            Link(destination: entry.listId == ICWidgetConstants.upNextListId
                 ? ICWidgetConstants.queueURL
                 : ICWidgetConstants.listURL(listUID: entry.listId)) {
                HStack {
                    Text(entry.listName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()

                    // Show tap mode indicator
                    if entry.tapAction == .play {
                        Image(systemName: "play.circle")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(height: 24)

            // Episode rows — fixed height each
            let items = Array(entry.episodes.prefix(maxEpisodes))
            ForEach(Array(items.enumerated()), id: \.element.id) { index, episode in
                Link(destination: episodeTapURL(for: episode)) {
                    EpisodeRowView(
                        episode: episode,
                        showFeedTitle: family == .systemLarge,
                        showProgress: family == .systemLarge,
                        widgetFamily: family
                    )
                }

                if index < items.count - 1 {
                    Divider()
                        .padding(.leading, 54)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(2)
        .clipped()
    }
}
