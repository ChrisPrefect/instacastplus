import SwiftUI
import WidgetKit

/// Reusable episode row view for widget lists.
struct EpisodeRowView: View {
    let episode: WEpisode
    let showFeedTitle: Bool
    let showProgress: Bool
    let widgetFamily: WidgetFamily

    init(episode: WEpisode, showFeedTitle: Bool = false, showProgress: Bool = false, widgetFamily: WidgetFamily = .systemMedium) {
        self.episode = episode
        self.showFeedTitle = showFeedTitle
        self.showProgress = showProgress
        self.widgetFamily = widgetFamily
    }

    var body: some View {
        HStack(spacing: 10) {
            // Artwork
            artworkView
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.system(size: titleFontSize, weight: .medium))
                    .lineLimit(widgetFamily == .systemLarge ? 2 : 1)
                    .foregroundColor(.primary)

                if showFeedTitle {
                    Text(episode.feedTitle)
                        .font(.system(size: subtitleFontSize))
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    // Status indicators
                    if !episode.consumed {
                        Circle()
                            .fill(WidgetAccentColor.color)
                            .frame(width: 6, height: 6)
                    }

                    if episode.downloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }

                    Text(episode.position > 0 ? episode.formattedTimeLeft + " " + NSLocalizedString("widget.left", comment: "") : episode.formattedDuration)
                        .font(.system(size: subtitleFontSize))
                        .foregroundColor(.secondary)
                }

                if showProgress && episode.duration > 0 && episode.position > 0 {
                    ProgressBarView(progress: episode.progress, tintColor: WidgetAccentColor.color)
                        .frame(height: 3)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(height: rowHeight)
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(episode.title + ", " + episode.feedTitle)
    }

    private var artworkView: some View {
        Group {
            if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "mic.fill")
                            .foregroundColor(.gray.opacity(0.5))
                            .font(.system(size: artworkSize * 0.4))
                    )
            }
        }
    }

    private var rowHeight: CGFloat {
        switch widgetFamily {
        case .systemMedium: return 48
        case .systemLarge: return 52
        default: return 44
        }
    }

    private var artworkSize: CGFloat {
        switch widgetFamily {
        case .systemSmall: return 40
        case .systemMedium: return 44
        case .systemLarge: return 44
        default: return 44
        }
    }

    private var titleFontSize: CGFloat {
        widgetFamily == .systemSmall ? 14 : 16
    }

    private var subtitleFontSize: CGFloat {
        widgetFamily == .systemSmall ? 12 : 13
    }
}
