import SwiftUI
import Foundation

struct WatchEpisodeListView: View {
    @EnvironmentObject private var store: WatchManifestStore
    @EnvironmentObject private var player: WatchPlayerController

    var body: some View {
        NavigationStack {
            Group {
                if store.sortedEpisodes.isEmpty {
                    UnavailableWatchView(title: "Keine Episoden", systemImage: "applewatch")
                } else {
                    List(store.sortedEpisodes) { episode in
                        NavigationLink(value: episode.episodeHash) {
                            WatchEpisodeRow(episode: episode)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                WatchDownloadManager.shared.removeEpisode(hash: episode.episodeHash)
                            } label: {
                                Label("Entfernen", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Instacast")
            .navigationDestination(for: String.self) { hash in
                if let episode = store.episode(hash: hash) {
                    WatchEpisodeDetailView(episodeHash: episode.episodeHash)
                } else {
                    UnavailableWatchView(title: "Nicht verfügbar", systemImage: "exclamationmark.triangle")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        WatchDownloadManager.shared.startQueuedDownloads()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Aktualisieren")
                }
            }
        }
    }
}

private struct WatchEpisodeRow: View {
    let episode: WatchEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(episode.title)
                .font(.headline)
                .lineLimit(2)
            Text(episode.podcastTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 6) {
                statusIcon
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(episode.consumed ? 0.65 : 1)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch episode.status {
        case .downloaded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .downloading:
            Image(systemName: "arrow.down.circle").foregroundStyle(.blue)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .removing:
            Image(systemName: "trash").foregroundStyle(.secondary)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch episode.status {
        case .downloaded:
            return remainingText
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

    private var remainingText: String {
        let seconds = episode.consumed ? episode.displayDuration : episode.remainingSeconds
        return formatDuration(seconds)
    }
}

struct WatchEpisodeDetailView: View {
    @EnvironmentObject private var store: WatchManifestStore
    @EnvironmentObject private var player: WatchPlayerController

    let episodeHash: String

    private var episode: WatchEpisode? {
        store.episode(hash: episodeHash)
    }

    var body: some View {
        Group {
            if let episode {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(episode.title)
                                .font(.headline)
                            Text(episode.podcastTitle)
                                .foregroundStyle(.secondary)
                            Text(formatDuration(episode.remainingSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        if episode.status == .downloaded {
                            Button {
                                player.togglePlayback(for: episode)
                            } label: {
                                Label(player.playingEpisodeHash == episode.episodeHash && player.isPlaying ? "Pause" : "Abspielen",
                                      systemImage: player.playingEpisodeHash == episode.episodeHash && player.isPlaying ? "pause.fill" : "play.fill")
                            }
                        }

                        if episode.status == .failed || episode.status == .queued {
                            Button {
                                WatchDownloadManager.shared.prioritizeEpisode(hash: episode.episodeHash)
                            } label: {
                                Label("Download erneut versuchen", systemImage: "arrow.clockwise")
                            }
                        }

                        Button(role: .destructive) {
                            WatchDownloadManager.shared.removeEpisode(hash: episode.episodeHash)
                        } label: {
                            Label("Von Watch entfernen", systemImage: "trash")
                        }
                    }

                    if episode.status == .downloading {
                        Section {
                            if let fraction = episode.progressFraction {
                                ProgressView(value: fraction)
                            } else {
                                Text(byteText(episode.downloadedBytes))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let error = episode.lastError, !error.isEmpty {
                        Section {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationTitle("Episode")
            } else {
                UnavailableWatchView(title: "Nicht verfügbar", systemImage: "exclamationmark.triangle")
            }
        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

private func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
