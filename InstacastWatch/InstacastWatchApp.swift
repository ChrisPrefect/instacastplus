import SwiftUI

@main
struct InstacastWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = WatchManifestStore.shared
    private let player = WatchPlayerController.shared

    init() {
        Task { @MainActor in
            await WatchManifestStore.shared.load()
            WatchConnectivityController.shared.start()
            WatchPlayerController.shared.checkForUnexpectedTermination()
            WatchDownloadManager.shared.startQueuedDownloads()
        }
    }

    var body: some Scene {
        WindowGroup {
            WatchEpisodeListView()
                .environmentObject(store)
                .onChange(of: scenePhase) { phase in
                    if phase != .active {
                        player.flushPlaybackState()
                    }
                    // Correlate playback drop-outs with the app losing the foreground: if audio
                    // stops shortly after the app goes inactive/background, that points at OS
                    // suspension rather than a file/decoding problem.
                    WatchDiagnostics.log("scene-phase", message: "Watch-Szenenphase", metadata: [
                        "phase": String(describing: phase),
                        "isPlaying": player.isPlaying ? "true" : "false",
                        "playingHash": player.playingEpisodeHash ?? "",
                    ])
                }
        }
        .backgroundTask(.urlSession(WatchDownloadManager.backgroundSessionIdentifier)) {
            await WatchDownloadManager.shared.handleBackgroundEvents()
        }
    }
}
