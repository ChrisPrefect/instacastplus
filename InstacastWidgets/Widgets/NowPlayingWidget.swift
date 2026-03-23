import WidgetKit
import SwiftUI
import AppIntents

struct NowPlayingWidget: Widget {
    let kind = ICWidgetConstants.nowPlayingWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName(NSLocalizedString("widget.nowplaying.name", comment: ""))
        .description(NSLocalizedString("widget.nowplaying.description", comment: ""))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Main View

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) var family

    private var accentColor: Color { WidgetAccentColor.color }

    @ViewBuilder
    private func playPauseControl(data: WNowPlaying, imageSystemName: String, font: Font) -> some View {
        Button(intent: PlayPauseIntent()) {
            Image(systemName: imageSystemName)
                .font(font)
        }
    }

    private func resolvedCurrentChapterIndex(data: WNowPlaying, episode: WEpisode) -> Int? {
        guard let chapters = data.chapters, !chapters.isEmpty else { return nil }

        // Resolve from position so chapter selection/seek updates are reflected
        // even when exported chapterIndex lags behind briefly.
        let currentPosition = TimeInterval(max(0, episode.position))
        var resolvedIndex = 0
        for (index, chapter) in chapters.enumerated() {
            if currentPosition >= chapter.startTime {
                resolvedIndex = index
            } else {
                break
            }
        }
        return resolvedIndex
    }

    private func displayedChapterTitle(data: WNowPlaying, episode: WEpisode) -> String? {
        guard let chapters = data.chapters,
              let index = resolvedCurrentChapterIndex(data: data, episode: episode),
              index >= 0, index < chapters.count else {
            if let title = data.chapterTitle, !title.isEmpty {
                return title
            }
            return nil
        }
        let title = chapters[index].title
        if !title.isEmpty {
            return title
        }
        if let fallbackTitle = data.chapterTitle, !fallbackTitle.isEmpty {
            return fallbackTitle
        }
        return nil
    }

    var body: some View {
        Group {
            if let data = entry.data, let episode = data.episode {
                switch family {
                case .systemSmall:
                    smallView(episode: episode, data: data)
                case .systemMedium:
                    mediumView(episode: episode, data: data)
                case .systemLarge:
                    largeView(episode: episode, data: data)
                default:
                    mediumView(episode: episode, data: data)
                }
            } else {
                WidgetEmptyStateView(icon: "play.circle", message: NSLocalizedString("widget.empty.noplayback", comment: ""))
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(ICWidgetConstants.playerURL())
    }

    // MARK: - Small

    private func smallView(episode: WEpisode, data: WNowPlaying) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Chapter art or podcast art
            artworkView(data: data, episode: episode, size: 58)

            Text(episode.title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .foregroundColor(.primary)

            Text(episode.feedTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundColor(.secondary)

            Spacer(minLength: 0)

            // Compact controls
            HStack(spacing: 14) {
                Button(intent: SkipBackwardIntent()) {
                    skipControlLabel(forward: false, seconds: skipBackwardSeconds(data: data), iconSize: 22)
                }

                playPauseControl(
                    data: data,
                    imageSystemName: data.isPaused ? "play.circle.fill" : "pause.circle.fill",
                    font: .system(size: 30)
                )

                Button(intent: SkipForwardIntent()) {
                    skipControlLabel(forward: true, seconds: skipForwardSeconds(data: data), iconSize: 22)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(accentColor)
        }
        .padding(2)
    }

    // MARK: - Medium

    private func mediumView(episode: WEpisode, data: WNowPlaying) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                // Chapter art
                artworkView(data: data, episode: episode, size: 82)

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(2)

                    Text(episode.feedTitle)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let chapterTitle = displayedChapterTitle(data: data, episode: episode) {
                        Text(chapterTitle)
                            .font(.system(size: 13))
                            .foregroundColor(accentColor)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // Progress
                    if episode.duration > 0 {
                        HStack(spacing: 8) {
                            ProgressBarView(progress: episode.progress, tintColor: accentColor)
                                .frame(height: 3)

                            Text(episode.formattedTimeLeft)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .fixedSize()
                        }
                    }
                }
            }

            // Controls row
            HStack(spacing: 16) {
                let canGoPrev = data.hasPreviousEpisode == true
                let canGoNext = data.hasNextEpisode == true

                Button(intent: PrevEpisodeIntent()) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 18))
                }
                .disabled(!canGoPrev)
                .foregroundColor(canGoPrev ? accentColor : .secondary.opacity(0.4))

                Button(intent: SkipBackwardIntent()) {
                    skipControlLabel(forward: false, seconds: skipBackwardSeconds(data: data), iconSize: 26)
                }
                .foregroundColor(accentColor)

                playPauseControl(
                    data: data,
                    imageSystemName: data.isPaused ? "play.circle.fill" : "pause.circle.fill",
                    font: .system(size: 36)
                )
                .foregroundColor(accentColor)

                Button(intent: SkipForwardIntent()) {
                    skipControlLabel(forward: true, seconds: skipForwardSeconds(data: data), iconSize: 26)
                }
                .foregroundColor(accentColor)

                Button(intent: NextEpisodeIntent()) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18))
                }
                .disabled(!canGoNext)
                .foregroundColor(canGoNext ? accentColor : .secondary.opacity(0.4))

                Spacer(minLength: 0)

                // Speed button
                Button(intent: CycleSpeedIntent()) {
                    Text(data.playbackSpeed ?? "1x")
                        .font(.system(size: 15, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(accentColor.opacity(0.12))
                        .cornerRadius(7)
                }
                .foregroundColor(accentColor)

                // Sleeptimer button
                Button(intent: ToggleSleepTimerIntent()) {
                    HStack(spacing: 2) {
                        Image(systemName: data.hasSleepTimer ? "moon.fill" : "moon")
                            .font(.system(size: 14))
                        if data.hasSleepTimer, let stopDate = data.sleepTimerStopDate {
                            Text(stopDate, style: .timer)
                                .font(.system(size: 13))
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(data.hasSleepTimer ? accentColor.opacity(0.12) : .clear)
                    .cornerRadius(7)
                }
                .foregroundColor(data.hasSleepTimer ? accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(2)
    }

    // MARK: - Large

    private func largeView(episode: WEpisode, data: WNowPlaying) -> some View {
        VStack(spacing: 8) {
            // Header: artwork + info
            HStack(spacing: 12) {
                artworkView(data: data, episode: episode, size: 90)

                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(2)

                    Text(episode.feedTitle)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if let chapterTitle = displayedChapterTitle(data: data, episode: episode) {
                        HStack(spacing: 4) {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 12))
                            Text(chapterTitle)
                                .font(.system(size: 14))
                                .lineLimit(1)
                        }
                        .foregroundColor(accentColor)
                    }

                    if let idx = resolvedCurrentChapterIndex(data: data, episode: episode), let count = data.chapterCount, count > 0 {
                        Text(String(format: NSLocalizedString("widget.chapter", comment: ""), idx + 1, count))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer(minLength: 0)
            }

            // Progress bar + time
            if episode.duration > 0 {
                VStack(spacing: 3) {
                    ProgressBarView(progress: episode.progress, tintColor: accentColor)
                        .frame(height: 4)

                    HStack {
                        Text(WEpisode.formatTime(Int(episode.position)))
                            .font(.system(size: 13))
                        Spacer()
                        Text(episode.formattedDuration)
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.secondary)
                }
            }

            // Main controls
            HStack(spacing: 20) {
                let canGoPrev = data.hasPreviousEpisode == true
                let canGoNext = data.hasNextEpisode == true

                Button(intent: PrevEpisodeIntent()) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 22))
                }
                .disabled(!canGoPrev)
                .foregroundColor(canGoPrev ? accentColor : .secondary.opacity(0.4))

                Button(intent: SkipBackwardIntent()) {
                    skipControlLabel(forward: false, seconds: skipBackwardSeconds(data: data), iconSize: 28)
                }
                .foregroundColor(accentColor)

                playPauseControl(
                    data: data,
                    imageSystemName: data.isPaused ? "play.circle.fill" : "pause.circle.fill",
                    font: .system(size: 48)
                )
                .foregroundColor(accentColor)

                Button(intent: SkipForwardIntent()) {
                    skipControlLabel(forward: true, seconds: skipForwardSeconds(data: data), iconSize: 28)
                }
                .foregroundColor(accentColor)

                Button(intent: NextEpisodeIntent()) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 22))
                }
                .disabled(!canGoNext)
                .foregroundColor(canGoNext ? accentColor : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)

            // Episode controls + speed + sleeptimer
            HStack(spacing: 12) {
                Spacer(minLength: 0)

                Button(intent: CycleSpeedIntent()) {
                    Text(data.playbackSpeed ?? "1x")
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(accentColor.opacity(0.15))
                        .cornerRadius(8)
                }

                Button(intent: ToggleSleepTimerIntent()) {
                    HStack(spacing: 3) {
                        Image(systemName: data.hasSleepTimer ? "moon.fill" : "moon")
                            .font(.system(size: 15))
                        if data.hasSleepTimer, let stopDate = data.sleepTimerStopDate {
                            Text(stopDate, style: .timer)
                                .font(.system(size: 14))
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(data.hasSleepTimer ? accentColor.opacity(0.15) : Color.clear)
                    .cornerRadius(8)
                }
                .foregroundColor(data.hasSleepTimer ? accentColor : .secondary)

                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            .foregroundColor(accentColor.opacity(0.8))

            // Chapter list (show chapters around the current one)
            if let chapters = data.chapters,
               !chapters.isEmpty,
               let currentIdx = resolvedCurrentChapterIndex(data: data, episode: episode) {
                Divider()
                chapterListView(chapters: chapters, currentIndex: currentIdx, episodeDuration: episode.duration)
            }

            Spacer(minLength: 0)
        }
        .padding(2)
    }

    // MARK: - Chapter List (Large widget)

    private func chapterListView(chapters: [WChapter], currentIndex: Int, episodeDuration: Int32) -> some View {
        // Show previous chapter + current + next 2 (max 4 visible, centered on current)
        let maxVisible = 4
        let startIdx: Int
        if chapters.count <= maxVisible {
            startIdx = 0
        } else if currentIndex <= 1 {
            startIdx = 0
        } else if currentIndex >= chapters.count - 2 {
            startIdx = max(0, chapters.count - maxVisible)
        } else {
            startIdx = currentIndex - 1
        }
        let endIdx = min(startIdx + maxVisible, chapters.count)
        let visibleChapters = Array(startIdx..<endIdx)

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(visibleChapters, id: \.self) { idx in
                let chapter = chapters[idx]
                let isCurrent = idx == currentIndex

                Button(intent: SkipToChapterIntent(chapterIndex: idx)) {
                    HStack(spacing: 8) {
                        // Chapter indicator
                        if isCurrent {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(accentColor)
                                .frame(width: 16, alignment: .trailing)
                        } else {
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.secondary)
                                .frame(width: 16, alignment: .trailing)
                        }

                        // Title
                        Text(chapter.title)
                            .font(.system(size: 14, weight: isCurrent ? .semibold : .regular))
                            .foregroundColor(isCurrent ? .primary : .secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        // Duration
                        Text(WEpisode.formatTime(Int(chapter.duration)))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .background(isCurrent ? accentColor.opacity(0.12) : Color.clear)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    /// Shows chapter artwork if available, otherwise podcast artwork
    private func artworkView(data: WNowPlaying, episode: WEpisode, size: CGFloat) -> some View {
        Group {
            if let chapterArt = data.chapterArtPath,
               let image = WidgetImageLoader.loadImage(relativePath: chapterArt) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let image = WidgetImageLoader.loadImage(relativePath: episode.localImagePath) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.12)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "headphones")
                            .font(.system(size: size * 0.3))
                            .foregroundColor(.gray.opacity(0.5))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }

    private func skipForwardSeconds(data: WNowPlaying) -> Int {
        let configured = data.skipForwardSeconds ?? 30
        return configured > 0 ? configured : 30
    }

    private func skipBackwardSeconds(data: WNowPlaying) -> Int {
        let configured = data.skipBackwardSeconds ?? 30
        return configured > 0 ? configured : 30
    }

    private func skipControlLabel(forward: Bool, seconds: Int, iconSize: CGFloat) -> some View {
        ZStack {
            Image(systemName: forward ? "goforward" : "gobackward")
                .font(.system(size: iconSize))
            Text("\(seconds)")
                .font(.system(size: max(10, iconSize * 0.42), weight: .semibold))
                .monospacedDigit()
                .offset(y: 0.5)
        }
    }
}
