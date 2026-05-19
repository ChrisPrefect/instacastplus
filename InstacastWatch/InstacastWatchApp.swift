import SwiftUI

@main
struct InstacastWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = WatchManifestStore.shared
    @StateObject private var player = WatchPlayerController.shared

    init() {
        WatchManifestStore.shared.load()
        WatchConnectivityController.shared.start()
        WatchDownloadManager.shared.startQueuedDownloads()
    }

    var body: some Scene {
        WindowGroup {
            WatchEpisodeListView()
                .environmentObject(store)
                .environmentObject(player)
                .onChange(of: scenePhase) { phase in
                    if phase != .active {
                        player.flushPlaybackState()
                    }
                }
        }
        .backgroundTask(.urlSession(WatchDownloadManager.backgroundSessionIdentifier)) {
            await WatchDownloadManager.shared.handleBackgroundEvents()
        }
    }
}
