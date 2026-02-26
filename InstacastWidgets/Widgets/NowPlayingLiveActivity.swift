import ActivityKit
import WidgetKit
import SwiftUI

@available(iOS 16.2, *)
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingAttributes.self) { context in
            // Lock Screen / Banner presentation
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded: full controls
                DynamicIslandExpandedRegion(.leading) {
                    artworkView(imagePath: context.attributes.episodeImagePath, size: 52)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(spacing: 6) {
                        Button(intent: PlayPauseIntent()) {
                            Image(systemName: context.state.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 20))
                        }
                        Button(intent: SkipForwardIntent()) {
                            Image(systemName: ICWidgetConstants.skipSymbolName(forward: true, seconds: context.attributes.skipForwardSeconds))
                                .font(.system(size: 14))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(WidgetAccentColor.color)
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.episodeTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(context.attributes.feedTitle)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        if let chapter = context.state.chapterTitle {
                            Text(chapter)
                                .font(.system(size: 11))
                                .foregroundColor(WidgetAccentColor.color)
                                .lineLimit(1)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        ProgressView(value: context.state.progress)
                            .tint(WidgetAccentColor.color)
                        HStack {
                            Text(context.state.formattedTimeLeft)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(intent: CycleSpeedIntent()) {
                                Text(context.state.playbackSpeed)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            if context.state.hasSleepTimer {
                                Button(intent: ToggleSleepTimerIntent()) {
                                    Image(systemName: "moon.fill")
                                        .font(.system(size: 10))
                                }
                                .foregroundColor(WidgetAccentColor.color)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                EmptyView()
            } compactTrailing: {
                artworkView(imagePath: context.attributes.episodeImagePath, size: 26)
            } minimal: {
                artworkView(imagePath: context.attributes.episodeImagePath, size: 16)
            }
        }
    }

    // MARK: - Lock Screen Banner View
    //
    // Design: Large chapter/podcast art as blurred background.
    // Content: Chapter list (current + next 2, past chapters hidden) + controls row.
    // Episode title and feed title are intentionally omitted — they are already
    // shown by the iOS system player widget directly above the Live Activity.

    private func lockScreenView(context: ActivityViewContext<NowPlayingAttributes>) -> some View {
        ZStack {
            // Full-bleed background: chapter art or podcast art, blurred and dimmed
            lockScreenBackground(
                chapterArtPath: context.state.chapterArtPath,
                podcastArtPath: context.attributes.episodeImagePath
            )

            // Foreground content
            VStack(alignment: .leading, spacing: 10) {
                // Chapter list: current chapter highlighted, next 2 below
                if let chapters = context.state.chapterList, !chapters.isEmpty {
                    chapterListSection(chapters: chapters)
                } else if let chapterTitle = context.state.chapterTitle {
                    // Fallback: just show the current chapter title if no list available
                    Text(chapterTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // Bottom controls: skip back · speed · sleep timer · skip forward
                HStack(spacing: 0) {
                    Button(intent: SkipBackwardIntent()) {
                        Image(systemName: ICWidgetConstants.skipSymbolName(
                            forward: false,
                            seconds: context.attributes.skipBackwardSeconds))
                            .font(.system(size: 22))
                    }

                    Spacer()

                    Button(intent: CycleSpeedIntent()) {
                        Text(context.state.playbackSpeed)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                    }

                    Spacer()

                    Button(intent: ToggleSleepTimerIntent()) {
                        HStack(spacing: 4) {
                            Image(systemName: context.state.hasSleepTimer ? "moon.fill" : "moon")
                                .font(.system(size: 20))
                            if context.state.hasSleepTimer,
                               let stopDate = context.state.sleepTimerStopDate {
                                Text(stopDate, style: .timer)
                                    .font(.system(size: 13, weight: .medium))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .foregroundColor(context.state.hasSleepTimer
                                     ? WidgetAccentColor.color
                                     : .white.opacity(0.8))

                    Spacer()

                    Button(intent: SkipForwardIntent()) {
                        Image(systemName: ICWidgetConstants.skipSymbolName(
                            forward: true,
                            seconds: context.attributes.skipForwardSeconds))
                            .font(.system(size: 22))
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
            }
            .padding(16)
        }
        .activityBackgroundTint(.clear)
    }

    // MARK: - Chapter List (Lock Screen)

    @ViewBuilder
    private func chapterListSection(chapters: [WLAChapter]) -> some View {
        // Show at most 3 chapters: first entry in chapterList is always the current chapter.
        let visible = Array(chapters.prefix(3))
        VStack(alignment: .leading, spacing: 5) {
            ForEach(visible.indices, id: \.self) { idx in
                chapterRow(chapter: visible[idx], isCurrent: idx == 0)
            }
        }
    }

    private func chapterRow(chapter: WLAChapter, isCurrent: Bool) -> some View {
        var intent = SkipToChapterIntent()
        intent.chapterIndex = chapter.absoluteIndex

        return Button(intent: intent) {
            HStack(spacing: 6) {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(WidgetAccentColor.color)
                } else {
                    // Alignment spacer
                    Color.clear.frame(width: 7, height: 7)
                }

                Text(chapter.title)
                    .font(.system(size: isCurrent ? 14 : 12,
                                  weight: isCurrent ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text(formatChapterTime(chapter.startTime))
                    .font(.system(size: 10))
                    .foregroundColor(isCurrent ? .white.opacity(0.8) : .white.opacity(0.5))
            }
            .foregroundColor(isCurrent ? .white : .white.opacity(0.65))
        }
        .buttonStyle(.plain)
    }

    private func formatChapterTime(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
        }
        return "\(m):\(String(format: "%02d", s))"
    }

    // MARK: - Background Image Helper

    @ViewBuilder
    private func lockScreenBackground(chapterArtPath: String?, podcastArtPath: String?) -> some View {
        let imagePath = chapterArtPath ?? podcastArtPath
        if let image = WidgetImageLoader.loadImage(relativePath: imagePath) {
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 20)
                .overlay(Color.black.opacity(0.58))
                .clipped()
        } else {
            Color.black.opacity(0.85)
        }
    }

    // MARK: - Artwork Helper

    private func artworkView(imagePath: String?, size: CGFloat) -> some View {
        Group {
            if let image = WidgetImageLoader.loadImage(relativePath: imagePath) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: size * 0.12)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "headphones")
                            .font(.system(size: size * 0.35))
                            .foregroundColor(.gray)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.12))
    }
}
