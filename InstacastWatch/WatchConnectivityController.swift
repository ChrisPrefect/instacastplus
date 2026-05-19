import Foundation
import WatchConnectivity

enum WatchConnectivityDelivery {
    case reliable
    case live
    case current
}

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityController()

    private let dateFormatter = ISO8601DateFormatter()

    private override init() {
        super.init()
        dateFormatter.formatOptions = [.withInternetDateTime]
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(type: String, payload: [String: Any], delivery: WatchConnectivityDelivery = .reliable) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }

        var message = payload
        message["type"] = type

        switch delivery {
        case .reliable:
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil) { _ in
                    WCSession.default.transferUserInfo(message)
                }
            } else {
                WCSession.default.transferUserInfo(message)
            }
        case .live:
            guard WCSession.default.isReachable else { return }
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
        case .current:
            try? WCSession.default.updateApplicationContext(message)
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
            }
        }
    }

    func sendStorageStatus() {
        send(type: "watch.storageStatus", payload: [
            "freeBytes": WatchStorageManager.shared.freeBytes(),
            "instacastWatchDownloadBytes": WatchStorageManager.shared.downloadBytes(),
            "episodeCount": WatchManifestStore.shared.episodes.count,
            "lastCleanupDate": dateFormatter.string(from: Date()),
        ])
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            Task { @MainActor in
                self.sendStorageStatus()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        enqueue(payload: userInfo)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        enqueue(payload: message)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        enqueue(payload: message)
        replyHandler(["ok": true])
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        enqueue(payload: applicationContext)
    }

    private nonisolated func enqueue(payload: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0) else { return }
        Task { @MainActor in
            guard let payload = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
            self.handle(payload: payload)
        }
    }

    private func handle(payload: [String: Any]) {
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "manifest.replace":
            let entries = manifestEntries(from: payload["episodes"])
            WatchDownloadManager.shared.replaceManifest(entries: entries)
        case "manifest.upsertEpisodes":
            let entries = manifestEntries(from: payload["episodes"])
            WatchDownloadManager.shared.upsertManifest(entries: entries)
        case "manifest.removeEpisodes":
            let hashes = payload["episodeHashes"] as? [String] ?? []
            for hash in hashes {
                WatchDownloadManager.shared.removeEpisode(hash: hash)
            }
        case "download.prioritize":
            if let hash = payload["episodeHash"] as? String {
                WatchDownloadManager.shared.prioritizeEpisode(hash: hash)
            }
        case "download.cancel":
            if let hash = payload["episodeHash"] as? String {
                WatchDownloadManager.shared.cancelEpisode(hash: hash)
            }
        case "playback.phoneState":
            WatchPlayerController.shared.applyPhoneState(payload)
        default:
            break
        }
    }

    private func manifestEntries(from value: Any?) -> [WatchManifestEntry] {
        guard let dictionaries = value as? [[String: Any]] else { return [] }
        return dictionaries.compactMap { WatchManifestEntry(dictionary: $0, dateFormatter: dateFormatter) }
    }
}
