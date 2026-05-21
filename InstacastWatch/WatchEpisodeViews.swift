import SwiftUI
import Foundation
import UIKit

struct WatchEpisodeListView: View {
    @EnvironmentObject private var store: WatchManifestStore
    @EnvironmentObject private var player: WatchPlayerController
    @State private var playerPath: [String] = []

    private var accentColor: Color {
        Color(hex: store.accentColorHex)
    }

    var body: some View {
        NavigationStack(path: $playerPath) {
            List {
                Text("InstacastPlus")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
                    .listRowBackground(Color.clear)

                if store.sortedEpisodes.isEmpty {
                    UnavailableWatchView(title: "Keine Episoden", systemImage: "tray")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(store.sortedEpisodes) { episode in
                        Button {
                            handleTap(episode)
                        } label: {
                            WatchEpisodeRow(
                                episode: episode,
                                accentColor: accentColor,
                                playbackPosition: playbackPosition(for: episode),
                                isCurrent: player.playingEpisodeHash == episode.episodeHash
                            )
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                WatchDownloadManager.shared.removeEpisode(hash: episode.episodeHash)
                            } label: {
                                Label("Von Watch entfernen", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .tint(accentColor)
            .navigationDestination(for: String.self) { episodeHash in
                if let episode = store.episode(hash: episodeHash) {
                    WatchPlayerView(episode: episode, accentColor: accentColor)
                } else {
                    Color.clear
                        .onAppear {
                            popUnavailablePlayerIfNeeded()
                        }
                }
            }
            .onChange(of: store.sortedEpisodes.map(\.episodeHash)) { _ in
                popUnavailablePlayerIfNeeded()
            }
            .onAppear {
                popUnavailablePlayerIfNeeded()
            }
        }
    }

    private func handleTap(_ episode: WatchEpisode) {
        if episode.status == .downloaded, episode.localFileURL != nil {
            if player.play(episode) {
                playerPath = [episode.episodeHash]
            }
        } else {
            WatchDownloadManager.shared.prioritizeEpisode(hash: episode.episodeHash)
        }
    }

    private func playbackPosition(for episode: WatchEpisode) -> Int {
        if player.playingEpisodeHash == episode.episodeHash {
            return max(0, Int(player.currentPosition.rounded()))
        }
        return episode.lastPlaybackPosition
    }

    private func popUnavailablePlayerIfNeeded() {
        guard let visibleHash = playerPath.last, store.episode(hash: visibleHash) == nil else { return }
        playerPath.removeAll()
    }
}

private struct WatchEpisodeRow: View {
    let episode: WatchEpisode
    let accentColor: Color
    let playbackPosition: Int
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            WatchArtworkView(imageURL: episode.imageURL)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if episode.consumed {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundStyle(episode.consumed ? .secondary : .primary)
                }

                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let fraction = progressFraction {
                    ThinProgressLine(fraction: fraction, tint: progressTint)
                }

                statusLine
                    .font(.caption2)
            }
        }
        .opacity(episode.consumed ? 0.72 : 1)
    }

    private var secondaryText: String {
        if let subtitle = episode.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        return episode.podcastTitle
    }

    private var progressFraction: Double? {
        if episode.status == .downloading {
            return episode.progressFraction
        }
        let duration = episode.displayDuration
        guard duration > 0, playbackPosition > 0 || isCurrent else { return nil }
        return min(1.0, max(0.0, Double(playbackPosition) / Double(duration)))
    }

    private var progressTint: Color {
        episode.status == .downloading ? .blue : accentColor
    }

    @ViewBuilder
    private var statusLine: some View {
        switch episode.status {
        case .downloaded:
            Text(playbackText)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .downloading:
            Label(statusText, systemImage: "arrow.down.circle")
                .foregroundStyle(.blue)
                .lineLimit(1)
        case .failed:
            Label(statusText, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .removing:
            Label(statusText, systemImage: "trash")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        case .queued:
            Label(statusText, systemImage: "clock")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var statusText: String {
        switch episode.status {
        case .downloaded:
            return playbackText
        case .downloading:
            if let fraction = episode.progressFraction {
                return "\(Int(fraction * 100)) %"
            }
            return byteText(episode.downloadedBytes)
        case .failed:
            return NSLocalizedString("Fehler", comment: "")
        case .removing:
            return NSLocalizedString("Wird entfernt", comment: "")
        case .queued:
            return NSLocalizedString("Wartet", comment: "")
        }
    }

    private var playbackText: String {
        if episode.consumed {
            return NSLocalizedString("Gespielt", comment: "")
        }
        return "\(formatCompactDuration(playbackPosition)) / \(formatCompactDuration(episode.displayDuration))"
    }
}

private struct WatchArtworkView: View {
    let imageURL: URL?

    var body: some View {
        AsyncImage(url: imageURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            default:
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct WatchPlayerView: View {
    @EnvironmentObject private var player: WatchPlayerController

    let episode: WatchEpisode
    let accentColor: Color

    private var duration: Double {
        max(1, Double(episode.displayDuration))
    }

    private var currentPosition: Double {
        if player.playingEpisodeHash == episode.episodeHash {
            return min(duration, max(0, player.currentPosition))
        }
        return min(duration, max(0, Double(episode.lastPlaybackPosition)))
    }

    private var playerProgressFraction: Double {
        min(1.0, max(0.0, currentPosition / duration))
    }

    private var currentChapter: WatchChapter? {
        episode.currentChapter(at: currentPosition)
    }

    private var chapterTitle: String? {
        currentChapter?.title
    }

    private var chapterTitleText: String {
        let title = chapterTitle ?? ""
        return title.isEmpty ? " " : title
    }

    private var hasChapterTitle: Bool {
        guard let chapterTitle else { return false }
        return !chapterTitle.isEmpty
    }

    private var chapterArtworkURL: URL? {
        guard
            let currentChapter,
            let imageFileName = currentChapter.imageFileName,
            let baseURL = episode.chapterArtworkBaseURL
        else {
            return nil
        }
        return baseURL.appendingPathComponent(imageFileName)
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 220

            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                WatchPlayerHeader(
                    episode: episode,
                    chapterArtworkURL: chapterArtworkURL,
                    compact: compact
                )

                if compact {
                    if hasChapterTitle {
                        Text(chapterTitleText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accentColor)
                            .lineLimit(2, reservesSpace: true)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                } else {
                    Text(chapterTitleText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(2, reservesSpace: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                ScrubbableProgressLine(
                    fraction: playerProgressFraction,
                    chapters: episode.chapters,
                    duration: duration,
                    tint: accentColor,
                    compact: compact
                ) { fraction in
                    player.seek(to: duration * fraction)
                }

                HStack {
                    Text(formatPlayerTime(Int(currentPosition.rounded())))
                    Spacer()
                    Text("-\(formatPlayerTime(max(0, Int((duration - currentPosition).rounded()))))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(alignment: .center) {
                    CompactSkipButton(
                        forward: false,
                        seconds: episode.skipBackwardSeconds,
                        accentColor: accentColor,
                        compact: compact
                    ) {
                        player.seek(by: -Double(episode.skipBackwardSeconds))
                    }

                    Spacer(minLength: 8)

                    Button {
                        player.togglePlayback(for: episode)
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: compact ? 24 : 28, weight: .semibold))
                            .frame(width: compact ? 44 : 50, height: compact ? 30 : 36)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accentColor)

                    Spacer(minLength: 8)

                    CompactSkipButton(
                        forward: true,
                        seconds: episode.skipForwardSeconds,
                        accentColor: accentColor,
                        compact: compact
                    ) {
                        player.seek(by: Double(episode.skipForwardSeconds))
                    }
                }
            }
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.top, compact ? 4 : 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            if episode.status == .downloaded, episode.localFileURL != nil, player.playingEpisodeHash != episode.episodeHash {
                _ = player.play(episode)
            }
        }
    }
}

private struct WatchPlayerHeader: View {
    let episode: WatchEpisode
    let chapterArtworkURL: URL?
    let compact: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let chapterArtworkURL {
                ChapterArtworkImage(url: chapterArtworkURL)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(compact ? 2 : 3)
                    .minimumScaleFactor(0.72)
                    .fixedSize(horizontal: false, vertical: true)

                Text(episode.podcastTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct ChapterArtworkImage: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .task(id: url) {
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

private struct CompactSkipButton: View {
    let forward: Bool
    let seconds: Int
    let accentColor: Color
    let compact: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: forward ? "goforward" : "gobackward")
                    .font(.system(size: compact ? 17 : 18, weight: .medium))
                Text(shortSkipText(seconds))
                    .font(.system(size: compact ? 9 : 10, weight: .semibold))
            }
            .frame(width: compact ? 36 : 40, height: compact ? 30 : 34)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accentColor)
        .accessibilityLabel(NSLocalizedString(forward ? "Skipping Forward" : "Skipping Back", comment: ""))
        .accessibilityValue(shortSkipText(seconds))
    }
}

private struct UnavailableWatchView: View {
    let title: LocalizedStringKey
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

private struct ThinProgressLine: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(1.0, max(0.0, fraction)))
            }
        }
        .frame(height: 2)
    }
}

private struct ScrubbableProgressLine: View {
    let fraction: Double
    let chapters: [WatchChapter]
    let duration: Double
    let tint: Color
    let compact: Bool
    let onScrub: (Double) -> Void

    private var chapterMarkerFractions: [Double] {
        guard duration > 1 else { return [] }
        return chapters
            .map { Double($0.startSeconds) / duration }
            .filter { $0 > 0 && $0 < 1 }
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: compact ? 7 : 9)
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * min(1.0, max(0.0, fraction)), height: compact ? 7 : 9)
                ForEach(chapterMarkerFractions, id: \.self) { markerFraction in
                    ChapterMarkerLine(height: compact ? 9 : 12)
                        .offset(x: max(0, min(proxy.size.width - 1, proxy.size.width * markerFraction)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard proxy.size.width > 0 else { return }
                        let fraction = min(1.0, max(0.0, value.location.x / proxy.size.width))
                        onScrub(fraction)
                    }
            )
        }
        .frame(height: compact ? 16 : 20)
    }
}

private struct ChapterMarkerLine: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.35))
            .frame(width: 1, height: height)
    }
}

private func formatCompactDuration(_ totalSeconds: Int) -> String {
    let minutes = max(0, totalSeconds) / 60
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if hours > 0 {
        if remainingMinutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remainingMinutes)m"
    }
    return "\(minutes)m"
}

private func formatPlayerTime(_ totalSeconds: Int) -> String {
    let seconds = max(0, totalSeconds)
    let hours = seconds / 3600
    let minutes = (seconds / 60) % 60
    let remainingSeconds = seconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%d:%02d", minutes, remainingSeconds)
}

private func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func shortSkipText(_ seconds: Int) -> String {
    let value = max(1, seconds)
    if value >= 60, value % 60 == 0 {
        return "\(value / 60)m"
    }
    return "\(value)s"
}

private extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
            self = Color(red: 1.0, green: 83.0 / 255.0, blue: 0.0)
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
