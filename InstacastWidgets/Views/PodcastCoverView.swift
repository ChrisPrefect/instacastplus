import SwiftUI

/// Podcast cover image with optional unplayed badge.
struct PodcastCoverView: View {
    let feed: WFeed
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .topTrailing) {
            artworkView
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.15))

            if feed.unplayedCount > 0 {
                badgeView
            }
        }
        .accessibilityLabel(feed.title + (feed.unplayedCount > 0 ? ", \(feed.unplayedCount) unplayed" : ""))
    }

    private var artworkView: some View {
        Group {
            if let image = WidgetImageLoader.loadImage(relativePath: feed.localImagePath) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.15)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "mic.fill")
                            .foregroundColor(.gray.opacity(0.5))
                            .font(.system(size: size * 0.35))
                    )
            }
        }
    }

    private var badgeView: some View {
        Text("\(feed.unplayedCount)")
            .font(.system(size: max(9, size * 0.15), weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color.blue)
            .clipShape(Capsule())
            .offset(x: 2, y: -2)
    }
}
