import WidgetKit
import SwiftUI

// MARK: - Lock Screen Circular Widget (Play/Pause button)

struct LockScreenCircularWidget: Widget {
    let kind = "LockScreenCircularWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            LockScreenCircularView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.lockscreen.circular.name", comment: ""))
        .description(NSLocalizedString("widget.lockscreen.circular.description", comment: ""))
        .supportedFamilies([.accessoryCircular])
    }
}

struct LockScreenCircularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let data = entry.data, data.episode != nil {
            ZStack {
                if let episode = data.episode, episode.duration > 0 {
                    // Progress ring
                    AccessoryWidgetBackground()
                    ProgressView(value: episode.progress)
                        .progressViewStyle(.circular)
                }

                // Play/pause icon
                if data.isPaused {
                    Link(destination: ICWidgetConstants.playerURL(action: "playpause")) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                } else {
                    Button(intent: PlayPauseIntent()) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            // No playback
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "headphones")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
            }
            .widgetURL(ICWidgetConstants.playerURL())
        }
    }
}

// MARK: - Lock Screen Rectangular Widget (Episode info + controls)

struct LockScreenRectangularWidget: Widget {
    let kind = "LockScreenRectangularWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            LockScreenRectangularView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.lockscreen.rectangular.name", comment: ""))
        .description(NSLocalizedString("widget.lockscreen.rectangular.description", comment: ""))
        .supportedFamilies([.accessoryRectangular])
    }
}

struct LockScreenRectangularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let data = entry.data, let episode = data.episode {
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(1)
                    .widgetAccentable()

                Text(episode.feedTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundColor(.secondary)

                HStack(spacing: 0) {
                    // Progress bar
                    if episode.duration > 0 {
                        ProgressView(value: episode.progress)
                            .progressViewStyle(.linear)

                        Text(episode.formattedTimeLeft)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.leading, 4)
                            .fixedSize()
                    }
                }
            }
            .widgetURL(ICWidgetConstants.playerURL())
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("widget.empty.noplayback", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .widgetURL(ICWidgetConstants.playerURL())
        }
    }
}

// MARK: - Lock Screen Inline Widget (minimal text)

struct LockScreenInlineWidget: Widget {
    let kind = "LockScreenInlineWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            LockScreenInlineView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.lockscreen.inline.name", comment: ""))
        .description(NSLocalizedString("widget.lockscreen.inline.description", comment: ""))
        .supportedFamilies([.accessoryInline])
    }
}

struct LockScreenInlineView: View {
    let entry: NowPlayingEntry

    var body: some View {
        if let data = entry.data, let episode = data.episode {
            ViewThatFits {
                // Full: icon + title + time left
                HStack(spacing: 4) {
                    Image(systemName: data.isPaused ? "play.fill" : "pause.fill")
                    Text(episode.title)
                    Text("· \(episode.formattedTimeLeft)")
                        .foregroundColor(.secondary)
                }

                // Shorter: icon + title
                HStack(spacing: 4) {
                    Image(systemName: data.isPaused ? "play.fill" : "pause.fill")
                    Text(episode.title)
                }

                // Minimal: just title
                Text(episode.title)
            }
        } else {
            Text(NSLocalizedString("widget.empty.noplayback", comment: ""))
        }
    }
}
