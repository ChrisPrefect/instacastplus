import AVFoundation
import Foundation

private final class WatchBackgroundSessionEventCycle: @unchecked Sendable {
    private let lock = NSLock()
    private var reattachFinished = false
    private var delegateEventsFinished = false
    private var pendingFinalizations = 0
    private var completed = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func beginFinalization() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        pendingFinalizations += 1
        return true
    }

    func finishFinalization() {
        lock.lock()
        precondition(pendingFinalizations > 0)
        pendingFinalizations -= 1
        let continuations = takeContinuationsIfReady()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func markReattachFinished() {
        lock.lock()
        reattachFinished = true
        let continuations = takeContinuationsIfReady()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func markDelegateEventsFinished() {
        lock.lock()
        delegateEventsFinished = true
        let continuations = takeContinuationsIfReady()
        lock.unlock()
        continuations.forEach { $0.resume() }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed {
                lock.unlock()
                continuation.resume()
                return
            }
            continuations.append(continuation)
            let continuations = takeContinuationsIfReady()
            lock.unlock()
            continuations.forEach { $0.resume() }
        }
    }

    private func takeContinuationsIfReady() -> [CheckedContinuation<Void, Never>] {
        guard !completed,
              reattachFinished,
              delegateEventsFinished,
              pendingFinalizations == 0 else { return [] }
        completed = true
        let readyContinuations = continuations
        continuations.removeAll()
        return readyContinuations
    }
}

private final class WatchBackgroundSessionLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var currentCycle: WatchBackgroundSessionEventCycle?

    func begin() -> WatchBackgroundSessionEventCycle {
        cycleForCurrentEvents()
    }

    func beginFinalization() -> WatchBackgroundSessionEventCycle? {
        while true {
            let cycle = cycleForCurrentEvents()
            if cycle.beginFinalization() {
                return cycle
            }
        }
    }

    func markDelegateEventsFinished() {
        cycleForCurrentEvents().markDelegateEventsFinished()
    }

    func end(_ cycle: WatchBackgroundSessionEventCycle) {
        lock.lock()
        if currentCycle === cycle {
            currentCycle = nil
        }
        lock.unlock()
    }

    private func cycleForCurrentEvents() -> WatchBackgroundSessionEventCycle {
        lock.lock()
        defer { lock.unlock() }
        if let currentCycle, !currentCycle.isCompleted {
            return currentCycle
        }
        let cycle = WatchBackgroundSessionEventCycle()
        currentCycle = cycle
        return cycle
    }
}

private let reconcileFileResolutionBatchSize = 128
private let reconcileDiagnosticSampleLimit = 5

private struct WatchDownloadReconcileFileCandidate: Sendable {
    let episodeHash: String
    let selectionIdentifier: String
    let watchAddedDate: Date
    let mediaURL: URL
    let originalLocalFileURL: URL
}

private struct WatchDownloadReconcileFileResolution: Sendable {
    let candidate: WatchDownloadReconcileFileCandidate
    let resolvedLocalFileURL: URL?
}

private struct WatchDownloadStartRequest: Sendable {
    let episode: WatchEpisode
    let identity: WatchStorageEpisodeIdentity
    let priority: Float
    let generation: UInt64
}

private struct WatchDownloadTransportSnapshot: Sendable {
    let statusCode: Int?
    let contentRange: String?
    let expectedBytes: Int64
    let mimeType: String?
}

private enum WatchDownloadValidationFailure: Sendable {
    case http(statusCode: Int)
    case partialContent(actualSize: Int64)
    case empty
    case transportTruncated(actualSize: Int64, expectedSize: Int64)
    case feedTruncated(actualSize: Int64, expectedSize: Int64)

    var userMessage: String {
        switch self {
        case let .http(statusCode):
            return String(
                format: NSLocalizedString("Download fehlgeschlagen: HTTP %ld.", comment: ""),
                statusCode
            )
        case .partialContent:
            return NSLocalizedString("Download unvollständig: HTTP 206 Partial Content.", comment: "")
        case .empty:
            return NSLocalizedString("Geladene Datei ist leer.", comment: "")
        case .transportTruncated, .feedTruncated:
            return NSLocalizedString("Geladene Datei ist unvollständig.", comment: "")
        }
    }
}

private enum WatchFinishedDownloadPreparationResult: Sendable {
    case prepared(destination: URL, artworkDirectory: URL, size: Int64)
    case invalid(WatchDownloadValidationFailure)
    case fileFailure(String)
}

private struct WatchDownloadedFileAttributes: Sendable {
    let size: Int64
    let duration: Int
    let isPlayable: Bool
}

enum WatchPlaybackFileDisposition: Equatable {
    case queued
    case failed

    var status: WatchEpisodeStatus {
        switch self {
        case .queued:
            return .queued
        case .failed:
            return .failed
        }
    }
}

@MainActor
final class WatchDownloadManager: NSObject, ObservableObject {
    static let shared = WatchDownloadManager()
    static let backgroundSessionIdentifier = "com.iteconomy.instacastplus.watch.downloads"

    private var activeTasksByHash: [String: URLSessionDownloadTask] = [:]
    private var finishingDownloadHashes: Set<String> = []
    private var reattachGeneration: UInt64 = 0
    private var reattachInProgress = false
    private var pendingReattachCompletions: [@MainActor () -> Void] = []
    private var reattachResolutionTask: Task<[WatchDownloadReconcileFileResolution], Never>?
    private var lastProgressReportByHash: [String: Date] = [:]
    private var lastStorageStatusSendDate: Date?
    private let eventDateFormatter = ISO8601DateFormatter()
    private let removalCleanupBatchSize = 25
    private let deletionAcknowledgementBatchSize = 200
    private let storageEvictionCommitBatchSize = 25
    private var pendingDownloadStartOrder: [String] = []
    private var pendingDownloadStartHashes: Set<String> = []
    private var pendingDownloadStartPriorityByHash: [String: Float] = [:]
    private var storagePreparationTask: Task<Void, Never>?
    private var storagePreparationTargetHash: String?
    private var storagePreparationGeneration: UInt64 = 0
    private var storageMutationBlockerGeneration: UInt64 = 0
    private var storageMutationBlockers: Set<UInt64> = []
    private var pendingStorageMutationBlockerWaiters: [(
        blocker: UInt64,
        continuation: CheckedContinuation<Void, Never>
    )] = []
    private var pendingStorageMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var storageEvictionOwnedIdentities: [String: WatchStorageEpisodeIdentity] = [:]
    private var pendingStorageEvictionCommits: [String: WatchStorageCleanupCandidate] = [:]
    private var storageEvictionCommitBlocked = false
    private var pendingRemovalHashes: Set<String> = []
    private var activeRemovalHashes: Set<String> = []
    private var physicallyRemovedHashes: Set<String> = []
    private var removalFailureCountByHash: [String: Int] = [:]
    private var removalOwnedIdentities: [String: WatchStorageEpisodeIdentity] = [:]
    private var removalContext: WatchStorageRemovalContext?
    private var removalCleanupInProgress = false
    private var removalCleanupRequested = false
    private var autoFillInProgress = false
    private var autoFillRequested = false
    // Staged files and synchronous staging failures handed from didFinishDownloadingTo to
    // didCompleteWithError (both on the serial delegate queue, hence the lock instead of an actor).
    nonisolated(unsafe) private var stagedLocationsByTaskIdentifier: [Int: URL] = [:]
    nonisolated(unsafe) private var stagingFailureDescriptionsByTaskIdentifier: [Int: String] = [:]
    private let stagedLocationsLock = NSLock()
    private let backgroundSessionLifecycle = WatchBackgroundSessionLifecycle()

    private lazy var session: URLSession = {
#if targetEnvironment(simulator)
        // The watchOS simulator has no working nsurlsessiond for app background sessions —
        // every background download task fails instantly with NSURLError -1 (XPC 4097,
        // "remote session is unavailable"). A default session drives the exact same delegate
        // callbacks, so all validation/storage paths behave identically for simulator tests.
        let configuration = URLSessionConfiguration.default
#else
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
#endif
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        eventDateFormatter.formatOptions = [.withInternetDateTime]
    }

    func replaceManifest(
        entries: [WatchManifestEntry],
        manifestRevision: Int64?,
        didCommit: () -> Void
    ) async throws {
        let storageBlocker = await beginStorageMutationBlocker()
        defer { endStorageMutationBlocker(storageBlocker) }
        WatchDiagnostics.log("manifest-replace-received", message: "Watch empfaengt Replace-Manifest", metadata: [
            "entryCount": "\(entries.count)",
        ])
        let removed = try await WatchManifestStore.shared.applyManifest(
            entries: entries,
            manifestRevision: manifestRevision
        )
        didCommit()
        enqueuePendingRemovalHashes(removed.map(\.episodeHash))
        startQueuedDownloads()
    }

    func upsertManifest(
        entries: [WatchManifestEntry],
        manifestRevision: Int64?,
        didCommit: () -> Void
    ) async throws {
        let storageBlocker = await beginStorageMutationBlocker()
        defer { endStorageMutationBlocker(storageBlocker) }
        WatchDiagnostics.log("manifest-upsert-received", message: "Watch empfaengt Upsert-Manifest", metadata: [
            "entryCount": "\(entries.count)",
        ])
        try await WatchManifestStore.shared.upsert(entries: entries, manifestRevision: manifestRevision)
        didCommit()
        startQueuedDownloads()
    }

    func startQueuedDownloads() {
        reattachDownloadTasks { [weak self] in
            self?.startQueuedDownloadsAfterReattach()
        }
    }

    func startDownload(for episode: WatchEpisode, priority: Float = URLSessionTask.defaultPriority) {
        guard activeTasksByHash[episode.episodeHash] == nil,
              !finishingDownloadHashes.contains(episode.episodeHash),
              episode.localFileURL == nil else { return }
        enqueuePendingDownloadStart(episode: episode, priority: priority)
    }

    private func enqueuePendingDownloadStart(episode: WatchEpisode, priority: Float) {
        let hash = episode.episodeHash
        storageEvictionCommitBlocked = false
        pendingDownloadStartHashes.insert(hash)
        pendingDownloadStartPriorityByHash[hash] = max(
            pendingDownloadStartPriorityByHash[hash] ?? URLSessionTask.defaultPriority,
            priority
        )
        if storagePreparationTargetHash != hash,
           !pendingDownloadStartOrder.contains(hash) {
            pendingDownloadStartOrder.append(hash)
        }
        startNextPendingDownloadPreparation()
    }

    private func startNextPendingDownloadPreparation() {
        guard storagePreparationTask == nil,
              !storageEvictionCommitBlocked,
              storageMutationBlockers.isEmpty,
              !reattachInProgress,
              !removalCleanupInProgress,
              let hash = pendingDownloadStartOrder.first else { return }
        pendingDownloadStartOrder.removeFirst()
        guard pendingDownloadStartHashes.contains(hash),
              let episode = WatchManifestStore.shared.episode(hash: hash),
              activeTasksByHash[hash] == nil,
              !finishingDownloadHashes.contains(hash),
              episode.status == .queued,
              episode.localFileURL == nil else {
            pendingDownloadStartHashes.remove(hash)
            pendingDownloadStartPriorityByHash[hash] = nil
            scheduleNextPendingDownloadPreparation()
            return
        }

        let request = WatchDownloadStartRequest(
            episode: episode,
            identity: WatchStorageEpisodeIdentity(episode: episode),
            priority: pendingDownloadStartPriorityByHash[hash] ?? URLSessionTask.defaultPriority,
            generation: storagePreparationGeneration
        )
        storagePreparationTargetHash = hash
        storagePreparationTask = Task { @MainActor [weak self] in
            await self?.preparePendingDownloadStart(request)
        }
    }

    private func scheduleNextPendingDownloadPreparation() {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.startNextPendingDownloadPreparation()
        }
    }

    private func preparePendingDownloadStart(_ request: WatchDownloadStartRequest) async {
        guard await repairPendingStorageEvictions() else {
            finishPendingDownloadStart(request, removeRequest: false, requeue: false)
            return
        }
        guard request.generation == storagePreparationGeneration else {
            let stillRequested = pendingDownloadStartHashes.contains(request.identity.episodeHash)
            finishPendingDownloadStart(
                request,
                removeRequest: !stillRequested,
                requeue: stillRequested
            )
            return
        }
        guard isCurrentDownloadStartRequest(request) else {
            finishPendingDownloadStart(request, removeRequest: true, requeue: false)
            return
        }

        let storageManager = WatchStorageManager.shared
        let downloadsDirectory = storageManager.downloadsDirectory
        let chapterArtworkDirectory = storageManager.chapterArtworkDirectory
        let simulatedFreeBytesURL = chapterArtworkDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("WatchManifest/simulated-free-bytes.txt")
        let snapshot = WatchStorageCleanupSnapshot(
            bytesNeeded: request.episode.expectedBytes,
            activeDownloadHashes: Set(activeTasksByHash.keys),
            excludingEpisodeHash: request.episode.episodeHash,
            playingEpisodeHash: WatchPlayerController.shared.playingEpisodeHash,
            episodes: WatchManifestStore.shared.episodes,
            downloadsDirectory: downloadsDirectory,
            chapterArtworkDirectory: chapterArtworkDirectory,
            simulatedFreeBytesURL: simulatedFreeBytesURL
        )
        let plan = await WatchStorageManager.makeCleanupPlan(for: snapshot)
        guard request.generation == storagePreparationGeneration,
              storageMutationBlockers.isEmpty,
              !removalCleanupInProgress,
              isCurrentDownloadStartRequest(request) else {
            finishPendingDownloadStart(
                request,
                removeRequest: !pendingDownloadStartHashes.contains(request.identity.episodeHash),
                requeue: pendingDownloadStartHashes.contains(request.identity.episodeHash)
            )
            return
        }
        guard plan.hasSufficientCapacity, !plan.wasCancelled else {
            _ = await persistInsufficientStorageState(
                for: request,
                freeBytes: plan.freeBytesBefore
            )
            finishPendingDownloadStart(request, removeRequest: true, requeue: false)
            return
        }
        guard revalidatedStorageCandidates(plan.selectedCandidates) != nil else {
            finishPendingDownloadStart(request, removeRequest: false, requeue: true)
            return
        }

        for candidate in plan.selectedCandidates {
            storageEvictionOwnedIdentities[candidate.identity.episodeHash] = candidate.identity
        }
        let execution = await WatchStorageManager.executeCleanup(plan)
        logStorageRemovalIssues(execution.issues)

        guard revalidatedStorageCandidates(plan.selectedCandidates) != nil else {
            for candidate in plan.selectedCandidates {
                if execution.physicallyRemovedHashes.contains(candidate.identity.episodeHash) {
                    pendingStorageEvictionCommits[candidate.identity.episodeHash] = candidate
                } else {
                    storageEvictionOwnedIdentities[candidate.identity.episodeHash] = nil
                }
            }
            guard await commitStorageEvictions() else {
                finishPendingDownloadStart(request, removeRequest: false, requeue: false)
                return
            }
            finishPendingDownloadStart(request, removeRequest: false, requeue: true)
            return
        }

        for candidate in plan.selectedCandidates {
            if execution.physicallyRemovedHashes.contains(candidate.identity.episodeHash) {
                pendingStorageEvictionCommits[candidate.identity.episodeHash] = candidate
            } else {
                storageEvictionOwnedIdentities[candidate.identity.episodeHash] = nil
            }
        }
        guard await commitStorageEvictions() else {
            finishPendingDownloadStart(request, removeRequest: false, requeue: false)
            return
        }
        guard execution.completedEverySelectedRemoval else {
            _ = await persistInsufficientStorageState(
                for: request,
                freeBytes: plan.freeBytesBefore
            )
            finishPendingDownloadStart(request, removeRequest: true, requeue: false)
            return
        }
        guard request.generation == storagePreparationGeneration,
              isCurrentDownloadStartRequest(request) else {
            let stillRequested = pendingDownloadStartHashes.contains(request.identity.episodeHash)
            finishPendingDownloadStart(
                request,
                removeRequest: !stillRequested,
                requeue: stillRequested
            )
            return
        }
        _ = beginPreparedDownload(
            request,
            projectedFreeBytes: plan.projectedFreeBytes
        )
        finishPendingDownloadStart(request, removeRequest: true, requeue: false)
    }

    private func revalidatedStorageCandidates(
        _ candidates: [WatchStorageCleanupCandidate]
    ) -> [WatchStorageCleanupCandidate]? {
        let playingHash = WatchPlayerController.shared.playingEpisodeHash
        for candidate in candidates {
            let hash = candidate.identity.episodeHash
            guard let current = WatchManifestStore.shared.episode(hash: hash),
                  candidate.identity.matches(current),
                  current.status == candidate.episode.status,
                  current.status != .removing,
                  current.localFileURL != nil,
                  hash != playingHash,
                  activeTasksByHash[hash] == nil,
                  !finishingDownloadHashes.contains(hash) else {
                return nil
            }
        }
        return candidates
    }

    private func commitStorageEvictions() async -> Bool {
        guard !pendingStorageEvictionCommits.isEmpty else { return true }
        var candidates: [WatchStorageCleanupCandidate] = []
        for candidate in pendingStorageEvictionCommits.values {
            let hash = candidate.identity.episodeHash
            guard let current = WatchManifestStore.shared.episode(hash: hash),
                  candidate.identity.matches(current),
                  current.status != .removing else {
                pendingStorageEvictionCommits[hash] = nil
                storageEvictionOwnedIdentities[hash] = nil
                continue
            }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else { return true }

        candidates.sort { $0.identity.episodeHash < $1.identity.episodeHash }
        let hashes = candidates.map { $0.identity.episodeHash }
        let expectedBytesByHash = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.identity.episodeHash, $0.expectedBytes) }
        )
        do {
            try await WatchManifestStore.shared.updateEpisodesDurablyInBatches(
                hashes: hashes,
                batchSize: storageEvictionCommitBatchSize
            ) { item in
                item.status = .evicted
                item.localFileURL = nil
                item.actualFileSize = 0
                item.downloadedBytes = 0
                item.expectedBytes = expectedBytesByHash[item.episodeHash] ?? item.expectedBytes
                item.chapters = []
                item.chapterArtworkBaseURL = nil
                item.lastError = NSLocalizedString("Nicht genügend Speicher auf der Watch.", comment: "")
            }
            for candidate in candidates {
                let hash = candidate.identity.episodeHash
                pendingStorageEvictionCommits[hash] = nil
                storageEvictionOwnedIdentities[hash] = nil
                sendStorageEviction(hash: hash)
            }
            storageEvictionCommitBlocked = false
            return true
        } catch {
            for candidate in candidates {
                pendingStorageEvictionCommits[candidate.identity.episodeHash] = candidate
            }
            storageEvictionCommitBlocked = true
            WatchDiagnostics.log(
                "storage-eviction-state-failed",
                message: "Freigeräumter Watch-Speicher konnte nicht im Manifest gesichert werden",
                metadata: ["error": error.localizedDescription, "episodeCount": "\(candidates.count)"]
            )
            return false
        }
    }

    private func repairPendingStorageEvictions() async -> Bool {
        await commitStorageEvictions()
    }

    private func persistInsufficientStorageState(
        for request: WatchDownloadStartRequest,
        freeBytes: Int64
    ) async -> Bool {
        guard isCurrentDownloadStartRequest(request) else { return false }
        do {
            try await WatchManifestStore.shared.updateEpisodeDurably(hash: request.identity.episodeHash) { item in
                item.status = .evicted
                item.localFileURL = nil
                item.actualFileSize = 0
                item.downloadedBytes = 0
                item.expectedBytes = max(item.expectedBytes, request.episode.expectedBytes)
                item.lastError = NSLocalizedString("Nicht genügend Speicher auf der Watch.", comment: "")
            }
        } catch {
            WatchDiagnostics.log(
                "download-storage-state-failed",
                message: "Watch-Speicherfehler konnte nicht im Manifest gesichert werden",
                metadata: ["episodeHash": request.identity.episodeHash, "error": error.localizedDescription]
            )
            return false
        }
        guard request.generation == storagePreparationGeneration,
              let current = WatchManifestStore.shared.episode(hash: request.identity.episodeHash),
              request.identity.matches(current),
              current.status == .evicted else {
            return false
        }

        var metadata = WatchDiagnostics.metadata(for: request.episode)
        metadata["freeBytes"] = "\(freeBytes)"
        metadata["expectedBytes"] = "\(request.episode.expectedBytes)"
        WatchDiagnostics.log(
            "download-storage-insufficient",
            message: "Watch-Speicher reicht nicht fuer Download",
            metadata: metadata
        )
        sendStorageEviction(hash: request.identity.episodeHash)
        WatchConnectivityController.shared.sendStorageStatus()
        return true
    }

    private func beginPreparedDownload(
        _ request: WatchDownloadStartRequest,
        projectedFreeBytes: Int64
    ) -> Bool {
        guard isCurrentDownloadStartRequest(request) else { return false }
        let episode = WatchManifestStore.shared.episode(hash: request.identity.episodeHash) ?? request.episode
        WatchConnectivityController.shared.clearReportedTerminalDownloadState(forEpisodeHash: episode.episodeHash)

        var urlRequest = URLRequest(url: episode.mediaURL)
        urlRequest.allowsCellularAccess = true
        var metadata = WatchDiagnostics.metadata(for: episode)
        metadata["freeBytes"] = "\(projectedFreeBytes)"
        metadata["expectedBytes"] = "\(episode.expectedBytes)"
        WatchDiagnostics.log("download-start", message: "Watch-Download startet", metadata: metadata)
        let task = session.downloadTask(with: urlRequest)
        task.taskDescription = episode.episodeHash
        task.priority = request.priority
        activeTasksByHash[episode.episodeHash] = task

        WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
            item.status = .downloading
            item.lastError = nil
        }
        WatchConnectivityController.shared.send(type: "watch.downloadQueued", payload: [
            "episodeHash": episode.episodeHash,
            "timestamp": timestamp(),
        ])
        task.resume()
        return true
    }

    private func isCurrentDownloadStartRequest(_ request: WatchDownloadStartRequest) -> Bool {
        let hash = request.identity.episodeHash
        guard pendingDownloadStartHashes.contains(hash),
              request.generation == storagePreparationGeneration,
              let current = WatchManifestStore.shared.episode(hash: hash),
              request.identity.matches(current),
              current.status == .queued,
              current.localFileURL == nil,
              activeTasksByHash[hash] == nil,
              !finishingDownloadHashes.contains(hash) else { return false }
        return true
    }

    private func finishPendingDownloadStart(
        _ request: WatchDownloadStartRequest,
        removeRequest: Bool,
        requeue: Bool
    ) {
        let hash = request.identity.episodeHash
        let releasableOwnedHashes = storageEvictionOwnedIdentities.keys.filter {
            pendingStorageEvictionCommits[$0] == nil
        }
        for ownedHash in releasableOwnedHashes {
            storageEvictionOwnedIdentities[ownedHash] = nil
        }
        storagePreparationTask = nil
        storagePreparationTargetHash = nil
        if removeRequest {
            pendingDownloadStartHashes.remove(hash)
            pendingDownloadStartPriorityByHash[hash] = nil
            pendingDownloadStartOrder.removeAll { $0 == hash }
        } else if requeue,
                  pendingDownloadStartHashes.contains(hash),
                  !pendingDownloadStartOrder.contains(hash) {
            pendingDownloadStartOrder.append(hash)
        }

        guard storageMutationBlockers.isEmpty else { return }
        let hasReadyRemoval = pendingRemovalHashes.contains {
            $0 != WatchPlayerController.shared.playingEpisodeHash
        }
        if hasReadyRemoval, !removalCleanupInProgress {
            enqueuePendingRemovalHashes([])
            return
        }
        scheduleNextPendingDownloadPreparation()
    }

    private func logStorageRemovalIssues(_ issues: [WatchStorageRemovalIssue]) {
        for issue in issues {
            var metadata = ["error": issue.errorDescription]
            if let episodeHash = issue.episodeHash {
                metadata["episodeHash"] = episodeHash
            }
            WatchDiagnostics.log(issue.event, message: issue.message, metadata: metadata)
        }
    }

    private func beginStorageMutationBlocker() async -> UInt64 {
        storageMutationBlockerGeneration &+= 1
        let blocker = storageMutationBlockerGeneration
        if !storageMutationBlockers.isEmpty {
            await withCheckedContinuation { continuation in
                pendingStorageMutationBlockerWaiters.append((blocker, continuation))
            }
        } else {
            storageMutationBlockers.insert(blocker)
        }
        storagePreparationGeneration &+= 1
        if let storagePreparationTask {
            await storagePreparationTask.value
        }
        if removalCleanupInProgress {
            await withCheckedContinuation { continuation in
                pendingStorageMutationWaiters.append(continuation)
            }
        }
        return blocker
    }

    private func endStorageMutationBlocker(_ blocker: UInt64) {
        guard storageMutationBlockers.remove(blocker) != nil else { return }
        guard storageMutationBlockers.isEmpty else { return }
        if !pendingStorageMutationBlockerWaiters.isEmpty {
            let next = pendingStorageMutationBlockerWaiters.removeFirst()
            storageMutationBlockers.insert(next.blocker)
            next.continuation.resume()
            return
        }
        storageEvictionCommitBlocked = false
        let hasReadyRemoval = pendingRemovalHashes.contains {
            $0 != WatchPlayerController.shared.playingEpisodeHash
        }
        if hasReadyRemoval, !removalCleanupInProgress {
            enqueuePendingRemovalHashes([])
            return
        }
        scheduleNextPendingDownloadPreparation()
    }

    func claimPlaybackBeforeStorageEviction(hash: String) -> Bool {
        guard removalOwnedIdentities[hash] == nil else { return false }
        if let ownedIdentity = storageEvictionOwnedIdentities[hash] {
            if let current = WatchManifestStore.shared.episode(hash: hash),
               ownedIdentity.matches(current) {
                return false
            }
            storageEvictionOwnedIdentities[hash] = nil
            pendingStorageEvictionCommits[hash] = nil
        }
        if storagePreparationTask != nil {
            storagePreparationGeneration &+= 1
        }
        return true
    }

    func removePlaybackFile(
        for episode: WatchEpisode,
        expectedStatus: WatchEpisodeStatus,
        disposition: WatchPlaybackFileDisposition,
        error: String,
        stillCurrentPlayback: @MainActor () -> Bool
    ) async -> Bool {
        let hash = episode.episodeHash
        let identity = WatchStorageEpisodeIdentity(episode: episode)
        guard removalOwnedIdentities[hash] == nil,
              storageEvictionOwnedIdentities[hash] == nil,
              let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
              matchesPlaybackRemovalIdentity(identity, currentEpisode),
              currentEpisode.status == expectedStatus,
              activeTasksByHash[hash] == nil,
              !finishingDownloadHashes.contains(hash),
              !pendingDownloadStartHashes.contains(hash),
              stillCurrentPlayback() else {
            return false
        }

        removalOwnedIdentities[hash] = identity
        let storageBlocker = await beginStorageMutationBlocker()
        defer {
            if removalOwnedIdentities[hash] == identity {
                removalOwnedIdentities[hash] = nil
            }
            endStorageMutationBlocker(storageBlocker)
        }

        guard removalOwnedIdentities[hash] == identity,
              let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
              matchesPlaybackRemovalIdentity(identity, currentEpisode),
              currentEpisode.status == expectedStatus,
              activeTasksByHash[hash] == nil,
              !finishingDownloadHashes.contains(hash),
              !pendingDownloadStartHashes.contains(hash),
              stillCurrentPlayback() else {
            return false
        }

        let storageManager = WatchStorageManager.shared
        let removalResult = await WatchStorageManager.removeLocalFiles(
            for: [episode],
            downloadsDirectory: storageManager.downloadsDirectory,
            chapterArtworkDirectory: storageManager.chapterArtworkDirectory
        )
        logStorageRemovalIssues(removalResult.issues)

        guard removalResult.removedHashes.contains(hash) else {
            await recordPlaybackFileRemovalFailure(
                hash: hash,
                identity: identity,
                expectedStatus: expectedStatus,
                error: error
            )
            return false
        }
        guard removalOwnedIdentities[hash] == identity,
              let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
              matchesPlaybackRemovalIdentity(identity, currentEpisode),
              currentEpisode.status == expectedStatus,
              activeTasksByHash[hash] == nil,
              !finishingDownloadHashes.contains(hash),
              !pendingDownloadStartHashes.contains(hash) else {
            return false
        }

        do {
            try await WatchManifestStore.shared.updateEpisodeDurably(hash: hash) { item in
                guard self.matchesPlaybackRemovalIdentity(identity, item),
                      item.status == expectedStatus else {
                    return
                }
                item.status = disposition.status
                item.localFileURL = nil
                item.actualFileSize = 0
                item.actualDuration = 0
                item.downloadedBytes = 0
                item.chapters = []
                item.chapterArtworkBaseURL = nil
                item.lastError = disposition == .queued ? nil : error
            }
        } catch {
            WatchDiagnostics.log(
                "playback-file-state-persist-failed",
                message: "Watch-Wiedergabedateistatus konnte nicht gespeichert werden",
                metadata: ["episodeHash": hash, "error": error.localizedDescription]
            )
            return false
        }

        guard removalOwnedIdentities[hash] == identity,
              let committedEpisode = WatchManifestStore.shared.episode(hash: hash),
              matchesPlaybackRemovalIdentity(identity, committedEpisode),
              committedEpisode.status == disposition.status,
              committedEpisode.localFileURL == nil,
              activeTasksByHash[hash] == nil,
              !finishingDownloadHashes.contains(hash),
              !pendingDownloadStartHashes.contains(hash) else {
            return false
        }
        return true
    }

    private func matchesPlaybackRemovalIdentity(
        _ identity: WatchStorageEpisodeIdentity,
        _ episode: WatchEpisode
    ) -> Bool {
        identity.episodeHash == episode.episodeHash
            && identity.selectionIdentifier == episode.selectionIdentifier
            && identity.watchAddedDate == episode.watchAddedDate
            && identity.mediaURL == episode.mediaURL
    }

    private func recordPlaybackFileRemovalFailure(
        hash: String,
        identity: WatchStorageEpisodeIdentity,
        expectedStatus: WatchEpisodeStatus,
        error playbackError: String
    ) async {
        guard removalOwnedIdentities[hash] == identity,
              let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
              matchesPlaybackRemovalIdentity(identity, currentEpisode),
              currentEpisode.status == expectedStatus,
              activeTasksByHash[hash] == nil,
              !finishingDownloadHashes.contains(hash),
              !pendingDownloadStartHashes.contains(hash) else {
            return
        }
        let cleanupError = NSLocalizedString(
            "Die defekte Audiodatei konnte nicht entfernt werden. Tippe, um es erneut zu versuchen.",
            comment: ""
        )
        do {
            try await WatchManifestStore.shared.updateEpisodeDurably(hash: hash) { item in
                guard self.matchesPlaybackRemovalIdentity(identity, item),
                      item.status == expectedStatus else {
                    return
                }
                item.lastError = cleanupError
            }
        } catch {
            WatchDiagnostics.log(
                "playback-file-removal-error-persist-failed",
                message: "Watch-Dateilöschfehler konnte nicht gespeichert werden",
                metadata: [
                    "episodeHash": hash,
                    "error": error.localizedDescription,
                    "playbackError": playbackError,
                ]
            )
            return
        }
        WatchConnectivityController.shared.clearReportedTerminalDownloadState(forEpisodeHash: hash)
    }

    func retryPlaybackFileRemoval(hash: String) {
        guard let episode = WatchManifestStore.shared.episode(hash: hash),
              episode.hasPlaybackFileRemovalError else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
                  currentEpisode.hasPlaybackFileRemovalError else {
                return
            }
            let removed = await self.removePlaybackFile(
                for: currentEpisode,
                expectedStatus: .downloaded,
                disposition: .queued,
                error: currentEpisode.lastError ?? "",
                stillCurrentPlayback: {
                    WatchPlayerController.shared.playingEpisodeHash != hash
                }
            )
            guard removed,
                  let queuedEpisode = WatchManifestStore.shared.episode(hash: hash),
                  queuedEpisode.status == .queued,
                  queuedEpisode.localFileURL == nil else {
                return
            }
            WatchConnectivityController.shared.clearReportedTerminalDownloadState(forEpisodeHash: hash)
            self.prioritizeEpisode(hash: hash)
        }
    }

    func prioritizeEpisode(hash: String) {
        if let task = activeTasksByHash[hash] {
            task.priority = URLSessionTask.highPriority
            return
        }
        guard let episode = WatchManifestStore.shared.episode(hash: hash) else { return }
        if episode.status == .failed || episode.status == .evicted {
            WatchManifestStore.shared.updateEpisode(hash: hash) { item in
                item.status = .queued
                item.lastError = nil
            }
        }
        startDownload(for: episode, priority: URLSessionTask.highPriority)
    }

    func cancelEpisode(hash: String) {
        // didComplete owns the state once finalization starts. Rewriting it while the durable
        // downloaded snapshot is suspended would leave `.queued` pointing at the installed file.
        guard !finishingDownloadHashes.contains(hash) else { return }
        storagePreparationGeneration &+= 1
        pendingDownloadStartHashes.remove(hash)
        pendingDownloadStartOrder.removeAll { $0 == hash }
        pendingDownloadStartPriorityByHash[hash] = nil
        activeTasksByHash[hash]?.cancel()
        activeTasksByHash[hash] = nil
        WatchManifestStore.shared.updateEpisode(hash: hash) { item in
            item.status = .queued
        }
    }

    func removeEpisode(hash: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let storageBlocker = await self.beginStorageMutationBlocker()
            defer { self.endStorageMutationBlocker(storageBlocker) }
            do {
                let marked = try await WatchManifestStore.shared.markEpisodesForRemoval(hashes: Set([hash]))
                guard !marked.isEmpty else { return }
                self.activeTasksByHash[hash]?.cancel()
                self.activeTasksByHash[hash] = nil
                self.enqueuePendingRemovalHashes([hash])
            } catch {
                WatchDiagnostics.log(
                    "manifest-remove-failed",
                    message: "Watch-Folge konnte nicht zum Entfernen vorgemerkt werden",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    func removeEpisodes(
        hashes: [String],
        manifestRevision: Int64?,
        didCommit: () -> Void
    ) async throws {
        let storageBlocker = await beginStorageMutationBlocker()
        defer { endStorageMutationBlocker(storageBlocker) }
        let uniqueHashes = Set(hashes.filter { !$0.isEmpty })
        let marked = try await WatchManifestStore.shared.markEpisodesForRemoval(
            hashes: uniqueHashes,
            manifestRevision: manifestRevision
        )
        didCommit()
        for episode in marked {
            activeTasksByHash[episode.episodeHash]?.cancel()
            activeTasksByHash[episode.episodeHash] = nil
        }
        enqueuePendingRemovalHashes(marked.map(\.episodeHash))
    }

    func finalizePendingRemoval(hash: String) {
        guard WatchManifestStore.shared.episode(hash: hash)?.status == .removing else { return }
        enqueuePendingRemovalHashes([hash])
    }

    private func finalizePendingRemovals() {
        let hashes = WatchManifestStore.shared.episodes
            .filter { $0.status == .removing }
            .map(\.episodeHash)
        enqueuePendingRemovalHashes(hashes)
    }

    func finalizePendingRemovalsAfterConnectivityActivation() {
        finalizePendingRemovals()
    }

    func retryPendingRemoval(hash: String) {
        guard let episode = WatchManifestStore.shared.episode(hash: hash),
              episode.hasPendingRemovalError else {
            return
        }
        let identity = WatchStorageEpisodeIdentity(episode: episode)
        Task { @MainActor [weak self] in
            guard let self,
                  let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
                  currentEpisode.status == .removing,
                  identity.matches(currentEpisode),
                  currentEpisode.hasPendingRemovalError else {
                return
            }
            do {
                try await WatchManifestStore.shared.updateEpisodeDurably(hash: hash) { item in
                    guard item.status == .removing, identity.matches(item) else { return }
                    item.lastError = nil
                    item.pendingRemovalRetryRequired = false
                }
            } catch {
                WatchDiagnostics.log(
                    "pending-removal-retry-state-failed",
                    message: "Watch-Löschwiederholung konnte nicht gespeichert werden",
                    metadata: ["episodeHash": hash, "error": error.localizedDescription]
                )
                return
            }
            guard let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
                  currentEpisode.status == .removing,
                  identity.matches(currentEpisode),
                  !currentEpisode.hasPendingRemovalError else {
                return
            }
            self.removalFailureCountByHash[hash] = nil
            self.enqueuePendingRemovalHashes([hash])
        }
    }

    private func enqueuePendingRemovalHashes(_ hashes: [String]) {
        let requestedHashes = Set(hashes.filter { !$0.isEmpty })
        for hash in requestedHashes {
            removalFailureCountByHash[hash] = nil
        }
        pendingRemovalHashes.formUnion(requestedHashes)
        guard storageMutationBlockers.isEmpty else {
            removalCleanupRequested = true
            return
        }
        guard storagePreparationTask == nil else {
            storagePreparationGeneration &+= 1
            removalCleanupRequested = true
            return
        }
        guard !removalCleanupInProgress else {
            removalCleanupRequested = true
            return
        }
        guard !pendingRemovalHashes.isEmpty else { return }
        removalCleanupInProgress = true
        removalCleanupRequested = false
        Task { @MainActor in
            await Task.yield()
            await self.preparePendingRemovalCleanup()
        }
    }

    private func preparePendingRemovalCleanup() async {
        let playingHash = WatchPlayerController.shared.playingEpisodeHash
        activeRemovalHashes = Set(pendingRemovalHashes.filter {
            $0 != playingHash &&
                removalFailureCountByHash[$0, default: 0] < 2 &&
                !(WatchManifestStore.shared.episode(hash: $0)?.hasPendingRemovalError ?? false)
        })
        guard !activeRemovalHashes.isEmpty else {
            finishPendingRemovalCleanup(processNext: false)
            return
        }
        pendingRemovalHashes.subtract(activeRemovalHashes)

        let storageManager = WatchStorageManager.shared
        let preparation = await WatchStorageManager.removalContext(
            downloadsDirectory: storageManager.downloadsDirectory,
            chapterArtworkDirectory: storageManager.chapterArtworkDirectory,
            episodeHashes: activeRemovalHashes
        )
        removalContext = preparation.context
        logStorageRemovalIssues(preparation.issues)
        await processPendingRemovalBatch()
    }

    private func processPendingRemovalBatch() async {
        let playingHash = WatchPlayerController.shared.playingEpisodeHash
        let batch = activeRemovalHashes
            .filter { $0 != playingHash }
            .prefix(removalCleanupBatchSize)

        guard !batch.isEmpty else {
            finishPendingRemovalCleanup(processNext: false)
            return
        }
        guard let removalContext else {
            pendingRemovalHashes.formUnion(activeRemovalHashes)
            activeRemovalHashes.removeAll()
            removalCleanupRequested = false
            finishPendingRemovalCleanup(processNext: false)
            return
        }

        var batchEpisodes: [WatchEpisode] = []
        var batchIdentities: [String: WatchStorageEpisodeIdentity] = [:]
        for hash in batch {
            activeRemovalHashes.remove(hash)
            guard let episode = WatchManifestStore.shared.episode(hash: hash),
                  episode.status == .removing else {
                removalFailureCountByHash[hash] = nil
                continue
            }
            activeTasksByHash[hash]?.cancel()
            activeTasksByHash[hash] = nil
            batchEpisodes.append(episode)
            let identity = WatchStorageEpisodeIdentity(episode: episode)
            batchIdentities[hash] = identity
            removalOwnedIdentities[hash] = identity
        }
        let removalResult = await WatchStorageManager.removeLocalFiles(
            for: batchEpisodes,
            context: removalContext
        )
        logStorageRemovalIssues(removalResult.issues)
        let attemptedHashes = Set(batchEpisodes.map(\.episodeHash))
        for hash in attemptedHashes {
            removalOwnedIdentities[hash] = nil
        }
        let physicallyDeletedHashes = removalResult.removedHashes
        let failedHashes = attemptedHashes.subtracting(physicallyDeletedHashes)
        let playingEpisodeHash = WatchPlayerController.shared.playingEpisodeHash
        var confirmedDeletedHashes: Set<String> = []
        var deferredHashes: Set<String> = []
        for hash in physicallyDeletedHashes {
            guard let identity = batchIdentities[hash],
                  let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
                  currentEpisode.status == .removing else {
                removalFailureCountByHash[hash] = nil
                continue
            }
            guard identity.matches(currentEpisode), playingEpisodeHash != hash else {
                deferredHashes.insert(hash)
                if playingEpisodeHash != hash {
                    removalCleanupRequested = true
                }
                continue
            }
            confirmedDeletedHashes.insert(hash)
        }
        pendingRemovalHashes.formUnion(failedHashes)
        pendingRemovalHashes.formUnion(deferredHashes)
        physicallyRemovedHashes.formUnion(confirmedDeletedHashes)
        for hash in confirmedDeletedHashes {
            removalFailureCountByHash[hash] = nil
        }
        var exhaustedRemovalFailureHashes: Set<String> = []
        for hash in failedHashes {
            guard let identity = batchIdentities[hash],
                  let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
                  currentEpisode.status == .removing,
                  identity.matches(currentEpisode) else {
                pendingRemovalHashes.remove(hash)
                removalFailureCountByHash[hash] = nil
                continue
            }
            removalFailureCountByHash[hash, default: 0] += 1
            if removalFailureCountByHash[hash, default: 0] >= 2 {
                exhaustedRemovalFailureHashes.insert(hash)
            } else {
                removalCleanupRequested = true
            }
        }
        if !exhaustedRemovalFailureHashes.isEmpty {
            await persistPendingRemovalFailures(hashes: exhaustedRemovalFailureHashes)
        }

        let hasMoreReady = activeRemovalHashes.contains { $0 != WatchPlayerController.shared.playingEpisodeHash }
        if hasMoreReady {
            Task { @MainActor in
                await Task.yield()
                await self.processPendingRemovalBatch()
            }
            return
        }

        guard !physicallyRemovedHashes.isEmpty else {
            finishPendingRemovalCleanup(processNext: false)
            return
        }
        let completedHashes = physicallyRemovedHashes
        let committedHashes = sendDeletionAcknowledgements(for: completedHashes)
        physicallyRemovedHashes.subtract(completedHashes)
        if WatchConnectivityController.shared.supportsDeletionAcknowledgementBatches {
            WatchConnectivityController.shared.sendStorageStatus()
            finishPendingRemovalCleanup(processNext: true)
            return
        }
        guard !committedHashes.isEmpty else {
            WatchConnectivityController.shared.sendStorageStatus()
            finishPendingRemovalCleanup(processNext: true)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await WatchManifestStore.shared.removeEpisodes(hashes: committedHashes)
                WatchConnectivityController.shared.sendStorageStatus()
                self.autoFillEvictedEpisodes()
                self.finishPendingRemovalCleanup(processNext: true)
            } catch {
                WatchDiagnostics.log(
                    "manifest-remove-state-failed",
                    message: "Entfernte Watch-Folgen konnten nicht aus dem Manifest gelöscht werden",
                    metadata: ["error": error.localizedDescription, "episodeCount": "\(committedHashes.count)"]
                )
                self.finishPendingRemovalCleanup(processNext: false)
            }
        }
    }

    private func persistPendingRemovalFailures(hashes: Set<String>) async {
        let removalError = NSLocalizedString(
            "Die Folge konnte nicht von der Watch entfernt werden. Tippe, um es erneut zu versuchen.",
            comment: ""
        )
        do {
            try await WatchManifestStore.shared.updateEpisodes(hashes: hashes) { item in
                guard item.status == .removing else { return }
                item.lastError = removalError
                item.pendingRemovalRetryRequired = true
            }
        } catch {
            WatchDiagnostics.log(
                "pending-removal-error-state-failed",
                message: "Watch-Löschfehler konnte nicht gespeichert werden",
                metadata: ["episodeCount": "\(hashes.count)", "error": error.localizedDescription]
            )
        }
    }

    private func sendDeletionAcknowledgements(for hashes: Set<String>) -> Set<String> {
        let acknowledgements = hashes.sorted().compactMap { hash -> (hash: String, selectionIdentifier: String, selectionDate: Date)? in
            guard let episode = WatchManifestStore.shared.episode(hash: hash),
                  episode.status == .removing else { return nil }
            return (hash, episode.selectionIdentifier, episode.watchAddedDate)
        }
        var acceptedHashes: Set<String> = []
        guard WatchConnectivityController.shared.supportsDeletionAcknowledgementBatches else {
            for acknowledgement in acknowledgements {
                if WatchConnectivityController.shared.send(type: "watch.deleted", payload: [
                    "episodeHash": acknowledgement.hash,
                    "selectionDate": timestamp(acknowledgement.selectionDate),
                    "timestamp": timestamp(),
                ], delivery: .durable) {
                    acceptedHashes.insert(acknowledgement.hash)
                }
            }
            return acceptedHashes
        }
        for acknowledgement in acknowledgements where acknowledgement.selectionIdentifier.isEmpty {
            if WatchConnectivityController.shared.send(type: "watch.deleted", payload: [
                "episodeHash": acknowledgement.hash,
                "selectionDate": timestamp(acknowledgement.selectionDate),
                "timestamp": timestamp(),
            ], delivery: .durable) {
                acceptedHashes.insert(acknowledgement.hash)
            }
        }
        let identifiedAcknowledgements = acknowledgements.filter { !$0.selectionIdentifier.isEmpty }
        for startIndex in stride(
            from: 0,
            to: identifiedAcknowledgements.count,
            by: deletionAcknowledgementBatchSize
        ) {
            let endIndex = min(startIndex + deletionAcknowledgementBatchSize, identifiedAcknowledgements.count)
            let batch = identifiedAcknowledgements[startIndex..<endIndex]
            let episodeHashes = batch.map { $0.hash }
            let selectionIdentifiers = batch.map { $0.selectionIdentifier }
            if WatchConnectivityController.shared.send(type: "watch.deletedEpisodes", payload: [
                "episodeHashes": episodeHashes,
                "selectionIdentifiers": selectionIdentifiers,
                "timestamp": timestamp(),
            ], delivery: .durable) {
                acceptedHashes.formUnion(episodeHashes)
            }
        }
        return acceptedHashes
    }

    func acknowledgeDeletedEpisodes(
        hashes: [String],
        selectionIdentifiers: [String],
        selectionDates: [String]
    ) {
        guard !hashes.isEmpty,
              hashes.count <= deletionAcknowledgementBatchSize,
              hashes.count == selectionIdentifiers.count || hashes.count == selectionDates.count else { return }
        var uniqueHashes: Set<String> = []
        var acknowledgedHashes: Set<String> = []
        for index in hashes.indices {
            let hash = hashes[index]
            let selectionIdentifier = selectionIdentifiers.indices.contains(index) ? selectionIdentifiers[index] : ""
            let selectionDate = selectionDates.indices.contains(index) ? selectionDates[index] : ""
            guard !hash.isEmpty,
                  uniqueHashes.insert(hash).inserted,
                  let episode = WatchManifestStore.shared.episode(hash: hash),
                  episode.status == .removing else { continue }
            let matchesSelection = !selectionIdentifier.isEmpty ?
                episode.selectionIdentifier == selectionIdentifier :
                (!selectionDate.isEmpty && timestamp(episode.watchAddedDate) == selectionDate)
            guard matchesSelection else { continue }
            acknowledgedHashes.insert(hash)
        }
        guard !acknowledgedHashes.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await WatchManifestStore.shared.removeEpisodes(hashes: acknowledgedHashes)
                WatchConnectivityController.shared.sendStorageStatus()
                self.autoFillEvictedEpisodes()
            } catch {
                WatchDiagnostics.log(
                    "manifest-remove-ack-failed",
                    message: "Bestätigte Watch-Löschungen konnten nicht aus dem Manifest entfernt werden",
                    metadata: ["error": error.localizedDescription, "episodeCount": "\(acknowledgedHashes.count)"]
                )
            }
        }
    }

    private func finishPendingRemovalCleanup(processNext: Bool) {
        pendingRemovalHashes.formUnion(activeRemovalHashes)
        activeRemovalHashes.removeAll()
        removalContext = nil
        removalCleanupInProgress = false
        let hasReadyPendingRemoval = pendingRemovalHashes.contains {
            $0 != WatchPlayerController.shared.playingEpisodeHash
        }
        let shouldProcessNext = (processNext || removalCleanupRequested) && hasReadyPendingRemoval
        if !storageMutationBlockers.isEmpty {
            removalCleanupRequested = shouldProcessNext
            let waiters = pendingStorageMutationWaiters
            pendingStorageMutationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            return
        }
        removalCleanupRequested = false
        if shouldProcessNext {
            enqueuePendingRemovalHashes([])
        } else if storageMutationBlockers.isEmpty {
            scheduleNextPendingDownloadPreparation()
        }
    }

    func handleBackgroundEvents() async {
        let lifecycle = backgroundSessionLifecycle.begin()
        await WatchManifestStore.shared.load()
        reattachDownloadTasks { [weak self] in
            self?.startQueuedDownloadsAfterReattach()
            lifecycle.markReattachFinished()
        }
        // Apple permits watchOS to suspend the app as soon as this background-task action
        // returns. Keep it alive until URLSession has delivered every delegate callback and
        // the async validation/durable manifest work launched by didComplete has also finished.
        await lifecycle.waitUntilFinished()
        backgroundSessionLifecycle.end(lifecycle)
    }

    private func startQueuedDownloadsAfterReattach() {
        finalizePendingRemovals()
        startNextQueuedDownloadIfIdle()
        autoFillEvictedEpisodes()
        WatchConnectivityController.shared.sendStorageStatus()
    }

    // Sequential download policy (User-Entscheid 06.07.): one episode at a time, in playback
    // order. Three parallel downloads competed for the watch's slow radio and none finished —
    // sequential makes the first episode playable as early as possible. A user tap
    // (prioritizeEpisode) still starts immediately and may run alongside the queue download.
    private func startNextQueuedDownloadIfIdle() {
        guard activeTasksByHash.isEmpty else { return }
        guard let next = WatchManifestStore.shared.sortedEpisodes.first(where: { $0.status == .queued && $0.localFileURL == nil }) else { return }
        startDownload(for: next)
    }

    // Keeps the watch as full as possible: pulls storage-evicted episodes back onto the watch when
    // space becomes available. Strictly anti-thrash by construction — it re-downloads ONLY into
    // genuinely free space (file size + the same reserve the rest of the code honors), highest
    // priority first, and NEVER evicts another episode to make room. It runs only while the queue is
    // idle, so it can't race or undo an in-flight download. Episodes whose size is still unknown
    // (expectedBytes == 0, never successfully probed) are left for an explicit tap rather than guessed.
    private func autoFillEvictedEpisodes() {
        guard activeTasksByHash.isEmpty else { return }
        guard !autoFillInProgress else {
            autoFillRequested = true
            return
        }
        autoFillInProgress = true
        let measurementEpisodes = WatchManifestStore.shared.episodes
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.autoFillInProgress = false
                if self.autoFillRequested {
                    self.autoFillRequested = false
                    self.autoFillEvictedEpisodes()
                }
            }
            let measuredFreeBytes = await WatchStorageManager.measureAvailableBytes(
                for: measurementEpisodes
            )
            WatchStorageManager.shared.recordAvailableBytes(measuredFreeBytes)
            guard activeTasksByHash.isEmpty else { return }

            let reserve = WatchStorageManager.minimumReserveBytes
            var projectedFree = measuredFreeBytes
            var selectedEpisodes: [WatchEpisode] = []
            for episode in WatchManifestStore.shared.sortedEpisodes
            where episode.status == .evicted && episode.localFileURL == nil && episode.expectedBytes > 0 {
                guard projectedFree - episode.expectedBytes >= reserve else { continue }
                projectedFree -= episode.expectedBytes
                selectedEpisodes.append(episode)
            }
            guard !selectedEpisodes.isEmpty else { return }
            let selectedHashes = Set(selectedEpisodes.map(\.episodeHash))
            do {
                try await WatchManifestStore.shared.updateEpisodes(hashes: selectedHashes) { item in
                    item.status = .queued
                    item.lastError = nil
                }
                WatchDiagnostics.log(
                    "storage-autofill",
                    message: "Watch laedt evictierte Folgen bei freiem Speicher nach",
                    metadata: [
                        "episodeCount": "\(selectedEpisodes.count)",
                        "projectedFreeAfter": "\(projectedFree)",
                    ]
                )
                // Re-queued episodes download one at a time like everything else.
                self.startNextQueuedDownloadIfIdle()
            } catch {
                WatchDiagnostics.log(
                    "storage-autofill-state-failed",
                    message: "Automatisches Nachladen konnte nicht gespeichert werden",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func reattachDownloadTasks(completion: @escaping @MainActor () -> Void) {
        reattachGeneration &+= 1
        pendingReattachCompletions.append(completion)
        guard !reattachInProgress else {
            reattachResolutionTask?.cancel()
            return
        }
        startLatestReattach()
    }

    private func startLatestReattach() {
        guard !pendingReattachCompletions.isEmpty else { return }
        reattachInProgress = true
        let generation = reattachGeneration
        let currentSession = session
        currentSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                guard let self else { return }
                await self.handleReattachTasksSnapshot(tasks, generation: generation)
            }
        }
    }

    private func handleReattachTasksSnapshot(_ tasks: [URLSessionTask], generation: UInt64) async {
        guard generation == reattachGeneration else {
            restartLatestReattach()
            return
        }
        if let storagePreparationTask {
            storagePreparationGeneration &+= 1
            await storagePreparationTask.value
        }
        guard generation == reattachGeneration else {
            restartLatestReattach()
            return
        }
        await reconcileManifestWithDownloadTasks(
            tasks.compactMap { $0 as? URLSessionDownloadTask },
            generation: generation
        )
        guard generation == reattachGeneration else {
            restartLatestReattach()
            return
        }

        reattachResolutionTask = nil
        reattachInProgress = false
        let completions = pendingReattachCompletions
        pendingReattachCompletions.removeAll()
        completions.forEach { $0() }
        startNextPendingDownloadPreparation()
    }

    private func restartLatestReattach() {
        reattachResolutionTask?.cancel()
        reattachResolutionTask = nil
        reattachInProgress = false
        startLatestReattach()
    }

    private func reconcileManifestWithDownloadTasks(
        _ tasks: [URLSessionDownloadTask],
        generation: UInt64
    ) async {
        var taskHashes = Set<String>()
        for task in tasks {
            guard let hash = task.taskDescription, !hash.isEmpty else {
                continue
            }
            guard let episode = WatchManifestStore.shared.episode(hash: hash),
                  episode.status == .downloading,
                  episode.localFileURL == nil,
                  !taskHashes.contains(hash) else {
                task.cancel()
                continue
            }

            if let activeTask = activeTasksByHash[hash], activeTask !== task {
                taskHashes.insert(hash)
                task.cancel()
                continue
            }

            taskHashes.insert(hash)
            activeTasksByHash[hash] = task
            if task.state == .suspended {
                task.resume()
            }
        }

        var fileCandidates: [WatchDownloadReconcileFileCandidate] = []
        var orphanedDownloadingSelectionsByHash: [String: (selectionIdentifier: String, watchAddedDate: Date)] = [:]
        for episode in WatchManifestStore.shared.episodes {
            if let originalLocalFileURL = episode.localFileURL {
                fileCandidates.append(WatchDownloadReconcileFileCandidate(
                    episodeHash: episode.episodeHash,
                    selectionIdentifier: episode.selectionIdentifier,
                    watchAddedDate: episode.watchAddedDate,
                    mediaURL: episode.mediaURL,
                    originalLocalFileURL: originalLocalFileURL
                ))
            } else if episode.status == .downloading,
                      !taskHashes.contains(episode.episodeHash),
                      activeTasksByHash[episode.episodeHash] == nil,
                      !finishingDownloadHashes.contains(episode.episodeHash) {
                orphanedDownloadingSelectionsByHash[episode.episodeHash] = (
                    episode.selectionIdentifier,
                    episode.watchAddedDate
                )
            }
        }

        let resolutionTask = Task.detached(priority: .utility) {
            Self.resolveReconcileLocalFiles(fileCandidates)
        }
        reattachResolutionTask = resolutionTask
        let fileResolutions = await resolutionTask.value
        reattachResolutionTask = nil
        guard generation == reattachGeneration else { return }

        var rerootedURLsByHash: [String: WatchDownloadReconcileFileResolution] = [:]
        var missingLocalFilesByHash: [String: WatchDownloadReconcileFileResolution] = [:]
        var rerootedDiagnosticSamples: [String] = []
        var missingDiagnosticSamples: [String] = []
        for resolution in fileResolutions {
            let candidate = resolution.candidate
            guard let episode = WatchManifestStore.shared.episode(hash: candidate.episodeHash),
                  episode.selectionIdentifier == candidate.selectionIdentifier,
                  episode.watchAddedDate == candidate.watchAddedDate,
                  episode.mediaURL == candidate.mediaURL,
                  episode.localFileURL == candidate.originalLocalFileURL else { continue }
            if let resolvedLocalFileURL = resolution.resolvedLocalFileURL {
                guard resolvedLocalFileURL != candidate.originalLocalFileURL else { continue }
                rerootedURLsByHash[candidate.episodeHash] = resolution
                if rerootedDiagnosticSamples.count < reconcileDiagnosticSampleLimit {
                    rerootedDiagnosticSamples.append(candidate.episodeHash)
                }
            } else {
                missingLocalFilesByHash[candidate.episodeHash] = resolution
                if missingDiagnosticSamples.count < reconcileDiagnosticSampleLimit {
                    missingDiagnosticSamples.append(candidate.episodeHash)
                }
            }
        }

        var orphanedDownloadingHashes: Set<String> = []
        for (episodeHash, selection) in orphanedDownloadingSelectionsByHash {
            guard activeTasksByHash[episodeHash] == nil,
                  !finishingDownloadHashes.contains(episodeHash),
                  let episode = WatchManifestStore.shared.episode(hash: episodeHash),
                  episode.status == .downloading,
                  episode.localFileURL == nil,
                  episode.selectionIdentifier == selection.selectionIdentifier,
                  episode.watchAddedDate == selection.watchAddedDate else { continue }
            orphanedDownloadingHashes.insert(episodeHash)
        }
        let changedHashes = Set(rerootedURLsByHash.keys)
            .union(missingLocalFilesByHash.keys)
            .union(orphanedDownloadingHashes)
        guard !changedHashes.isEmpty else { return }
        do {
            try await WatchManifestStore.shared.updateEpisodes(hashes: changedHashes) { item in
                if let resolution = rerootedURLsByHash[item.episodeHash],
                   item.selectionIdentifier == resolution.candidate.selectionIdentifier,
                   item.watchAddedDate == resolution.candidate.watchAddedDate,
                   item.mediaURL == resolution.candidate.mediaURL,
                   item.localFileURL == resolution.candidate.originalLocalFileURL {
                    item.localFileURL = resolution.resolvedLocalFileURL
                } else if let resolution = missingLocalFilesByHash[item.episodeHash],
                          item.selectionIdentifier == resolution.candidate.selectionIdentifier,
                          item.watchAddedDate == resolution.candidate.watchAddedDate,
                          item.mediaURL == resolution.candidate.mediaURL,
                          item.localFileURL == resolution.candidate.originalLocalFileURL {
                    item.status = item.status == .removing ? .removing : .queued
                    item.localFileURL = nil
                    item.actualFileSize = 0
                    item.actualDuration = 0
                    item.downloadedBytes = 0
                    item.chapters = []
                    item.chapterArtworkBaseURL = nil
                } else if let selection = orphanedDownloadingSelectionsByHash[item.episodeHash],
                          orphanedDownloadingHashes.contains(item.episodeHash),
                          item.status == .downloading,
                          item.localFileURL == nil,
                          item.selectionIdentifier == selection.selectionIdentifier,
                          item.watchAddedDate == selection.watchAddedDate {
                    item.status = .queued
                    item.downloadedBytes = 0
                }
            }
            if !rerootedURLsByHash.isEmpty {
                WatchDiagnostics.log("download-reconcile-pathRerooted", message: "Watch-Downloadpfade beim Reconcile normalisiert", metadata: [
                    "count": "\(rerootedURLsByHash.count)",
                    "sampleEpisodeHashes": rerootedDiagnosticSamples.joined(separator: ","),
                ])
            }
            if !missingLocalFilesByHash.isEmpty {
                WatchDiagnostics.log("download-reconcile-localFileMissing", message: "Watch-Dateien fehlen beim Reconcile", metadata: [
                    "count": "\(missingLocalFilesByHash.count)",
                    "sampleEpisodeHashes": missingDiagnosticSamples.joined(separator: ","),
                ])
            }
        } catch {
            WatchDiagnostics.log(
                "download-reconcile-state-failed",
                message: "Watch-Downloadzustand konnte nicht repariert werden",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private nonisolated static func resolveReconcileLocalFiles(
        _ candidates: [WatchDownloadReconcileFileCandidate]
    ) -> [WatchDownloadReconcileFileResolution] {
        guard !candidates.isEmpty else { return [] }
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDirectory = documentsDirectory.appendingPathComponent("Episodes", isDirectory: true)
        var resolutions: [WatchDownloadReconcileFileResolution] = []
        resolutions.reserveCapacity(candidates.count)

        for startIndex in stride(
            from: 0,
            to: candidates.count,
            by: reconcileFileResolutionBatchSize
        ) {
            guard !Task.isCancelled else { return [] }
            let endIndex = min(startIndex + reconcileFileResolutionBatchSize, candidates.count)
            for candidate in candidates[startIndex..<endIndex] {
                guard !Task.isCancelled else { return [] }
                var fileNames: [String] = []
                let storedFileName = candidate.originalLocalFileURL.lastPathComponent
                if !storedFileName.isEmpty {
                    fileNames.append(storedFileName)
                }
                let mediaExtension = candidate.mediaURL.pathExtension
                let computedFileName = mediaExtension.isEmpty
                    ? candidate.episodeHash
                    : "\(candidate.episodeHash).\(mediaExtension)"
                if !computedFileName.isEmpty, !fileNames.contains(computedFileName) {
                    fileNames.append(computedFileName)
                }

                var resolvedLocalFileURL: URL?
                for fileName in fileNames {
                    let candidateURL = downloadsDirectory.appendingPathComponent(fileName)
                    if fileManager.fileExists(atPath: candidateURL.path) {
                        resolvedLocalFileURL = candidateURL
                        break
                    }
                }
                if resolvedLocalFileURL == nil,
                   fileManager.fileExists(atPath: candidate.originalLocalFileURL.path) {
                    resolvedLocalFileURL = candidate.originalLocalFileURL
                }
                resolutions.append(WatchDownloadReconcileFileResolution(
                    candidate: candidate,
                    resolvedLocalFileURL: resolvedLocalFileURL
                ))
            }
        }
        return resolutions
    }

    private nonisolated static func downloadedFileAttributes(
        for fileURL: URL,
        size: Int64
    ) async -> WatchDownloadedFileAttributes {
        let asset = AVURLAsset(url: fileURL)
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        let durationTime = (try? await asset.load(.duration)) ?? .zero
        let seconds = CMTimeGetSeconds(durationTime)
        let duration = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        return WatchDownloadedFileAttributes(
            size: size,
            duration: duration,
            isPlayable: isPlayable
        )
    }

    private func isCurrentDownload(_ downloadTask: URLSessionDownloadTask, hash: String) -> Bool {
        activeTasksByHash[hash] === downloadTask &&
            WatchManifestStore.shared.episode(hash: hash)?.status == .downloading
    }

    private func discardFinishedDownload(
        fileURL: URL,
        hash: String,
        chapterMetadata: WatchChapterExtractionResult? = nil
    ) async {
        var fileURLs = Set([fileURL])
        if let chapterMetadata, let artworkBaseURL = chapterMetadata.artworkBaseURL {
            for chapter in chapterMetadata.chapters {
                guard let imageFileName = chapter.imageFileName else { continue }
                fileURLs.insert(artworkBaseURL.appendingPathComponent(imageFileName))
            }
        }
        if let errorDescription = await Self.removeFinishedDownloadFiles(fileURLs) {
            WatchDiagnostics.log(
                "download-discard-failed",
                message: "Veraltete Watch-Downloaddateien konnten nicht vollständig entfernt werden",
                metadata: ["episodeHash": hash, "error": errorDescription]
            )
        }
    }

    private nonisolated static func prepareFinishedDownloadFile(
        stagedLocation: URL,
        episode: WatchEpisode,
        transport: WatchDownloadTransportSnapshot
    ) async -> WatchFinishedDownloadPreparationResult {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let storageError = NSLocalizedString(
                "Download-Datei konnte auf der Watch nicht gespeichert werden.",
                comment: ""
            )
            let attributes = try? fileManager.attributesOfItem(atPath: stagedLocation.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            if let failure = Self.downloadValidationError(
                transport: transport,
                actualSize: size,
                feedExpectedBytes: episode.expectedBytes
            ) {
                return .invalid(failure)
            }

            guard let documentsDirectory = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first else {
                return .fileFailure(storageError)
            }
            let downloadsDirectory = documentsDirectory.appendingPathComponent(
                "Episodes",
                isDirectory: true
            )
            do {
                try fileManager.createDirectory(
                    at: downloadsDirectory,
                    withIntermediateDirectories: true
                )
                var fileExtension = stagedLocation.pathExtension.isEmpty
                    ? episode.mediaURL.pathExtension
                    : stagedLocation.pathExtension
                if fileExtension.isEmpty, let mimeExtension = Self.fileExtension(
                    forMIMEType: transport.mimeType
                ) {
                    fileExtension = mimeExtension
                }
                let fileName = fileExtension.isEmpty
                    ? episode.episodeHash
                    : "\(episode.episodeHash).\(fileExtension)"
                let destination = downloadsDirectory.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: stagedLocation, to: destination)
                guard let supportDirectory = fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first else {
                    try? fileManager.removeItem(at: destination)
                    return .fileFailure(storageError)
                }
                let artworkDirectory = supportDirectory.appendingPathComponent(
                    "ChapterArtwork",
                    isDirectory: true
                )
                return .prepared(
                    destination: destination,
                    artworkDirectory: artworkDirectory,
                    size: size
                )
            } catch {
                return .fileFailure(error.localizedDescription)
            }
        }.value
    }

    private nonisolated static func removeFinishedDownloadFiles(
        _ fileURLs: Set<URL>
    ) async -> String? {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var firstErrorDescription: String?
            for fileURL in fileURLs where fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    firstErrorDescription = firstErrorDescription ?? error.localizedDescription
                }
            }
            return firstErrorDescription
        }.value
    }

    private nonisolated static func downloadValidationError(
        transport: WatchDownloadTransportSnapshot,
        actualSize: Int64,
        feedExpectedBytes: Int64
    ) -> WatchDownloadValidationFailure? {
        if let statusCode = transport.statusCode {
            if !(200..<300).contains(statusCode) {
                return .http(statusCode: statusCode)
            }
            if statusCode == 206,
               !isCompletePartialContentResponse(
                   contentRange: transport.contentRange,
                   actualSize: actualSize
               ) {
                return .partialContent(actualSize: actualSize)
            }
        }
        if actualSize <= 0 {
            return .empty
        }
        let expectedSize = transport.expectedBytes
        if expectedSize > 0, actualSize < expectedSize {
            return .transportTruncated(
                actualSize: actualSize,
                expectedSize: expectedSize
            )
        }
        // A cleanly closed connection without Content-Length looks like a SUCCESSFUL download to
        // URLSession even when only a prefix arrived (proven with megaphone-style mp3 streams:
        // a 120 KB prefix of a 14 MB file passes every check above and AVFoundation's isPlayable,
        // then plays for exactly 7.5 seconds — the customer's "stops after 6-8 seconds"). When the
        // transport declared no size, fall back to the feed's enclosure length: anything below half
        // the declared size is a truncated body, not a complete file.
        if expectedSize <= 0,
           feedExpectedBytes > 0,
           actualSize < feedExpectedBytes / 2 {
            return .feedTruncated(
                actualSize: actualSize,
                expectedSize: feedExpectedBytes
            )
        }
        return nil
    }

    private func logDownloadValidationFailure(
        _ failure: WatchDownloadValidationFailure,
        hash: String
    ) {
        let message: String
        var metadata = ["episodeHash": hash]
        switch failure {
        case let .http(statusCode):
            message = "Watch-Download HTTP-Fehler"
            metadata["httpStatus"] = "\(statusCode)"
        case let .partialContent(actualSize):
            message = "Watch-Download ist HTTP 206 Partial Content"
            metadata["httpStatus"] = "206"
            metadata["actualBytes"] = "\(actualSize)"
        case .empty:
            message = "Watch-Downloaddatei ist leer"
            metadata["actualBytes"] = "0"
        case let .transportTruncated(actualSize, expectedSize):
            message = "Watch-Downloaddatei ist unvollstaendig"
            metadata["actualBytes"] = "\(actualSize)"
            metadata["expectedBytes"] = "\(expectedSize)"
        case let .feedTruncated(actualSize, expectedSize):
            message = "Watch-Downloaddatei ist deutlich kleiner als im Feed deklariert"
            metadata["actualBytes"] = "\(actualSize)"
            metadata["feedExpectedBytes"] = "\(expectedSize)"
        }
        WatchDiagnostics.log(
            "download-validation-failed",
            message: message,
            metadata: metadata
        )
    }

    private nonisolated static func isCompletePartialContentResponse(
        contentRange: String?,
        actualSize: Int64
    ) -> Bool {
        guard
            actualSize > 0,
            let contentRange = contentRange?.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return false
        }

        let components = contentRange.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard components.count == 2, components[0].lowercased() == "bytes" else {
            return false
        }

        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard
            rangeAndTotal.count == 2,
            let totalSize = Int64(rangeAndTotal[1])
        else {
            return false
        }

        // URLSession reassembles the complete file even when the final response is a *resumed*
        // 206 whose Content-Range starts at an offset > 0 — the usual case after a background
        // download is interrupted and continued (the customer's failing downloads showed partial
        // bytes before the 206). The range bounds describe only the last network segment, not the
        // file on disk, so requiring the range to start at byte 0 would reject every resumed
        // download. Completeness is proven by the staged file matching the resource's declared
        // total size; a truncated file has actualSize < totalSize and stays rejected, and the
        // downstream AVURLAsset playability check guards against a same-size-but-corrupt file.
        return totalSize == actualSize
    }

    // Stops a running download that is about to breach the free-space reserve, marks the episode as
    // storage-evicted ("Speicher voll"), and tells the phone so its list/warning stays in sync.
    private func abortDownloadForInsufficientStorage(
        hash: String,
        totalBytesExpectedToWrite: Int64,
        measuredFreeBytes: Int64
    ) {
        let episode = WatchManifestStore.shared.episode(hash: hash)
        activeTasksByHash[hash]?.cancel()
        activeTasksByHash[hash] = nil
        lastProgressReportByHash[hash] = nil
        WatchManifestStore.shared.updateEpisode(hash: hash) { item in
            item.status = .evicted
            item.localFileURL = nil
            item.actualFileSize = 0
            item.downloadedBytes = 0
            if totalBytesExpectedToWrite > 0 {
                item.expectedBytes = max(item.expectedBytes, totalBytesExpectedToWrite)
            }
            item.lastError = NSLocalizedString("Nicht genügend Speicher auf der Watch.", comment: "")
        }
        var metadata = episode.map { WatchDiagnostics.metadata(for: $0) } ?? ["episodeHash": hash]
        metadata["freeBytes"] = "\(measuredFreeBytes)"
        metadata["totalBytesExpected"] = "\(totalBytesExpectedToWrite)"
        WatchDiagnostics.log("download-storage-aborted", message: "Watch-Download wegen Speichermangel abgebrochen", metadata: metadata)
        sendStorageEviction(hash: hash)
        WatchConnectivityController.shared.sendStorageStatus()
    }

    // Single channel for "this episode is storage-evicted / Speicher voll" so the phone applies one
    // consistent status regardless of which path (pre-check, make-room eviction, or live abort) hit it.
    private func sendStorageEviction(hash: String) {
        WatchConnectivityController.shared.reportTerminalDownloadState(forEpisodeHash: hash)
    }

    private func markDownloadFailed(hash: String, error: String) async {
        do {
            try await WatchManifestStore.shared.updateEpisodeDurably(hash: hash) { item in
                item.status = .failed
                item.lastError = error
            }
        } catch {
            WatchDiagnostics.log(
                "download-failed-state-persist-failed",
                message: "Fehlgeschlagener Watch-Download konnte nicht gespeichert werden",
                metadata: ["episodeHash": hash, "error": error.localizedDescription]
            )
            return
        }
        WatchConnectivityController.shared.reportTerminalDownloadState(forEpisodeHash: hash)
    }

    private func timestamp(_ date: Date = Date()) -> String {
        eventDateFormatter.string(from: date)
    }

    // Maps the transport's MIME type to a file extension so AVFoundation can identify the
    // container when the media URL itself carries no extension (tracking redirects).
    nonisolated static func fileExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType = mimeType?.lowercased().components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        switch mimeType {
        case "audio/mpeg", "audio/mp3", "audio/mpeg3":
            return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a", "audio/mp4a-latm":
            return "m4a"
        case "audio/aac", "audio/x-aac", "audio/aacp":
            return "aac"
        case "audio/ogg", "application/ogg":
            return "ogg"
        case "audio/wav", "audio/x-wav":
            return "wav"
        default:
            return nil
        }
    }
}

extension WatchDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let stagedLocation = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstacastWatchDownload-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stagedLocation)
        } catch {
            stagedLocationsLock.lock()
            stagingFailureDescriptionsByTaskIdentifier[downloadTask.taskIdentifier] = error.localizedDescription
            stagedLocationsLock.unlock()
            return
        }

        // Only stage here. Validation/registration runs from didCompleteWithError, which the
        // serial delegate queue delivers strictly AFTER this callback: a detached MainActor task
        // started here raced didCompleteWithError's task — the next queued download began while
        // the finished episode was still unregistered (file on disk but not yet an eviction
        // candidate), so a tight-storage start was wrongly refused with "Speicher voll"
        // (proven in the simulator with a 51 MB budget).
        stagedLocationsLock.lock()
        stagedLocationsByTaskIdentifier[downloadTask.taskIdentifier] = stagedLocation
        stagedLocationsLock.unlock()
    }

    @MainActor
    private func processFinishedDownload(hash: String, stagedLocation: URL, downloadTask: URLSessionDownloadTask) async {
        guard isCurrentDownload(downloadTask, hash: hash) else {
            await discardFinishedDownload(fileURL: stagedLocation, hash: hash)
            return
        }
        guard let episode = WatchManifestStore.shared.episode(hash: hash) else {
            await discardFinishedDownload(fileURL: stagedLocation, hash: hash)
            return
        }
        let episodeIdentity = WatchStorageEpisodeIdentity(episode: episode)
        let httpResponse = downloadTask.response as? HTTPURLResponse
        let transport = WatchDownloadTransportSnapshot(
            statusCode: httpResponse?.statusCode,
            contentRange: httpResponse?.value(forHTTPHeaderField: "Content-Range"),
            expectedBytes: downloadTask.countOfBytesExpectedToReceive,
            mimeType: downloadTask.response?.mimeType
        )
        let preparation = await Self.prepareFinishedDownloadFile(
            stagedLocation: stagedLocation,
            episode: episode,
            transport: transport
        )
        guard isCurrentDownload(downloadTask, hash: hash) else {
            if case let .prepared(destination, _, _) = preparation {
                await discardFinishedDownload(fileURL: destination, hash: hash)
            } else {
                await discardFinishedDownload(fileURL: stagedLocation, hash: hash)
            }
            return
        }

        let destination: URL
        let artworkDirectory: URL
        let fileSize: Int64
        switch preparation {
        case let .prepared(preparedDestination, preparedArtworkDirectory, preparedSize):
            destination = preparedDestination
            artworkDirectory = preparedArtworkDirectory
            fileSize = preparedSize
        case let .invalid(failure):
            logDownloadValidationFailure(failure, hash: hash)
            await discardFinishedDownload(fileURL: stagedLocation, hash: hash)
            guard isCurrentDownload(downloadTask, hash: hash) else { return }
            await markDownloadFailed(hash: hash, error: failure.userMessage)
            return
        case let .fileFailure(errorDescription):
            await discardFinishedDownload(fileURL: stagedLocation, hash: hash)
            guard isCurrentDownload(downloadTask, hash: hash) else { return }
            await markDownloadFailed(hash: hash, error: errorDescription)
            return
        }
        guard isCurrentDownload(downloadTask, hash: hash),
              let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
              episodeIdentity.matches(currentEpisode) else {
            await discardFinishedDownload(fileURL: destination, hash: hash)
            return
        }

        let attributes = await Self.downloadedFileAttributes(
            for: destination,
            size: fileSize
        )
        guard isCurrentDownload(downloadTask, hash: hash),
              let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
              episodeIdentity.matches(currentEpisode) else {
            await discardFinishedDownload(fileURL: destination, hash: hash)
            return
        }
        // duration <= 0 is a hard failure too: for a file AVFoundation cannot read (random
        // bytes, unknown container) isPlayable still answers an optimistic true while the
        // measured duration collapses to 0 — proven in the watch simulator. A finished
        // podcast download always has a measurable duration.
        if attributes.size <= 0 || !attributes.isPlayable || attributes.duration <= 0 {
            WatchDiagnostics.log("download-validation-failed", message: "Watch-Audiodatei ist nicht spielbar", metadata: [
                "episodeHash": hash,
                "actualBytes": "\(attributes.size)",
                "actualDuration": "\(attributes.duration)",
                "isPlayable": attributes.isPlayable ? "true" : "false",
            ])
            await discardFinishedDownload(fileURL: destination, hash: hash)
            guard isCurrentDownload(downloadTask, hash: hash) else { return }
            await markDownloadFailed(
                hash: hash,
                error: NSLocalizedString("Geladene Audiodatei konnte nicht validiert werden.", comment: "")
            )
            return
        }
        // Transport-independent truncation check: a truncated mp3/aac prefix is "playable" for
        // AVFoundation, but its measured duration collapses to the received fraction (120 KB of
        // a 90-minute episode measure as 7.5 s). The feed's duration hint is in the manifest —
        // a file measuring under half of a substantial hint is a truncated body. The 10-minute
        // floor keeps wrong hints on short episodes from rejecting good files.
        if episode.durationHint >= 600,
           attributes.duration > 0,
           attributes.duration < episode.durationHint / 2 {
            WatchDiagnostics.log("download-validation-failed", message: "Watch-Audiodatei ist deutlich kuerzer als im Feed deklariert", metadata: [
                "episodeHash": hash,
                "actualBytes": "\(attributes.size)",
                "actualDuration": "\(attributes.duration)",
                "durationHint": "\(episode.durationHint)",
            ])
            await discardFinishedDownload(fileURL: destination, hash: hash)
            guard isCurrentDownload(downloadTask, hash: hash) else { return }
            await markDownloadFailed(
                hash: hash,
                error: NSLocalizedString("Geladene Datei ist unvollständig.", comment: "")
            )
            return
        }

        let chapterMetadata = await WatchChapterExtractor.shared.extractChapters(
            from: destination,
            episodeHash: hash,
            artworkDirectory: artworkDirectory
        )
        guard isCurrentDownload(downloadTask, hash: hash),
              let currentEpisode = WatchManifestStore.shared.episode(hash: hash),
              episodeIdentity.matches(currentEpisode) else {
            await discardFinishedDownload(
                fileURL: destination,
                hash: hash,
                chapterMetadata: chapterMetadata
            )
            return
        }

        do {
            try await WatchManifestStore.shared.updateEpisodeDurably(hash: hash) { item in
                item.status = .downloaded
                item.localFileURL = destination
                item.actualFileSize = attributes.size
                item.actualDuration = attributes.duration
                item.downloadedBytes = attributes.size
                item.expectedBytes = attributes.size
                item.lastError = nil
                item.chapters = chapterMetadata.chapters
                item.chapterArtworkBaseURL = chapterMetadata.artworkBaseURL
            }
        } catch {
            await discardFinishedDownload(
                fileURL: destination,
                hash: hash,
                chapterMetadata: chapterMetadata
            )
            WatchDiagnostics.log(
                "download-finished-state-failed",
                message: "Abgeschlossener Watch-Download konnte nicht gespeichert werden",
                metadata: ["episodeHash": hash, "error": error.localizedDescription]
            )
            return
        }
        WatchDiagnostics.log("download-finished", message: "Watch-Download abgeschlossen", metadata: [
            "episodeHash": hash,
            "actualBytes": "\(attributes.size)",
            "actualDuration": "\(attributes.duration)",
            "isPlayable": attributes.isPlayable ? "true" : "false",
            "fileName": destination.lastPathComponent,
        ])
        WatchConnectivityController.shared.reportTerminalDownloadState(forEpisodeHash: hash)
        WatchConnectivityController.shared.sendStorageStatus()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Register synchronously on URLSession's serial delegate queue. Finish-events may be
        // delivered as soon as this callback returns, while the MainActor work below is pending.
        let backgroundFinalization = backgroundSessionLifecycle.beginFinalization()
        let hash = task.taskDescription ?? ""
        stagedLocationsLock.lock()
        let stagedLocation = stagedLocationsByTaskIdentifier.removeValue(
            forKey: task.taskIdentifier
        )
        let stagingFailureDescription = stagingFailureDescriptionsByTaskIdentifier.removeValue(
            forKey: task.taskIdentifier
        )
        stagedLocationsLock.unlock()
        let downloadTask = task as? URLSessionDownloadTask

        Task { @MainActor in
            defer { backgroundFinalization?.finishFinalization() }
            guard let downloadTask else {
                if let stagedLocation {
                    await discardFinishedDownload(fileURL: stagedLocation, hash: hash)
                }
                return
            }
            let startedFinishingCurrentDownload = isCurrentDownload(downloadTask, hash: hash)
            if startedFinishingCurrentDownload {
                finishingDownloadHashes.insert(hash)
            }

            // Success path: validate + register the staged file FIRST, then advance the queue.
            // The episode must be fully registered (localFileURL, .downloaded) before the next
            // download's storage pre-check runs, otherwise it occupies disk space without being
            // an eviction candidate.
            if let stagingFailureDescription, startedFinishingCurrentDownload {
                await markDownloadFailed(hash: hash, error: stagingFailureDescription)
            } else if error == nil, let stagedLocation, startedFinishingCurrentDownload {
                await processFinishedDownload(hash: hash, stagedLocation: stagedLocation, downloadTask: downloadTask)
            } else if let stagedLocation {
                await discardFinishedDownload(fileURL: stagedLocation, hash: hash)
            }

            let completionStillOwnsTask = activeTasksByHash[hash] === downloadTask
            if completionStillOwnsTask {
                activeTasksByHash[hash] = nil
            }
            if startedFinishingCurrentDownload {
                finishingDownloadHashes.remove(hash)
            }
            if startedFinishingCurrentDownload,
               stagingFailureDescription == nil,
               let error,
               (error as NSError).code != NSURLErrorCancelled {
                let nsError = error as NSError
                WatchDiagnostics.log("download-transport-error", message: "Watch-Download Transportfehler", metadata: [
                    "episodeHash": hash,
                    "errorDomain": nsError.domain,
                    "errorCode": "\(nsError.code)",
                    "errorDescription": nsError.localizedDescription,
                ])
                await markDownloadFailed(hash: hash, error: error.localizedDescription)
            }
            guard startedFinishingCurrentDownload || completionStillOwnsTask else { return }
            // Sequential queue: this download is done (success or failure) — start the next one,
            // then backfill any evicted episodes that fit the freed/leftover space.
            startNextQueuedDownloadIfIdle()
            autoFillEvictedEpisodes()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // This may precede handleBackgroundEvents/waiter installation, so the lifecycle latches
        // it instead of trying to resume a one-shot continuation directly.
        backgroundSessionLifecycle.markDelegateEventsFinished()
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let hash = downloadTask.taskDescription ?? ""
        Task { @MainActor in
            // A late progress callback after the storage guard aborted (.evicted) or the task failed
            // must not resurrect the episode back to .downloading.
            let currentEpisode = WatchManifestStore.shared.episode(hash: hash)
            guard activeTasksByHash[hash] === downloadTask,
                  currentEpisode?.status == .downloading else { return }

            if totalBytesExpectedToWrite > 0,
               let currentExpectedBytes = currentEpisode?.expectedBytes,
               totalBytesExpectedToWrite > currentExpectedBytes,
               storagePreparationTask != nil {
                // A parallel task just disclosed a larger remaining reservation than the immutable
                // storage snapshot contained. Re-plan in the next queue turn; never start from the
                // now-underreserved capacity result.
                storagePreparationGeneration &+= 1
            }

            let now = Date()
            if let last = lastProgressReportByHash[hash], now.timeIntervalSince(last) < 2 {
                return
            }
            lastProgressReportByHash[hash] = now

            // Behind the 2 s throttle: updateEpisode persists the whole manifest JSON to disk —
            // running it on EVERY didWriteData callback burned disk writes several times a second.
            WatchManifestStore.shared.updateEpisode(hash: hash) { item in
                item.status = .downloading
                item.downloadedBytes = totalBytesWritten
                // Without Content-Length the transport reports -1. Overwriting with max(0, -1) = 0
                // erased the feed's enclosure size on the FIRST progress callback — which is exactly
                // the value the truncation validation falls back to when the transport declared no
                // size. Keep the feed value unless the transport actually knows better.
                if totalBytesExpectedToWrite > 0 {
                    item.expectedBytes = totalBytesExpectedToWrite
                }
            }

            // Live storage guard: a download whose size the feed never declared (expectedBytes == 0,
            // e.g. megaphone) slips past the pre-download capacity check, which could only reserve the
            // 50 MB floor. If it now threatens that reserve, stop it before the watch is starved —
            // storage pressure is what suspends the app and cuts playback. The capacity read runs off
            // MainActor; revalidation below prevents a stale result from aborting a replacement task.
            let measurementEpisodes = WatchManifestStore.shared.episodes
            let measuredFreeBytes = await WatchStorageManager.measureAvailableBytes(
                for: measurementEpisodes
            )
            guard activeTasksByHash[hash] === downloadTask,
                  WatchManifestStore.shared.episode(hash: hash)?.status == .downloading,
                  lastProgressReportByHash[hash] == now else { return }
            WatchStorageManager.shared.recordAvailableBytes(measuredFreeBytes)
            if measuredFreeBytes < WatchStorageManager.minimumReserveBytes {
                abortDownloadForInsufficientStorage(
                    hash: hash,
                    totalBytesExpectedToWrite: totalBytesExpectedToWrite,
                    measuredFreeBytes: measuredFreeBytes
                )
                return
            }

            WatchConnectivityController.shared.send(type: "watch.downloadProgress", payload: [
                "episodeHash": hash,
                "downloadedBytes": totalBytesWritten,
                "expectedBytes": max(0, totalBytesExpectedToWrite),
                "timestamp": timestamp(),
            ], delivery: .live)

            // Keep the storage displays (watch header and iOS storage bar) moving while a
            // download runs — previously the phone only got a storage status after completion.
            if lastStorageStatusSendDate.map({ now.timeIntervalSince($0) >= 10 }) ?? true {
                lastStorageStatusSendDate = now
                WatchConnectivityController.shared.sendStorageStatus()
            }
        }
    }
}
