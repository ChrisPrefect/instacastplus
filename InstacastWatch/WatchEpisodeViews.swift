import SwiftUI
import Foundation

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
                    UnavailableWatchView(title: "Nicht verfügbar", systemImage: "exclamationmark.triangle")
                }
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
                    playedIndicator
                    Text(episode.title)
                        .font(.headline)
                        .lineLimit(2)
                        .foregroundStyle(episode.consumed ? .secondary : .primary)
                }

                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let fraction = progressFraction {
                    ProgressView(value: fraction)
                        .tint(progressTint)
                }

                statusLine
                    .font(.caption2)
            }
        }
        .opacity(episode.consumed ? 0.72 : 1)
    }

    @ViewBuilder
    private var playedIndicator: some View {
        if episode.consumed {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "circle.fill")
                .foregroundStyle(accentColor)
                .font(.system(size: 9, weight: .semibold))
        }
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
        return "\(formatClock(playbackPosition)) / \(formatDuration(episode.displayDuration))"
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
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(episode.title)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(3)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)

            Text(episode.podcastTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ProgressView(value: playerProgressFraction)
                .progressViewStyle(.linear)
                .tint(accentColor)
                .scaleEffect(x: 1, y: 0.45, anchor: .center)

            HStack {
                Text(formatClock(Int(currentPosition.rounded())))
                Spacer()
                Text("-\(formatClock(max(0, Int((duration - currentPosition).rounded()))))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(alignment: .center) {
                CompactSkipButton(
                    forward: false,
                    seconds: episode.skipBackwardSeconds,
                    accentColor: accentColor
                ) {
                    player.seek(by: -Double(episode.skipBackwardSeconds))
                }

                Spacer(minLength: 8)

                Button {
                    player.togglePlayback(for: episode)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .frame(width: 52, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accentColor)

                Spacer(minLength: 8)

                CompactSkipButton(
                    forward: true,
                    seconds: episode.skipForwardSeconds,
                    accentColor: accentColor
                ) {
                    player.seek(by: Double(episode.skipForwardSeconds))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, -2)
        .onAppear {
            if episode.status == .downloaded, episode.localFileURL != nil, player.playingEpisodeHash != episode.episodeHash {
                _ = player.play(episode)
            }
        }
    }
}

private struct CompactSkipButton: View {
    let forward: Bool
    let seconds: Int
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: forward ? "goforward" : "gobackward")
                    .font(.system(size: 19, weight: .medium))
                Text(shortSkipText(seconds))
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 42, height: 38)
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

private func formatDuration(_ totalSeconds: Int) -> String {
    let seconds = max(0, totalSeconds)
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
        return "\(hours) h \(minutes) min"
    }
    return "\(minutes) min"
}

private func formatClock(_ totalSeconds: Int) -> String {
    let seconds = max(0, totalSeconds)
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
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
