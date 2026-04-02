import SwiftUI
import WidgetKit

/// Reusable episode row view for widget lists.
struct EpisodeRowView: View {
    let episode: WEpisode
    let showFeedTitle: Bool
    let feedTitleAbove: Bool   // show podcast name above episode title
    let showProgress: Bool
    let widgetFamily: WidgetFamily

    init(episode: WEpisode, showFeedTitle: Bool = false, feedTitleAbove: Bool = false, showProgress: Bool = false, widgetFamily: WidgetFamily = .systemMedium) {
        self.episode = episode
        self.showFeedTitle = showFeedTitle
        self.feedTitleAbove = feedTitleAbove
        self.showProgress = showProgress
        self.widgetFamily = widgetFamily
    }

    var body: some View {
        HStack(spacing: 10) {
            // Artwork
            artworkView
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 1) {
                // Podcast name above episode title
                if showFeedTitle && feedTitleAbove {
                    Text(episode.feedTitle)
                        .font(.system(size: feedTitleFontSize, weight: .semibold))
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }

                Text(episode.title)
                    .font(.system(size: titleFontSize, weight: .regular))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                // Podcast name below episode title (legacy / non-above mode)
                if showFeedTitle && !feedTitleAbove {
                    Text(episode.feedTitle)
                        .font(.system(size: subtitleFontSize))
                        .lineLimit(1)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    if !episode.consumed {
                        Circle()
                            .fill(WidgetAccentColor.color)
                            .frame(width: 5, height: 5)
                    }

                    if episode.downloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 8))
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

    private var artworkSize: CGFloat {
        switch widgetFamily {
        case .systemSmall: return 44
        case .systemMedium: return 48
        case .systemLarge: return 46
        default: return 48
        }
    }

    private var feedTitleFontSize: CGFloat {
        widgetFamily == .systemSmall ? 10 : 11
    }

    private var titleFontSize: CGFloat {
        widgetFamily == .systemSmall ? 12 : 13
    }

    private var subtitleFontSize: CGFloat {
        widgetFamily == .systemSmall ? 11 : 11
    }
}
