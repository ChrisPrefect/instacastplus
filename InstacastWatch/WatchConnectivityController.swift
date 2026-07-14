import Foundation
import WatchConnectivity

enum WatchConnectivityDelivery {
    case durable
    case reliable
    case live
    case current
}

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchConnectivityController()

    private let dateFormatter = ISO8601DateFormatter()
    private let watchEventRevisionKey = "InstacastWatchEventRevision"
    private let reportedTerminalStateSignaturesKey = "InstacastWatchReportedTerminalStateSignatures"
    private var lastWatchEventRevision: Int64 = 0
    private var reportedTerminalStateSignatures: [String: String] = [:]
    private var inFlightTerminalStateIdentifiers: Set<String> = []
    private(set) var phoneWatchEventProtocolVersion = 1
    private var manifestInboxProcessing = false
    private var manifestInboxProcessingRequested = false
    private var storageStatusScanInFlight = false
    private var storageStatusResendRequested = false

    var supportsDeletionAcknowledgementBatches: Bool {
        phoneWatchEventProtocolVersion >= 2
    }

    private func advancePhoneWatchEventProtocolVersion(to version: Int) {
        phoneWatchEventProtocolVersion = max(
            phoneWatchEventProtocolVersion,
            max(1, version)
        )
    }

    private override init() {
        super.init()
        dateFormatter.formatOptions = [.withInternetDateTime]
        lastWatchEventRevision = (UserDefaults.standard.object(forKey: watchEventRevisionKey) as? NSNumber)?.int64Value ?? 0
        reportedTerminalStateSignatures = UserDefaults.standard.dictionary(forKey: reportedTerminalStateSignaturesKey) as? [String: String] ?? [:]
    }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @discardableResult
    func send(type: String, payload: [String: Any], delivery: WatchConnectivityDelivery = .reliable) -> Bool {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return false }
        if case .live = delivery, !WCSession.default.isReachable {
            return false
        }

        var message = payload
        message["type"] = type
        if let episodeHash = payload["episodeHash"] as? String,
           let episode = WatchManifestStore.shared.episode(hash: episodeHash),
           !episode.selectionIdentifier.isEmpty {
            message["selectionIdentifier"] = episode.selectionIdentifier
        }
        message["watchEventRevision"] = NSNumber(value: nextWatchEventRevision())

        switch delivery {
        case .durable:
            WCSession.default.transferUserInfo(message)
            return true
        case .reliable:
            if WCSession.default.isReachable {
                // WatchConnectivity invokes the error handler on its own NSOperationQueue and the
                // SDK block is not NS_SWIFT_SENDABLE — without @Sendable this closure inherits the
                // surrounding MainActor isolation (Swift 6) and the runtime traps off-main with
                // EXC_BREAKPOINT. Every FAILED reliable send crashed the whole app ("crasht sofort
                // beim Play", 11 identische .ips vom 05.07.). The message copy is a local value
                // type that is never mutated again, so handing it across is safe.
                nonisolated(unsafe) let fallbackMessage = message
                WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: { @Sendable _ in
                    WCSession.default.transferUserInfo(fallbackMessage)
                })
            } else {
                WCSession.default.transferUserInfo(message)
            }
            return true
        case .live:
            guard WCSession.default.isReachable else { return false }
            WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
            return true
        case .current:
            var accepted = true
            do {
                try WCSession.default.updateApplicationContext(message)
            } catch {
                accepted = false
            }
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
                accepted = true
            }
            return accepted
        }
    }

    func advanceWatchEventRevisionFloor(to revision: Int64?) {
        guard let revision, revision > lastWatchEventRevision else { return }
        lastWatchEventRevision = revision
        UserDefaults.standard.set(NSNumber(value: revision), forKey: watchEventRevisionKey)
    }

    @discardableResult
    func reportTerminalDownloadState(forEpisodeHash episodeHash: String) -> Bool {
        guard let episode = WatchManifestStore.shared.episode(hash: episodeHash) else { return false }
        guard let terminalStateSignature = terminalStateSignature(for: episode) else { return false }
        let type: String
        var payload: [String: Any] = [
            "episodeHash": episode.episodeHash,
            "timestamp": dateFormatter.string(from: Date()),
        ]
        switch episode.status {
        case .downloaded:
            type = "watch.downloaded"
            payload["actualFileSize"] = episode.actualFileSize
            payload["actualDuration"] = episode.actualDuration
        case .failed:
            type = "watch.downloadFailed"
            payload["error"] = episode.lastError ?? ""
        case .evicted:
            type = "watch.downloadEvicted"
            payload["reason"] = "storageFull"
        default:
            return false
        }

        if reportedTerminalStateSignatures[episode.episodeHash] == terminalStateSignature {
            return true
        }
        let transferIdentifier = terminalStateIdentifier(
            episodeHash: episode.episodeHash,
            terminalStateSignature: terminalStateSignature
        )
        if inFlightTerminalStateIdentifiers.contains(transferIdentifier) {
            return true
        }
        payload["terminalStateSignature"] = terminalStateSignature
        let accepted = send(type: type, payload: payload, delivery: .durable)
        guard accepted else { return false }
        inFlightTerminalStateIdentifiers.insert(transferIdentifier)
        return true
    }

    func clearReportedTerminalDownloadState(forEpisodeHash episodeHash: String) {
        for transfer in WCSession.default.outstandingUserInfoTransfers
        where transfer.userInfo["episodeHash"] as? String == episodeHash
            && transfer.userInfo["terminalStateSignature"] as? String != nil {
            transfer.cancel()
        }
        let prefix = "\(episodeHash)\u{001F}"
        inFlightTerminalStateIdentifiers = Set(
            inFlightTerminalStateIdentifiers.filter { !$0.hasPrefix(prefix) }
        )
        if reportedTerminalStateSignatures.removeValue(forKey: episodeHash) != nil {
            persistReportedTerminalStateSignatures()
        }
    }

    private func terminalStateSignature(for episode: WatchEpisode) -> String? {
        guard !episode.hasPlaybackFileRemovalError else { return nil }
        guard episode.status == .downloaded || episode.status == .failed || episode.status == .evicted else {
            return nil
        }
        return [
            episode.selectionIdentifier,
            episode.status.rawValue,
            String(episode.actualFileSize),
            String(episode.actualDuration),
            episode.lastError ?? "",
        ].joined(separator: "|")
    }

    private func terminalStateIdentifier(episodeHash: String, terminalStateSignature: String) -> String {
        "\(episodeHash)\u{001F}\(terminalStateSignature)"
    }

    private func restoreOutstandingTerminalStateTransfers() {
        inFlightTerminalStateIdentifiers = Set(
            WCSession.default.outstandingUserInfoTransfers.compactMap { transfer in
                guard let episodeHash = transfer.userInfo["episodeHash"] as? String,
                      let signature = transfer.userInfo["terminalStateSignature"] as? String else {
                    return nil
                }
                return terminalStateIdentifier(
                    episodeHash: episodeHash,
                    terminalStateSignature: signature
                )
            }
        )
    }

    private func completeTerminalStateTransfer(
        episodeHash: String,
        terminalStateSignature: String,
        errorDescription: String?
    ) {
        let transferIdentifier = terminalStateIdentifier(
            episodeHash: episodeHash,
            terminalStateSignature: terminalStateSignature
        )
        guard inFlightTerminalStateIdentifiers.remove(transferIdentifier) != nil else { return }

        if let errorDescription {
            WatchDiagnostics.log(
                "terminal-state-transfer-failed",
                message: "Watch-Endstatus konnte nicht an das iPhone übertragen werden",
                metadata: ["episodeHash": episodeHash, "error": errorDescription]
            )
            _ = reportTerminalDownloadState(forEpisodeHash: episodeHash)
            return
        }

        guard let episode = WatchManifestStore.shared.episode(hash: episodeHash),
              self.terminalStateSignature(for: episode) == terminalStateSignature else {
            _ = reportTerminalDownloadState(forEpisodeHash: episodeHash)
            return
        }
        reportedTerminalStateSignatures[episodeHash] = terminalStateSignature
        persistReportedTerminalStateSignatures()
    }

    private func replayPendingTerminalDownloadStates() {
        let currentHashes = Set(WatchManifestStore.shared.episodes.map(\.episodeHash))
        let staleHashes = Set(reportedTerminalStateSignatures.keys).subtracting(currentHashes)
        if !staleHashes.isEmpty {
            for hash in staleHashes {
                reportedTerminalStateSignatures.removeValue(forKey: hash)
            }
            persistReportedTerminalStateSignatures()
        }
        for episode in WatchManifestStore.shared.episodes {
            _ = reportTerminalDownloadState(forEpisodeHash: episode.episodeHash)
        }
    }

    private func persistReportedTerminalStateSignatures() {
        UserDefaults.standard.set(reportedTerminalStateSignatures, forKey: reportedTerminalStateSignaturesKey)
    }

    private func nextWatchEventRevision() -> Int64 {
        let previousRevision = lastWatchEventRevision
        let wallClockRevision = Int64(Date().timeIntervalSince1970 * 1_000)
        let nextRevision = max(wallClockRevision, previousRevision + 1)
        lastWatchEventRevision = nextRevision
        UserDefaults.standard.set(NSNumber(value: nextRevision), forKey: watchEventRevisionKey)
        return nextRevision
    }

    func sendStorageStatus() {
        guard !storageStatusScanInFlight else {
            storageStatusResendRequested = true
            return
        }
        storageStatusScanInFlight = true
        let episodes = WatchManifestStore.shared.episodes
        Task { @MainActor in
            let measurements = await WatchStorageManager.measureStatus(for: episodes)
            finishStorageStatus(measurements: measurements)
        }
    }

    private func finishStorageStatus(measurements: WatchStorageStatusMeasurements) {
        WatchStorageManager.shared.recordMeasurements(measurements)
        // Sum of what the manifest *wants* on the watch (actual size if known, else the expected size).
        // Comparing this against freeBytes + downloadedBytes shows at a glance whether the desired
        // set can ever fit — the root signal for the eviction/re-download thrash.
        send(type: "watch.storageStatus", payload: [
            "freeBytes": measurements.freeBytes,
            // Diagnostics only: the old typed Swift Int value that truncated into negatives on
            // watchOS arm64_32. freeBytes is the raw NSNumber Int64 value used for gating.
            "rawFreeBytes": measurements.rawFreeBytes,
            "usedBytes": measurements.usedBytes,
            "totalBytes": measurements.totalBytes,
            "instacastWatchDownloadBytes": measurements.downloadBytes,
            "episodeCount": measurements.episodeCount,
            "downloadedCount": measurements.downloadedCount,
            "downloadedBytes": measurements.downloadedBytes,
            "wantedBytes": measurements.wantedBytes,
            "playingHash": WatchPlayerController.shared.playingEpisodeHash ?? "",
            "watchTimestamp": dateFormatter.string(from: Date()),
            "lastCleanupDate": dateFormatter.string(from: Date()),
        ], delivery: .live)

        storageStatusScanInFlight = false
        if storageStatusResendRequested {
            storageStatusResendRequested = false
            sendStorageStatus()
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            let eventProtocolVersion = max(
                1,
                (session.receivedApplicationContext["watchEventProtocolVersion"] as? NSNumber)?.intValue ?? 1
            )
            Task { @MainActor in
                await WatchManifestStore.shared.load()
                self.advancePhoneWatchEventProtocolVersion(to: eventProtocolVersion)
                self.resumePendingManifestTransfers()
                WatchDownloadManager.shared.finalizePendingRemovalsAfterConnectivityActivation()
                self.restoreOutstandingTerminalStateTransfers()
                self.replayPendingTerminalDownloadStates()
                self.send(type: "watch.requestManifest", payload: [
                    "timestamp": self.dateFormatter.string(from: Date()),
                    "manifestProtocolVersion": 3,
                ], delivery: .durable)
                self.sendStorageStatus()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        enqueue(payload: userInfo)
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: Error?
    ) {
        guard let episodeHash = userInfoTransfer.userInfo["episodeHash"] as? String,
              let terminalStateSignature = userInfoTransfer.userInfo["terminalStateSignature"] as? String else {
            return
        }
        let errorDescription = error?.localizedDescription
        Task { @MainActor in
            self.completeTerminalStateTransfer(
                episodeHash: episodeHash,
                terminalStateSignature: terminalStateSignature,
                errorDescription: errorDescription
            )
        }
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

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let revision = (file.metadata?["manifestRevision"] as? NSNumber)?.int64Value
        do {
            guard let revision, revision > 0 else { throw WatchManifestTransferError.invalidRevision }
            _ = try WatchManifestTransferInbox.stage(fileURL: file.fileURL, revision: revision)
            Task { @MainActor in
                self.scheduleManifestInboxProcessing()
            }
        } catch {
            let errorDescription = error.localizedDescription
            Task { @MainActor in
                self.manifestCommitFailed(errorDescription: errorDescription, revision: revision)
            }
        }
    }

    private func resumePendingManifestTransfers() {
        scheduleManifestInboxProcessing()
    }

    private func scheduleManifestInboxProcessing() {
        guard !manifestInboxProcessing else {
            manifestInboxProcessingRequested = true
            return
        }
        manifestInboxProcessing = true
        manifestInboxProcessingRequested = false
        Task.detached(priority: .utility) { [self] in
            var processingURL: URL?
            var processingRevision: Int64?
            do {
                let pendingURLs = try WatchManifestTransferInbox.pendingFileURLs()
                guard let newestURL = pendingURLs.last,
                      let revision = WatchManifestTransferInbox.revision(fileURL: newestURL) else {
                    await self.finishManifestInboxProcessing(processNext: false)
                    return
                }
                processingURL = newestURL
                processingRevision = revision
                for staleURL in pendingURLs.dropLast() {
                    do {
                        try WatchManifestTransferInbox.remove(fileURL: staleURL)
                    } catch {
                        await self.logManifestInboxCleanupFailure(
                            message: "Veraltete Watch-Manifestdatei konnte nicht entfernt werden",
                            errorDescription: error.localizedDescription
                        )
                    }
                }
                let snapshot = try WatchManifestTransferSnapshot.decode(fileURL: newestURL)
                guard snapshot.manifestRevision == revision else {
                    throw WatchManifestTransferError.revisionMismatch
                }
                await self.commitStagedManifest(snapshot, fileURL: newestURL)
            } catch {
                var removedInvalidFile = false
                if let processingURL {
                    do {
                        try WatchManifestTransferInbox.remove(fileURL: processingURL)
                        removedInvalidFile = true
                    } catch {
                        await self.logManifestInboxCleanupFailure(
                            message: "Ungültige Watch-Manifestdatei konnte nicht entfernt werden",
                            errorDescription: error.localizedDescription
                        )
                    }
                }
                let errorDescription = error.localizedDescription
                await self.manifestInboxProcessingFailed(
                    errorDescription: errorDescription,
                    revision: processingRevision,
                    processNext: removedInvalidFile
                )
            }
        }
    }

    private func commitStagedManifest(_ snapshot: WatchManifestTransferSnapshot, fileURL: URL) async {
        let committed = await applyManifestReplace(
            entries: snapshot.entries,
            revision: snapshot.manifestRevision,
            watchEventProtocolVersion: snapshot.watchEventProtocolVersion,
            accentColorHex: snapshot.accentColorHex,
            compactAcknowledgement: true
        )
        guard committed else {
            finishManifestInboxProcessing(processNext: false)
            return
        }
        do {
            try WatchManifestTransferInbox.remove(fileURL: fileURL)
            finishManifestInboxProcessing(processNext: true)
        } catch {
            logManifestInboxCleanupFailure(
                message: "Verarbeitetes Watch-Manifest konnte nicht entfernt werden",
                errorDescription: error.localizedDescription
            )
            finishManifestInboxProcessing(processNext: false)
        }
    }

    private func manifestInboxProcessingFailed(
        errorDescription: String,
        revision: Int64?,
        processNext: Bool
    ) {
        manifestCommitFailed(errorDescription: errorDescription, revision: revision)
        finishManifestInboxProcessing(processNext: processNext)
    }

    private func finishManifestInboxProcessing(processNext: Bool) {
        manifestInboxProcessing = false
        let shouldProcessNext = processNext || manifestInboxProcessingRequested
        manifestInboxProcessingRequested = false
        if shouldProcessNext {
            scheduleManifestInboxProcessing()
        }
    }

    private func logManifestInboxCleanupFailure(message: String, errorDescription: String) {
        WatchDiagnostics.log(
            "manifest-inbox-cleanup-failed",
            message: message,
            metadata: ["error": errorDescription]
        )
    }

    private nonisolated func enqueue(payload: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0) else { return }
        Task { @MainActor in
            guard let payload = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { return }
            await self.handle(payload: payload)
        }
    }

    private func handle(payload: [String: Any]) async {
        guard let type = payload["type"] as? String else { return }

        switch type {
        case "manifest.replace":
            let entries = manifestEntries(from: payload["episodes"])
            let revision = manifestRevision(from: payload)
            _ = await applyManifestReplace(
                entries: entries,
                revision: revision,
                watchEventProtocolVersion: (payload["watchEventProtocolVersion"] as? NSNumber)?.intValue ?? 1,
                accentColorHex: payload["accentColorHex"] as? String,
                compactAcknowledgement: false
            )
            if let phonePlaybackState = payload["phonePlaybackState"] as? [String: Any] {
                WatchPlayerController.shared.applyPhoneState(phonePlaybackState)
            }
        case "manifest.upsertEpisodes":
            let entries = manifestEntries(from: payload["episodes"])
            let revision = manifestRevision(from: payload)
            if WatchManifestStore.shared.shouldApplyManifestRevision(revision) {
                do {
                    try await WatchDownloadManager.shared.upsertManifest(
                        entries: entries,
                        manifestRevision: revision
                    ) {
                        self.advanceWatchEventRevisionFloor(to: revision)
                    }
                    acknowledgeManifest(entries, revision: revision, compactAcknowledgement: false)
                } catch {
                    manifestCommitFailed(errorDescription: error.localizedDescription, revision: revision)
                }
            } else if WatchManifestStore.shared.isManifestRevisionCommitted(revision) {
                acknowledgeManifest(entries, revision: revision, compactAcknowledgement: false)
            }
        case "manifest.fileAvailable":
            // The descriptor is intentionally small and may arrive before the background file.
            // Never interpret a missing episodes array as an empty destructive replacement.
            if let phonePlaybackState = payload["phonePlaybackState"] as? [String: Any] {
                WatchPlayerController.shared.applyPhoneState(phonePlaybackState)
            }
        case "manifest.removeEpisodes":
            let revision = manifestRevision(from: payload)
            if WatchManifestStore.shared.shouldApplyManifestRevision(revision) {
                let hashes = payload["episodeHashes"] as? [String] ?? []
                do {
                    try await WatchDownloadManager.shared.removeEpisodes(
                        hashes: hashes,
                        manifestRevision: revision
                    ) {
                        self.advanceWatchEventRevisionFloor(to: revision)
                    }
                } catch {
                    manifestCommitFailed(errorDescription: error.localizedDescription, revision: revision)
                }
            }
        case "phone.ackDeletedEpisodes":
            WatchDownloadManager.shared.acknowledgeDeletedEpisodes(
                hashes: payload["episodeHashes"] as? [String] ?? [],
                selectionIdentifiers: payload["selectionIdentifiers"] as? [String] ?? [],
                selectionDates: payload["selectionDates"] as? [String] ?? []
            )
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

    private func manifestRevision(from payload: [String: Any]) -> Int64? {
        (payload["manifestRevision"] as? NSNumber)?.int64Value
    }

    private func applyManifestReplace(
        entries: [WatchManifestEntry],
        revision: Int64?,
        watchEventProtocolVersion: Int,
        accentColorHex: String?,
        compactAcknowledgement: Bool
    ) async -> Bool {
        if WatchManifestStore.shared.shouldApplyManifestRevision(revision) {
            do {
                try await WatchDownloadManager.shared.replaceManifest(
                    entries: entries,
                    manifestRevision: revision
                ) {
                    self.advanceWatchEventRevisionFloor(to: revision)
                }
                advancePhoneWatchEventProtocolVersion(to: watchEventProtocolVersion)
                WatchManifestStore.shared.updateAccentColorHex(accentColorHex)
                acknowledgeManifest(entries, revision: revision, compactAcknowledgement: compactAcknowledgement)
                return true
            } catch {
                manifestCommitFailed(errorDescription: error.localizedDescription, revision: revision)
                return false
            }
        } else if WatchManifestStore.shared.isManifestRevisionCommitted(revision) {
            acknowledgeManifest(entries, revision: revision, compactAcknowledgement: compactAcknowledgement)
            return true
        }
        return false
    }

    private func manifestCommitFailed(errorDescription: String, revision: Int64?) {
        WatchDiagnostics.log(
            "manifest-commit-failed",
            message: "Watch-Manifest konnte nicht dauerhaft gespeichert werden",
            metadata: ["error": errorDescription]
        )
        var payload: [String: Any] = [
            "timestamp": dateFormatter.string(from: Date()),
            "error": errorDescription,
        ]
        if let revision, revision > 0 {
            payload["manifestRevision"] = NSNumber(value: revision)
        }
        send(type: "watch.manifestFailed", payload: payload, delivery: .durable)
    }

    private func acknowledgeManifest(
        _ entries: [WatchManifestEntry],
        revision: Int64?,
        compactAcknowledgement: Bool
    ) {
        var payload: [String: Any] = [
            "timestamp": dateFormatter.string(from: Date()),
        ]
        if compactAcknowledgement, let revision, revision > 0 {
            payload["manifestRevision"] = NSNumber(value: revision)
        } else {
            payload["episodeHashes"] = entries.map(\.episodeHash)
            if let revision, revision > 0 {
                payload["manifestRevision"] = NSNumber(value: revision)
            }
        }
        send(type: "watch.ackManifest", payload: payload, delivery: .durable)
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
