import WidgetKit
import SwiftUI

struct UpNextWidget: Widget {
    let kind = ICWidgetConstants.upNextWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.upnext.name", comment: ""))
        .description(NSLocalizedString("widget.upnext.description", comment: ""))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

// MARK: - Views

struct UpNextWidgetView: View {
    let entry: UpNextEntry
    @Environment(\.widgetFamily) var family

    private var maxQueueItems: Int {
        family == .systemLarge ? 5 : 2
    }

    var body: some View {
        Group {
            if let data = entry.data, (data.currentEpisode != nil || !data.queue.isEmpty) {
                contentView(data: data)
            } else {
                WidgetEmptyStateView(icon: "list.bullet", message: NSLocalizedString("widget.empty.noupnext", comment: ""))
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func contentView(data: WUpNext) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(NSLocalizedString("widget.upnext.header", comment: ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.bottom, 6)

            // Now Playing
            if let current = data.currentEpisode {
                Link(destination: ICWidgetConstants.playerURL()) {
                    HStack(spacing: 10) {
                        artworkView(episode: current, size: 50)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("widget.nowplaying.label", comment: ""))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.accentColor)

                            Text(current.title)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .foregroundColor(.primary)

                            HStack(spacing: 4) {
                                Image(systemName: data.isPaused ? "pause.fill" : "play.fill")
                                    .font(.system(size: 8))
                                Text(current.formattedTimeLeft + " " + NSLocalizedString("widget.left", comment: ""))
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                }

                if !data.queue.isEmpty {
                    Divider().padding(.vertical, 4)
                }
            }

            // Queue items
            let items = Array(data.queue.prefix(maxQueueItems))
            ForEach(Array(items.enumerated()), id: \.element.id) { index, episode in
                Link(destination: ICWidgetConstants.episodeURL(objectHash: episode.id, action: "play")) {
                    EpisodeRowView(episode: episode, showFeedTitle: family == .systemLarge, widgetFamily: family)
                }

                if index < items.count - 1 {
                    Divider().padding(.vertical, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(2)
    }

    private func artworkView(episode: WEpisode, size: CGFloat) -> some View {
        Group {
            if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "headphones").foregroundColor(.gray.opacity(0.5)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
