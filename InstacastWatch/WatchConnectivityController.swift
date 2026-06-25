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
        let episodes = WatchManifestStore.shared.episodes
        let downloaded = episodes.filter { $0.status == .downloaded }
        let downloadedBytes = downloaded.reduce(Int64(0)) { $0 + max(0, $1.actualFileSize) }
        // Sum of what the manifest *wants* on the watch (actual size if known, else the expected size).
        // Comparing this against freeBytes + downloadedBytes shows at a glance whether the desired
        // set can ever fit — the root signal for the eviction/re-download thrash.
        let wantedBytes = episodes.reduce(Int64(0)) { $0 + max($1.actualFileSize, $1.expectedBytes) }
        send(type: "watch.storageStatus", payload: [
            "freeBytes": WatchStorageManager.shared.freeBytes(),
            "usedBytes": WatchStorageManager.shared.usedBytes(),
            "totalBytes": WatchStorageManager.shared.totalBytes(),
            "instacastWatchDownloadBytes": WatchStorageManager.shared.downloadBytes(),
            "episodeCount": episodes.count,
            "downloadedCount": downloaded.count,
            "downloadedBytes": downloadedBytes,
            "wantedBytes": wantedBytes,
            "playingHash": WatchPlayerController.shared.playingEpisodeHash ?? "",
            "watchTimestamp": dateFormatter.string(from: Date()),
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
        WatchManifestStore.shared.updateAccentColorHex(payload["accentColorHex"] as? String)

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

@MainActor
enum WatchDiagnostics {
    static func log(_ event: String, message: String, metadata: [String: String] = [:], delivery: WatchConnectivityDelivery = .reliable) {
        var payloadMetadata = metadata
        payloadMetadata["event"] = event
        payloadMetadata["timestamp"] = timestamp()
        NSLog("[InstacastWatch][%@] %@ %@", event, message, payloadMetadata.description)
        WatchConnectivityController.shared.send(type: "watch.diagnostic", payload: [
            "event": event,
            "message": message,
            "metadata": payloadMetadata,
            "timestamp": payloadMetadata["timestamp"] ?? "",
        ], delivery: delivery)
    }

    static func metadata(for episode: WatchEpisode, prefix: String = "") -> [String: String] {
        var values: [String: String] = [
            "\(prefix)episodeHash": episode.episodeHash,
            "\(prefix)status": episode.status.rawValue,
            "\(prefix)mediaURLHash": stableHash(episode.mediaURL.absoluteString),
            "\(prefix)mediaHost": episode.mediaURL.host ?? "",
            "\(prefix)expectedBytes": "\(episode.expectedBytes)",
            "\(prefix)downloadedBytes": "\(episode.downloadedBytes)",
            "\(prefix)actualFileSize": "\(episode.actualFileSize)",
            "\(prefix)actualDuration": "\(episode.actualDuration)",
        ]
        if let localFileURL = episode.localFileURL {
            values["\(prefix)localFileName"] = localFileURL.lastPathComponent
            values["\(prefix)localPathHash"] = stableHash(localFileURL.path)
        }
        return values
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
