import Foundation

private struct WatchManifestNormalizationSummary: Sendable {
    var checked = 0
    var rerooted = 0
    var missing = 0
    var unchanged = 0

    var metadata: [String: String] {
        [
            "checked": "\(checked)",
            "rerooted": "\(rerooted)",
            "missing": "\(missing)",
            "unchanged": "\(unchanged)",
        ]
    }
}

private struct WatchManifestNormalizationChange: Sendable {
    let originalEpisode: WatchEpisode
    let resolvedURL: URL?
}

private struct WatchManifestNormalizationIdentity: Hashable {
    let episodeHash: String
    let mediaURL: URL
    let localFileURL: URL?

    init(episode: WatchEpisode) {
        episodeHash = episode.episodeHash
        mediaURL = episode.mediaURL
        localFileURL = episode.localFileURL
    }
}

private struct WatchEpisodeRuntimeState: Codable, Sendable {
    let generation: UInt64
    let episodeHash: String
    let selectionIdentifier: String
    let watchAddedDate: Date
    let mediaURL: URL
    let status: WatchEpisodeStatus
    let lastPlaybackPosition: Int
    let lastPlaybackDate: Date?
    let downloadedBytes: Int64
    let expectedBytes: Int64

    init(episode: WatchEpisode, generation: UInt64) {
        self.generation = generation
        episodeHash = episode.episodeHash
        selectionIdentifier = episode.selectionIdentifier
        watchAddedDate = episode.watchAddedDate
        mediaURL = episode.mediaURL
        status = episode.status
        lastPlaybackPosition = episode.lastPlaybackPosition
        lastPlaybackDate = episode.lastPlaybackDate
        downloadedBytes = episode.downloadedBytes
        expectedBytes = episode.expectedBytes
    }
}

private struct WatchEpisodeRuntimeStateLoadResult: Sendable {
    let states: [WatchEpisodeRuntimeState]
    let invalidRecordCount: Int
}

private struct WatchEpisodeRuntimeStateReplay: Sendable {
    let episodes: [WatchEpisode]
    let maximumGeneration: UInt64
    let appliedCount: Int
}

private enum WatchManifestMergeDiagnosticCategory: String, CaseIterable, Sendable {
    case downloadReset = "download-reset"
    case mediaURLChanged = "media-url-changed"
    case localFileStateChanged = "local-file-state-changed"
}

private struct WatchManifestMergeDiagnosticSample: Sendable {
    let result: WatchEpisode
    let wasDownloaded: Bool
    let keptDownloaded: Bool
    let resetDownloaded: Bool
    let mediaURLChanged: Bool
    let entryExpectedFileSize: Int64
    let existingActualFileSize: Int64
}

private struct WatchManifestMergeDiagnosticAggregate: Sendable {
    var count: Int
    let sample: WatchManifestMergeDiagnosticSample
}

private enum WatchManifestMergeMode: Sendable {
    case replace
    case upsert
}

private struct WatchManifestMergePlan: Sendable {
    let episodes: [WatchEpisode]
    let pendingRemovals: [WatchEpisode]
    let diagnostics: [WatchManifestMergeDiagnosticCategory: WatchManifestMergeDiagnosticAggregate]
    let beforeCounts: [String: String]
    let afterCounts: [String: String]
    let uniqueEntryCount: Int
    let removedStoredDuplicateCount: Int
}

private enum WatchManifestMergeError: LocalizedError {
    case superseded

    var errorDescription: String? {
        "The Watch manifest changed while it was being prepared."
    }
}

private struct WatchManifestNormalizationResult: Sendable {
    let episodes: [WatchEpisode]
    let changes: [WatchManifestNormalizationChange]
    let summary: WatchManifestNormalizationSummary
}

private struct WatchManifestArchive: Codable, Sendable {
    let manifestRevision: Int64
    let runtimeStateGeneration: UInt64
    let episodes: [WatchEpisode]

    private enum CodingKeys: String, CodingKey {
        case manifestRevision
        case runtimeStateGeneration
        case episodes
    }

    init(
        manifestRevision: Int64,
        runtimeStateGeneration: UInt64 = 0,
        episodes: [WatchEpisode]
    ) {
        self.manifestRevision = manifestRevision
        self.runtimeStateGeneration = runtimeStateGeneration
        self.episodes = episodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        manifestRevision = try container.decode(Int64.self, forKey: .manifestRevision)
        runtimeStateGeneration = try container.decodeIfPresent(
            UInt64.self,
            forKey: .runtimeStateGeneration
        ) ?? 0
        episodes = try container.decode([WatchEpisode].self, forKey: .episodes)
    }
}

private struct WatchManifestPersistenceSnapshot: Sendable {
    let archive: WatchManifestArchive
    let supportDirectory: URL
    let manifestURL: URL
    let generation: UInt64
}

private struct WatchManifestPersistenceCommit: Sendable {
    let archive: WatchManifestArchive
    let generation: UInt64
}

private struct WatchManifestPersistenceWaiter {
    let generation: UInt64
    let continuation: CheckedContinuation<WatchManifestPersistenceCommit, any Error>
}

private enum WatchManifestLoadResult: Sendable {
    case missing
    case archive(WatchManifestArchive, migratedLegacyArchive: Bool)
    case failure(String)
}

enum WatchManifestLoadState: Equatable {
    case loading
    case loaded
    case failed
}

private enum WatchManifestInitialLoadOutcome {
    case loaded
    case failed
    case superseded
}

private actor WatchManifestPersistenceWriter {
    private var committedArchive = WatchManifestArchive(manifestRevision: 0, episodes: [])
    private var committedGeneration: UInt64 = 0
    private var activeSnapshot: WatchManifestPersistenceSnapshot?
    private var pendingSnapshot: WatchManifestPersistenceSnapshot?
    private var writeInProgress = false
    private var durableWaiters: [WatchManifestPersistenceWaiter] = []
    private var lastFailedGeneration: UInt64 = 0
    private var lastFailure: NSError?

    func seedCommittedArchive(_ archive: WatchManifestArchive) {
        guard !writeInProgress, pendingSnapshot == nil else { return }
        committedArchive = archive
        committedGeneration = 0
        lastFailedGeneration = 0
        lastFailure = nil
    }

    func persist(
        archive: WatchManifestArchive,
        supportDirectory: URL,
        manifestURL: URL,
        generation: UInt64
    ) async throws -> WatchManifestPersistenceCommit {
        if generation <= committedGeneration {
            return WatchManifestPersistenceCommit(archive: committedArchive, generation: committedGeneration)
        }
        if generation <= lastFailedGeneration, !writeInProgress, pendingSnapshot == nil {
            throw lastFailure ?? NSError(
                domain: "WatchManifestPersistence",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Watch manifest persistence failed."]
            )
        }

        let minimumRevision = max(
            max(
                committedArchive.manifestRevision,
                activeSnapshot?.archive.manifestRevision ?? 0
            ),
            pendingSnapshot?.archive.manifestRevision ?? 0
        )
        let snapshot = WatchManifestPersistenceSnapshot(
            archive: WatchManifestArchive(
                manifestRevision: max(archive.manifestRevision, minimumRevision),
                runtimeStateGeneration: archive.runtimeStateGeneration,
                episodes: archive.episodes
            ),
            supportDirectory: supportDirectory,
            manifestURL: manifestURL,
            generation: generation
        )
        let highestQueuedGeneration = max(
            max(committedGeneration, activeSnapshot?.generation ?? 0),
            pendingSnapshot?.generation ?? 0
        )
        if generation > highestQueuedGeneration {
            pendingSnapshot = snapshot
        }
        startWriteLoopIfNeeded()

        return try await withCheckedThrowingContinuation { continuation in
            if generation <= committedGeneration {
                continuation.resume(returning: WatchManifestPersistenceCommit(
                    archive: committedArchive,
                    generation: committedGeneration
                ))
                return
            }
            durableWaiters.append(WatchManifestPersistenceWaiter(
                generation: generation,
                continuation: continuation
            ))
        }
    }

    func waitForCommit(atLeast generation: UInt64) async throws -> WatchManifestPersistenceCommit {
        if generation <= committedGeneration {
            return WatchManifestPersistenceCommit(archive: committedArchive, generation: committedGeneration)
        }
        if generation <= lastFailedGeneration, !writeInProgress, pendingSnapshot == nil {
            throw lastFailure ?? NSError(
                domain: "WatchManifestPersistence",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Watch manifest persistence failed."]
            )
        }
        return try await withCheckedThrowingContinuation { continuation in
            durableWaiters.append(WatchManifestPersistenceWaiter(
                generation: generation,
                continuation: continuation
            ))
        }
    }

    private func startWriteLoopIfNeeded() {
        guard !writeInProgress else { return }
        writeInProgress = true
        Task {
            await runWriteLoop()
        }
    }

    private func runWriteLoop() async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            activeSnapshot = snapshot
            do {
                try await Self.write(snapshot)
                if snapshot.generation >= committedGeneration {
                    committedArchive = snapshot.archive
                    committedGeneration = snapshot.generation
                }
                lastFailure = nil
                let commit = WatchManifestPersistenceCommit(
                    archive: committedArchive,
                    generation: committedGeneration
                )
                let completedWaiters = durableWaiters.filter { waiter in
                    waiter.generation <= committedGeneration
                }
                durableWaiters.removeAll { waiter in
                    waiter.generation <= committedGeneration
                }
                for waiter in completedWaiters {
                    waiter.continuation.resume(returning: commit)
                }
                activeSnapshot = nil
            } catch {
                activeSnapshot = nil
                if let pendingSnapshot, pendingSnapshot.generation > snapshot.generation {
                    continue
                }
                let failure = error as NSError
                lastFailedGeneration = max(lastFailedGeneration, snapshot.generation)
                lastFailure = failure
                let failedWaiters = durableWaiters.filter { waiter in
                    waiter.generation <= snapshot.generation
                }
                durableWaiters.removeAll { waiter in
                    waiter.generation <= snapshot.generation
                }
                writeInProgress = false
                for waiter in failedWaiters {
                    waiter.continuation.resume(throwing: failure)
                }
                return
            }
        }
        writeInProgress = false
    }

    private nonisolated static func write(_ snapshot: WatchManifestPersistenceSnapshot) async throws {
        try await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(
                at: snapshot.supportDirectory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot.archive)
            try data.write(to: snapshot.manifestURL, options: [.atomic])
        }.value
    }
}

private actor WatchEpisodeRuntimeStateWriter {
    private var latestGenerationByHash: [String: UInt64] = [:]

    func persist(
        _ state: WatchEpisodeRuntimeState,
        directoryURL: URL
    ) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let fileURL = Self.fileURL(forEpisodeHash: state.episodeHash, directoryURL: directoryURL)
        let latestGeneration: UInt64
        if let cachedGeneration = latestGenerationByHash[state.episodeHash] {
            latestGeneration = cachedGeneration
        } else {
            latestGeneration = Self.persistedGeneration(at: fileURL)
            latestGenerationByHash[state.episodeHash] = latestGeneration
        }
        if state.generation < latestGeneration {
            return
        }
        try data.write(to: fileURL, options: [.atomic])
        latestGenerationByHash[state.episodeHash] = state.generation
    }

    func removeStates(atOrBefore generation: UInt64, directoryURL: URL) throws {
        guard generation > 0 else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let state = try? decoder.decode(WatchEpisodeRuntimeState.self, from: data),
                  state.generation <= generation else {
                continue
            }
            latestGenerationByHash[state.episodeHash] = max(
                latestGenerationByHash[state.episodeHash, default: 0],
                state.generation
            )
            try fileManager.removeItem(at: fileURL)
        }
    }

    nonisolated private static func persistedGeneration(at fileURL: URL) -> UInt64 {
        guard let data = try? Data(contentsOf: fileURL) else { return 0 }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(WatchEpisodeRuntimeState.self, from: data).generation) ?? 0
    }

    nonisolated static func fileURL(forEpisodeHash episodeHash: String, directoryURL: URL) -> URL {
        let encodedHash = Data(episodeHash.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directoryURL
            .appendingPathComponent(encodedHash.isEmpty ? "empty" : encodedHash)
            .appendingPathExtension("json")
    }
}

@MainActor
final class WatchManifestStore: ObservableObject {
    static let shared = WatchManifestStore()

    private var episodeIndexByHash: [String: Int] = [:]
    private var sortedEpisodesCache: [WatchEpisode] = []
    private var sortedEpisodeRowsCache: [WatchEpisodeRowState] = []
    private var sortedEpisodeIndexByHash: [String: Int] = [:]
    private var episodeStatusCounts: [WatchEpisodeStatus: Int] = [:]
    private var episodeIndexDirty = true
    private var sortedEpisodesDirty = true
    private var episodeStatusCountsDirty = true
    private var episodesMutationGeneration: UInt64 = 0
    let episodeCollection = WatchEpisodeCollectionState()
    private(set) var episodes: [WatchEpisode] {
        get {
            episodeCollection.episodes
        }
        set {
            episodeCollection.replace(with: newValue)
            episodesMutationGeneration &+= 1
        }
    }
    @Published private(set) var accentColorHex = UserDefaults.standard.string(forKey: "InstacastWatchAccentColorHex") ?? "#FF5300"
    @Published private(set) var loadState: WatchManifestLoadState = .loading
    private(set) var episodeMembershipGeneration: UInt64 = 0

    private let persistenceWriter = WatchManifestPersistenceWriter()
    private let runtimeStateWriter = WatchEpisodeRuntimeStateWriter()
    private var persistenceGeneration: UInt64 = 0
    private var runtimeStateGeneration: UInt64 = 0
    private var lastAppliedManifestRevision: Int64 = 0
    private var pendingManifestRevision: Int64 = 0
    private var inMemoryManifestRevision: Int64 = 0
    private var manifestMutationGeneration: UInt64 = 0
    private var lastCommittedArchive = WatchManifestArchive(manifestRevision: 0, episodes: [])
    private var lastCommittedGeneration: UInt64 = 0
    private var manifestLoaded: Bool { loadState == .loaded }
    private var manifestLoadInProgress = false
    private var manifestLoadContinuations: [CheckedContinuation<Void, Never>] = []
    private var storageEvictionBatchMutationInProgress = false
    private var deferredStorageEvictionScheduleRequested = false
    private var deferredStorageEvictionManifestRevision: Int64?
    private var deferredStorageEvictionDurableWaiters: [CheckedContinuation<Void, any Error>] = []

    private init() {}

    var sortedEpisodes: [WatchEpisode] {
        ensureSortedEpisodesCache()
        return sortedEpisodesCache
    }

    var sortedEpisodeRows: [WatchEpisodeRowState] {
        ensureSortedEpisodesCache()
        return sortedEpisodeRowsCache
    }

    var downloadedEpisodeCount: Int {
        ensureEpisodeStatusCounts()
        return episodeStatusCounts[.downloaded, default: 0]
    }

    var hasEvictedEpisodes: Bool {
        ensureEpisodeStatusCounts()
        return episodeStatusCounts[.evicted, default: 0] > 0
    }

    private func ensureEpisodeIndex() {
        guard episodeIndexDirty else { return }
        var indexByHash: [String: Int] = [:]
        for (index, episode) in episodes.enumerated() where indexByHash[episode.episodeHash] == nil {
            indexByHash[episode.episodeHash] = index
        }
        episodeIndexByHash = indexByHash
        episodeIndexDirty = false
    }

    private func ensureSortedEpisodesCache() {
        guard sortedEpisodesDirty else { return }
        sortedEpisodesCache = episodes.sorted { first, second in
            switch (first.playbackOrder, second.playbackOrder) {
            case let (.some(firstOrder), .some(secondOrder)) where firstOrder != secondOrder:
                return firstOrder < secondOrder
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return first.sortDate > second.sortDate
            }
        }
        var sortedIndexByHash: [String: Int] = [:]
        for (index, episode) in sortedEpisodesCache.enumerated()
        where sortedIndexByHash[episode.episodeHash] == nil {
            sortedIndexByHash[episode.episodeHash] = index
        }
        sortedEpisodeIndexByHash = sortedIndexByHash
        sortedEpisodeRowsCache = episodeCollection.rowStates(in: sortedEpisodesCache)
        sortedEpisodesDirty = false
    }

    private func ensureEpisodeStatusCounts() {
        guard episodeStatusCountsDirty else { return }
        var counts: [WatchEpisodeStatus: Int] = [:]
        for episode in episodes {
            counts[episode.status, default: 0] += 1
        }
        episodeStatusCounts = counts
        episodeStatusCountsDirty = false
    }

    private func invalidateEpisodeCollectionCaches(membershipChanged: Bool) {
        episodeIndexDirty = true
        sortedEpisodesDirty = true
        sortedEpisodeRowsCache.removeAll(keepingCapacity: true)
        sortedEpisodeIndexByHash.removeAll(keepingCapacity: true)
        episodeStatusCountsDirty = true
        if membershipChanged {
            episodeMembershipGeneration &+= 1
        }
    }

    private func recordEpisodeMutation(previous: WatchEpisode, updated: WatchEpisode) {
        guard previous.episodeHash == updated.episodeHash else {
            invalidateEpisodeCollectionCaches(membershipChanged: true)
            return
        }

        if Self.episodeSortKeyChanged(previous: previous, updated: updated) {
            sortedEpisodesDirty = true
            sortedEpisodeRowsCache.removeAll(keepingCapacity: true)
            sortedEpisodeIndexByHash.removeAll(keepingCapacity: true)
        } else if !sortedEpisodesDirty {
            if let sortedIndex = sortedEpisodeIndexByHash[updated.episodeHash] {
                sortedEpisodesCache[sortedIndex] = updated
            } else {
                sortedEpisodesDirty = true
                sortedEpisodeRowsCache.removeAll(keepingCapacity: true)
                sortedEpisodeIndexByHash.removeAll(keepingCapacity: true)
            }
        }

        if !episodeStatusCountsDirty, previous.status != updated.status {
            episodeStatusCounts[previous.status] = max(
                0,
                episodeStatusCounts[previous.status, default: 0] - 1
            )
            episodeStatusCounts[updated.status, default: 0] += 1
        }
    }

    private nonisolated static func episodeSortKeyChanged(
        previous: WatchEpisode,
        updated: WatchEpisode
    ) -> Bool {
        previous.playbackOrder != updated.playbackOrder || previous.sortDate != updated.sortDate
    }

    func shouldApplyManifestRevision(_ revision: Int64?) -> Bool {
        guard let revision, revision > 0 else {
            // Accept unversioned messages only until the first versioned phone build is
            // observed. This preserves upgrade compatibility but rejects old queued
            // transferUserInfo payloads forever after the protocol transition.
            return lastAppliedManifestRevision == 0 && pendingManifestRevision == 0
        }
        return revision > max(lastAppliedManifestRevision, pendingManifestRevision)
    }

    func isManifestRevisionCommitted(_ revision: Int64?) -> Bool {
        guard let revision, revision > 0 else {
            return lastAppliedManifestRevision == 0
        }
        return revision <= lastAppliedManifestRevision
    }

    func load() async {
        guard !manifestLoaded else { return }
        if manifestLoadInProgress {
            await withCheckedContinuation { continuation in
                manifestLoadContinuations.append(continuation)
            }
            return
        }

        manifestLoadInProgress = true
        loadState = .loading
        let expectedManifestMutationGeneration = manifestMutationGeneration
        let outcome = await performInitialLoad(
            expectedManifestMutationGeneration: expectedManifestMutationGeneration
        )
        switch outcome {
        case .loaded:
            loadState = .loaded
        case .failed:
            loadState = .failed
        case .superseded:
            break
        }
        manifestLoadInProgress = false
        let continuations = manifestLoadContinuations
        manifestLoadContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private func performInitialLoad(
        expectedManifestMutationGeneration: UInt64
    ) async -> WatchManifestInitialLoadOutcome {
        let url = manifestURL
        let loadResult = await Task.detached(priority: .utility) {
            Self.loadArchive(at: url)
        }.value
        guard expectedManifestMutationGeneration == manifestMutationGeneration else {
            return .superseded
        }

        let loadedArchive: WatchManifestArchive
        var needsPersistence = false
        switch loadResult {
        case .missing:
            loadedArchive = WatchManifestArchive(manifestRevision: 0, episodes: [])
        case let .archive(archive, migratedLegacyArchive):
            loadedArchive = archive
            needsPersistence = migratedLegacyArchive
        case let .failure(message):
            WatchDiagnostics.log("manifest-load-failed", message: message)
            return .failed
        }

        let runtimeStateLoad = await Self.loadRuntimeStates(at: runtimeStateDirectory)
        let runtimeStateReplay = Self.applyRuntimeStates(
            to: loadedArchive.episodes,
            states: runtimeStateLoad.states,
            archiveRuntimeStateGeneration: loadedArchive.runtimeStateGeneration
        )
        runtimeStateGeneration = max(
            loadedArchive.runtimeStateGeneration,
            runtimeStateReplay.maximumGeneration
        )
        if runtimeStateLoad.invalidRecordCount > 0 {
            WatchDiagnostics.log(
                "manifest-runtime-state-load-failed",
                message: "Einzelne Watch-Laufzeitzustände konnten nicht gelesen werden",
                metadata: ["invalidRecordCount": "\(runtimeStateLoad.invalidRecordCount)"]
            )
        }
        if runtimeStateReplay.appliedCount > 0 {
            needsPersistence = true
        }

        let normalization = await Self.normalizeStoredLocalFileURLs(
            in: runtimeStateReplay.episodes,
            affectedHashes: nil
        )
        guard expectedManifestMutationGeneration == manifestMutationGeneration else {
            return .superseded
        }
        episodes = normalization.episodes
        invalidateEpisodeCollectionCaches(membershipChanged: true)
        logNormalizationChanges(normalization.changes, reason: "load")
        lastAppliedManifestRevision = max(0, loadedArchive.manifestRevision)
        pendingManifestRevision = lastAppliedManifestRevision
        inMemoryManifestRevision = lastAppliedManifestRevision
        let replayedArchive = WatchManifestArchive(
            manifestRevision: loadedArchive.manifestRevision,
            runtimeStateGeneration: runtimeStateGeneration,
            episodes: runtimeStateReplay.episodes
        )
        lastCommittedArchive = replayedArchive
        lastCommittedGeneration = 0
        await persistenceWriter.seedCommittedArchive(replayedArchive)

        if normalization.summary.rerooted > 0 || normalization.summary.missing > 0 {
            needsPersistence = true
        }
        let removedDuplicates = removeDuplicateEpisodes(reason: "load")
        if needsPersistence || removedDuplicates > 0 {
            do {
                try await persistEpisodes(episodes)
            } catch {
                WatchDiagnostics.log(
                    "manifest-persist-failed",
                    message: "Watch-Manifest konnte nach dem Laden nicht repariert werden",
                    metadata: ["error": error.localizedDescription]
                )
            }
        } else {
            scheduleRuntimeStateCleanup(atOrBefore: loadedArchive.runtimeStateGeneration)
        }
        WatchDiagnostics.log("manifest-load", message: "Watch-Manifest geladen", metadata: statusCountsMetadata(prefix: "loaded"))
        return .loaded
    }

    private nonisolated static func loadArchive(at manifestURL: URL) -> WatchManifestLoadResult {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: manifestURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let archive = try? decoder.decode(WatchManifestArchive.self, from: data) {
                return .archive(archive, migratedLegacyArchive: false)
            }
            if let legacyEpisodes = try? decoder.decode([WatchEpisode].self, from: data) {
                return .archive(
                    WatchManifestArchive(manifestRevision: 0, episodes: legacyEpisodes),
                    migratedLegacyArchive: true
                )
            }
            return .failure("Gespeichertes Watch-Manifest konnte nicht gelesen werden")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private nonisolated static func loadRuntimeStates(
        at directoryURL: URL
    ) async -> WatchEpisodeRuntimeStateLoadResult {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: directoryURL.path) else {
                return WatchEpisodeRuntimeStateLoadResult(states: [], invalidRecordCount: 0)
            }
            let fileURLs: [URL]
            do {
                fileURLs = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                return WatchEpisodeRuntimeStateLoadResult(states: [], invalidRecordCount: 1)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var states: [WatchEpisodeRuntimeState] = []
            var invalidRecordCount = 0
            for fileURL in fileURLs where fileURL.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: fileURL)
                    states.append(try decoder.decode(WatchEpisodeRuntimeState.self, from: data))
                } catch {
                    invalidRecordCount += 1
                }
            }
            return WatchEpisodeRuntimeStateLoadResult(
                states: states,
                invalidRecordCount: invalidRecordCount
            )
        }.value
    }

    private nonisolated static func applyRuntimeStates(
        to episodes: [WatchEpisode],
        states: [WatchEpisodeRuntimeState],
        archiveRuntimeStateGeneration: UInt64
    ) -> WatchEpisodeRuntimeStateReplay {
        var maximumGeneration = archiveRuntimeStateGeneration
        var newestStateByHash: [String: WatchEpisodeRuntimeState] = [:]
        for state in states {
            maximumGeneration = max(maximumGeneration, state.generation)
            if state.generation > (newestStateByHash[state.episodeHash]?.generation ?? 0) {
                newestStateByHash[state.episodeHash] = state
            }
        }

        var episodeIndexByHash: [String: Int] = [:]
        for (index, episode) in episodes.enumerated() where episodeIndexByHash[episode.episodeHash] == nil {
            episodeIndexByHash[episode.episodeHash] = index
        }
        var replayedEpisodes = episodes
        var appliedCount = 0
        for state in newestStateByHash.values {
            guard state.generation > archiveRuntimeStateGeneration,
                  let index = episodeIndexByHash[state.episodeHash] else {
                continue
            }
            let episode = replayedEpisodes[index]
            guard episode.selectionIdentifier == state.selectionIdentifier,
                  episode.watchAddedDate == state.watchAddedDate,
                  episode.mediaURL == state.mediaURL,
                  episode.status == state.status else {
                continue
            }
            replayedEpisodes[index].lastPlaybackPosition = max(0, state.lastPlaybackPosition)
            replayedEpisodes[index].lastPlaybackDate = state.lastPlaybackDate
            replayedEpisodes[index].downloadedBytes = max(0, state.downloadedBytes)
            replayedEpisodes[index].expectedBytes = max(0, state.expectedBytes)
            appliedCount += 1
        }
        return WatchEpisodeRuntimeStateReplay(
            episodes: replayedEpisodes,
            maximumGeneration: maximumGeneration,
            appliedCount: appliedCount
        )
    }

    private func currentManifestMergePlan(
        entries: [WatchManifestEntry],
        mode: WatchManifestMergeMode,
        manifestRevision: Int64?,
        reservationGeneration: UInt64
    ) async throws -> WatchManifestMergePlan {
        let maximumAttempts = 2
        for _ in 0..<maximumAttempts {
            guard reservationGeneration == manifestMutationGeneration else {
                releaseIncomingManifestRevision(
                    manifestRevision,
                    reservationGeneration: reservationGeneration
                )
                throw WatchManifestMergeError.superseded
            }
            let snapshot = episodes
            let snapshotGeneration = episodesMutationGeneration
            let plan = await Task.detached(priority: .utility) {
                Self.buildManifestMergePlan(
                    existingEpisodes: snapshot,
                    entries: entries,
                    mode: mode
                )
            }.value
            guard reservationGeneration == manifestMutationGeneration else {
                releaseIncomingManifestRevision(
                    manifestRevision,
                    reservationGeneration: reservationGeneration
                )
                throw WatchManifestMergeError.superseded
            }
            if snapshotGeneration == episodesMutationGeneration {
                return plan
            }
        }
        releaseIncomingManifestRevision(
            manifestRevision,
            reservationGeneration: reservationGeneration
        )
        throw WatchManifestMergeError.superseded
    }

    private nonisolated static func buildManifestMergePlan(
        existingEpisodes: [WatchEpisode],
        entries: [WatchManifestEntry],
        mode: WatchManifestMergeMode
    ) -> WatchManifestMergePlan {
        let storedResult = uniqueStoredEpisodes(existingEpisodes)
        let storedEpisodes = storedResult.episodes
        let beforeCounts = statusCountsMetadata(for: storedEpisodes, prefix: "before")
        var existingByHash: [String: WatchEpisode] = [:]
        for episode in storedEpisodes {
            existingByHash[episode.episodeHash] = episode
        }
        let uniqueEntries = uniqueManifestEntries(entries)
        var diagnostics: [WatchManifestMergeDiagnosticCategory: WatchManifestMergeDiagnosticAggregate] = [:]
        let mergedEpisodes: [WatchEpisode]
        let pendingRemovals: [WatchEpisode]

        switch mode {
        case .replace:
            let desiredHashes = Set(uniqueEntries.map(\.episodeHash))
            pendingRemovals = storedEpisodes.compactMap { episode in
                guard !desiredHashes.contains(episode.episodeHash) else { return nil }
                var pendingRemoval = episode
                pendingRemoval.status = .removing
                return pendingRemoval
            }
            mergedEpisodes = uniqueEntries.map { entry in
                let existing = existingByHash[entry.episodeHash]
                let item = WatchEpisode(
                    entry: entry,
                    existing: existing,
                    existingLocalFileWasValidated: true
                )
                recordMergeDecision(
                    entry: entry,
                    existing: existing,
                    result: item,
                    diagnostics: &diagnostics
                )
                return item
            } + pendingRemovals
        case .upsert:
            pendingRemovals = []
            var byHash = existingByHash
            for entry in uniqueEntries {
                let existing = byHash[entry.episodeHash]
                let item = WatchEpisode(
                    entry: entry,
                    existing: existing,
                    existingLocalFileWasValidated: true
                )
                recordMergeDecision(
                    entry: entry,
                    existing: existing,
                    result: item,
                    diagnostics: &diagnostics
                )
                byHash[entry.episodeHash] = item
            }
            mergedEpisodes = Array(byHash.values)
        }

        return WatchManifestMergePlan(
            episodes: mergedEpisodes,
            pendingRemovals: pendingRemovals,
            diagnostics: diagnostics,
            beforeCounts: beforeCounts,
            afterCounts: statusCountsMetadata(for: mergedEpisodes, prefix: "after"),
            uniqueEntryCount: uniqueEntries.count,
            removedStoredDuplicateCount: storedResult.removedCount
        )
    }

    func applyManifest(
        entries: [WatchManifestEntry],
        manifestRevision: Int64? = nil
    ) async throws -> [WatchEpisode] {
        guard reserveIncomingManifestRevision(manifestRevision) else { return [] }
        let reservationGeneration = manifestMutationGeneration
        let normalizationResult = await Self.normalizeStoredLocalFileURLs(
            in: episodes,
            affectedHashes: nil
        )
        guard reservationGeneration == manifestMutationGeneration else {
            releaseIncomingManifestRevision(
                manifestRevision,
                reservationGeneration: reservationGeneration
            )
            throw WatchManifestMergeError.superseded
        }
        let normalization = applyNormalizationResult(
            normalizationResult,
            reason: "manifest.replace-before"
        )
        let plan = try await currentManifestMergePlan(
            entries: entries,
            mode: .replace,
            manifestRevision: manifestRevision,
            reservationGeneration: reservationGeneration
        )
        episodes = plan.episodes
        invalidateEpisodeCollectionCaches(membershipChanged: true)
        logMergeDecisions(plan.diagnostics, reason: "manifest.replace")
        try await persistEpisodes(episodes, manifestRevision: manifestRevision)
        var metadata = plan.beforeCounts
        metadata.merge(plan.afterCounts) { _, new in new }
        metadata.merge(normalization.metadata.mapKeys { "normalization.\($0)" }) { _, new in new }
        metadata["entryCount"] = "\(entries.count)"
        metadata["duplicateEntryCount"] = "\(entries.count - plan.uniqueEntryCount)"
        metadata["removedStoredDuplicateCount"] = "\(plan.removedStoredDuplicateCount)"
        metadata["removedCount"] = "\(plan.pendingRemovals.count)"
        WatchDiagnostics.log("manifest-replace", message: "Watch-Manifest ersetzt", metadata: metadata)
        return plan.pendingRemovals
    }

    func upsert(entries: [WatchManifestEntry], manifestRevision: Int64? = nil) async throws {
        guard reserveIncomingManifestRevision(manifestRevision) else { return }
        let reservationGeneration = manifestMutationGeneration
        let affectedHashes = await Task.detached(priority: .utility) {
            Set(entries.map(\.episodeHash))
        }.value
        let normalizationResult = await Self.normalizeStoredLocalFileURLs(
            in: episodes,
            affectedHashes: affectedHashes
        )
        guard reservationGeneration == manifestMutationGeneration else {
            releaseIncomingManifestRevision(
                manifestRevision,
                reservationGeneration: reservationGeneration
            )
            throw WatchManifestMergeError.superseded
        }
        let normalization = applyNormalizationResult(
            normalizationResult,
            reason: "manifest.upsert-before"
        )
        let plan = try await currentManifestMergePlan(
            entries: entries,
            mode: .upsert,
            manifestRevision: manifestRevision,
            reservationGeneration: reservationGeneration
        )
        episodes = plan.episodes
        invalidateEpisodeCollectionCaches(membershipChanged: true)
        logMergeDecisions(plan.diagnostics, reason: "manifest.upsert")
        try await persistEpisodes(episodes, manifestRevision: manifestRevision)
        var metadata = plan.beforeCounts
        metadata.merge(plan.afterCounts) { _, new in new }
        metadata.merge(normalization.metadata.mapKeys { "normalization.\($0)" }) { _, new in new }
        metadata["entryCount"] = "\(entries.count)"
        metadata["duplicateEntryCount"] = "\(entries.count - plan.uniqueEntryCount)"
        metadata["removedStoredDuplicateCount"] = "\(plan.removedStoredDuplicateCount)"
        WatchDiagnostics.log("manifest-upsert", message: "Watch-Manifest aktualisiert", metadata: metadata)
    }

    func markEpisodesForRemoval(
        hashes: Set<String>,
        manifestRevision: Int64? = nil
    ) async throws -> [WatchEpisode] {
        if manifestRevision != nil, !reserveIncomingManifestRevision(manifestRevision) {
            return []
        }
        var markedEpisodes: [WatchEpisode] = []
        var nextEpisodes = episodes
        var mutations: [(previous: WatchEpisode, updated: WatchEpisode)] = []
        for index in nextEpisodes.indices where hashes.contains(nextEpisodes[index].episodeHash) {
            let previous = nextEpisodes[index]
            nextEpisodes[index].status = .removing
            markedEpisodes.append(nextEpisodes[index])
            if nextEpisodes[index] != previous {
                mutations.append((previous, nextEpisodes[index]))
            }
        }
        guard nextEpisodes != episodes else {
            if manifestRevision != nil {
                try await persistEpisodes(episodes, manifestRevision: manifestRevision)
            }
            return []
        }
        episodes = nextEpisodes
        for mutation in mutations {
            recordEpisodeMutation(previous: mutation.previous, updated: mutation.updated)
        }
        try await persistEpisodes(episodes, manifestRevision: manifestRevision)
        return markedEpisodes
    }

    func removeEpisode(hash: String) async throws -> WatchEpisode? {
        try await removeEpisodes(hashes: Set([hash])).first
    }

    func removeEpisodes(hashes: Set<String>) async throws -> [WatchEpisode] {
        guard !hashes.isEmpty else { return [] }
        let removed = episodes.filter { hashes.contains($0.episodeHash) }
        guard !removed.isEmpty else { return [] }
        episodes.removeAll { hashes.contains($0.episodeHash) }
        invalidateEpisodeCollectionCaches(membershipChanged: true)
        try await persistEpisodes(episodes)
        return removed
    }

    func retainPendingRemoval(_ episode: WatchEpisode) {
        var pendingRemoval = episode
        pendingRemoval.status = .removing
        ensureEpisodeIndex()
        if let index = episodeIndexByHash[episode.episodeHash] {
            let previous = episodes[index]
            episodeCollection.updateStructuralEpisode(at: index, with: pendingRemoval)
            episodesMutationGeneration &+= 1
            recordEpisodeMutation(previous: previous, updated: pendingRemoval)
        } else {
            episodes.append(pendingRemoval)
            invalidateEpisodeCollectionCaches(membershipChanged: true)
        }
        schedulePersist()
    }

    func episode(hash: String) -> WatchEpisode? {
        ensureEpisodeIndex()
        guard let index = episodeIndexByHash[hash] else { return nil }
        return episodes[index]
    }

    func updateEpisode(hash: String, mutate: (inout WatchEpisode) -> Void) {
        ensureEpisodeIndex()
        guard let index = episodeIndexByHash[hash] else { return }
        let previousEpisode = episodes[index]
        var updatedEpisode = previousEpisode
        mutate(&updatedEpisode)
        guard updatedEpisode != previousEpisode else { return }
        if Self.isRuntimeOnlyMutation(previous: previousEpisode, updated: updatedEpisode) {
            episodeCollection.updateRuntimeEpisode(at: index, with: updatedEpisode)
            episodesMutationGeneration &+= 1
            recordEpisodeMutation(previous: previousEpisode, updated: updatedEpisode)
            scheduleRuntimeStatePersist(updatedEpisode)
        } else {
            episodeCollection.updateStructuralEpisode(at: index, with: updatedEpisode)
            episodesMutationGeneration &+= 1
            recordEpisodeMutation(previous: previousEpisode, updated: updatedEpisode)
            schedulePersist()
        }
    }

    func updateEpisodeDurably(hash: String, mutate: (inout WatchEpisode) -> Void) async throws {
        ensureEpisodeIndex()
        guard let index = episodeIndexByHash[hash] else { return }
        let previousEpisode = episodes[index]
        var updatedEpisode = previousEpisode
        mutate(&updatedEpisode)
        guard updatedEpisode != previousEpisode else { return }
        episodeCollection.updateStructuralEpisode(at: index, with: updatedEpisode)
        episodesMutationGeneration &+= 1
        recordEpisodeMutation(previous: previousEpisode, updated: updatedEpisode)
        try await persistEpisodes(episodes)
    }

    func updateEpisodes(
        hashes: Set<String>,
        mutate: (inout WatchEpisode) -> Void
    ) async throws {
        guard !hashes.isEmpty else { return }
        var nextEpisodes = episodes
        var mutations: [(previous: WatchEpisode, updated: WatchEpisode)] = []
        for index in nextEpisodes.indices where hashes.contains(nextEpisodes[index].episodeHash) {
            let previousEpisode = nextEpisodes[index]
            mutate(&nextEpisodes[index])
            if nextEpisodes[index] != previousEpisode {
                mutations.append((previousEpisode, nextEpisodes[index]))
            }
        }
        guard !mutations.isEmpty else { return }
        episodes = nextEpisodes
        for mutation in mutations {
            recordEpisodeMutation(previous: mutation.previous, updated: mutation.updated)
        }
        try await persistEpisodes(episodes)
    }

    func updateEpisodesDurablyInBatches(
        hashes: [String],
        batchSize: Int,
        mutate: (inout WatchEpisode) -> Void
    ) async throws {
        guard !hashes.isEmpty else { return }
        guard !storageEvictionBatchMutationInProgress else {
            throw NSError(
                domain: "WatchManifestStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A storage-eviction manifest transaction is already running."]
            )
        }

        // This is the only reentrant mutation window in the eviction transaction. Each chunk
        // updates the current indexed store (never a stale full-array copy), so position/progress
        // changes delivered at a yield survive. schedulePersist and every durable persistEpisodes
        // caller coalesce below into the one final snapshot instead of writing a partial batch.
        storageEvictionBatchMutationInProgress = true
        deferredStorageEvictionScheduleRequested = false
        deferredStorageEvictionManifestRevision = nil
        let boundedBatchSize = max(1, batchSize)
        var changed = false
        var offset = 0
        while offset < hashes.count {
            let upperBound = min(offset + boundedBatchSize, hashes.count)
            ensureEpisodeIndex()
            var chunkUpdates: [(index: Int, episode: WatchEpisode)] = []
            var chunkMutations: [(previous: WatchEpisode, updated: WatchEpisode)] = []
            for hash in hashes[offset..<upperBound] {
                guard let index = episodeIndexByHash[hash] else { continue }
                let previousEpisode = episodes[index]
                var updatedEpisode = previousEpisode
                mutate(&updatedEpisode)
                guard updatedEpisode != previousEpisode else { continue }
                chunkUpdates.append((index: index, episode: updatedEpisode))
                chunkMutations.append((previous: previousEpisode, updated: updatedEpisode))
            }
            if !chunkUpdates.isEmpty {
                episodeCollection.updateStructuralEpisodes(chunkUpdates)
                episodesMutationGeneration &+= 1
                for mutation in chunkMutations {
                    recordEpisodeMutation(previous: mutation.previous, updated: mutation.updated)
                }
                changed = true
            }
            offset = upperBound
            if offset < hashes.count {
                await Task.yield()
            }
        }

        let deferredScheduleRequested = deferredStorageEvictionScheduleRequested
        let deferredManifestRevision = deferredStorageEvictionManifestRevision
        let deferredDurableWaiters = deferredStorageEvictionDurableWaiters
        deferredStorageEvictionScheduleRequested = false
        deferredStorageEvictionManifestRevision = nil
        deferredStorageEvictionDurableWaiters.removeAll()
        storageEvictionBatchMutationInProgress = false

        // Do not abandon this commit on Task cancellation: audio files were already physically
        // removed. Every suspended durable caller must observe this same success or error exactly
        // once, and the existing persistence writer remains responsible for rollback/coalescing.
        guard changed || deferredScheduleRequested || !deferredDurableWaiters.isEmpty else {
            return
        }
        do {
            try await persistEpisodesNow(episodes, manifestRevision: deferredManifestRevision)
            deferredDurableWaiters.forEach { $0.resume() }
        } catch {
            deferredDurableWaiters.forEach { $0.resume(throwing: error) }
            throw error
        }
    }

    func updateEpisodesEventually(
        hashes: Set<String>,
        mutate: (inout WatchEpisode) -> Void
    ) {
        guard !hashes.isEmpty else { return }
        var nextEpisodes = episodes
        var mutations: [(previous: WatchEpisode, updated: WatchEpisode)] = []
        for index in nextEpisodes.indices where hashes.contains(nextEpisodes[index].episodeHash) {
            let previousEpisode = nextEpisodes[index]
            mutate(&nextEpisodes[index])
            if nextEpisodes[index] != previousEpisode {
                mutations.append((previousEpisode, nextEpisodes[index]))
            }
        }
        guard !mutations.isEmpty else { return }
        episodes = nextEpisodes
        for mutation in mutations {
            recordEpisodeMutation(previous: mutation.previous, updated: mutation.updated)
        }
        schedulePersist()
    }

    func nextPlayableEpisode(after episodeHash: String) -> WatchEpisode? {
        let orderedEpisodes = sortedEpisodes
        guard let index = orderedEpisodes.firstIndex(where: { $0.episodeHash == episodeHash }) else { return nil }
        return orderedEpisodes[(index + 1)...].first { episode in
            episode.status == .downloaded && episode.localFileURL != nil && !episode.consumed
        }
    }

    func updateAccentColorHex(_ value: String?) {
        guard let value, Self.isValidHexColor(value), value != accentColorHex else { return }
        accentColorHex = value
        UserDefaults.standard.set(value, forKey: "InstacastWatchAccentColorHex")
    }

    private nonisolated static func isRuntimeOnlyMutation(
        previous: WatchEpisode,
        updated: WatchEpisode
    ) -> Bool {
        var replayedPrevious = previous
        replayedPrevious.lastPlaybackPosition = updated.lastPlaybackPosition
        replayedPrevious.lastPlaybackDate = updated.lastPlaybackDate
        replayedPrevious.downloadedBytes = updated.downloadedBytes
        replayedPrevious.expectedBytes = updated.expectedBytes
        return replayedPrevious == updated
    }

    private func scheduleRuntimeStatePersist(_ episode: WatchEpisode) {
        runtimeStateGeneration &+= 1
        let state = WatchEpisodeRuntimeState(
            episode: episode,
            generation: runtimeStateGeneration
        )
        let directory = runtimeStateDirectory
        Task { [runtimeStateWriter] in
            do {
                try await runtimeStateWriter.persist(state, directoryURL: directory)
            } catch {
                WatchDiagnostics.log(
                    "manifest-runtime-state-persist-failed",
                    message: "Watch-Laufzeitzustand konnte nicht gespeichert werden",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func scheduleRuntimeStateCleanup(atOrBefore generation: UInt64) {
        guard generation > 0 else { return }
        let directory = runtimeStateDirectory
        Task { [runtimeStateWriter] in
            do {
                try await runtimeStateWriter.removeStates(
                    atOrBefore: generation,
                    directoryURL: directory
                )
            } catch {
                WatchDiagnostics.log(
                    "manifest-runtime-state-cleanup-failed",
                    message: "Alte Watch-Laufzeitzustände konnten nicht entfernt werden",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func schedulePersist() {
        guard !storageEvictionBatchMutationInProgress else {
            deferredStorageEvictionScheduleRequested = true
            return
        }
        schedulePersistNow()
    }

    private func schedulePersistNow() {
        let snapshot = episodes
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let committedRevision = inMemoryManifestRevision
        let archive = WatchManifestArchive(
            manifestRevision: committedRevision,
            runtimeStateGeneration: runtimeStateGeneration,
            episodes: snapshot
        )
        let directory = supportDirectory
        let url = manifestURL
        Task { @MainActor [weak self, persistenceWriter] in
            do {
                let commit = try await persistenceWriter.persist(
                    archive: archive,
                    supportDirectory: directory,
                    manifestURL: url,
                    generation: generation
                )
                self?.recordCommittedArchive(commit)
                self?.scheduleRuntimeStateCleanup(
                    atOrBefore: commit.archive.runtimeStateGeneration
                )
            } catch {
                WatchDiagnostics.log(
                    "manifest-persist-failed",
                    message: "Watch-Manifest konnte nicht gespeichert werden",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func persistEpisodes(_ episodes: [WatchEpisode], manifestRevision: Int64? = nil) async throws {
        guard !storageEvictionBatchMutationInProgress else {
            if let manifestRevision {
                deferredStorageEvictionManifestRevision = max(
                    deferredStorageEvictionManifestRevision ?? 0,
                    manifestRevision
                )
            }
            // apply/upsert/mark/remove/update and player/download durable mutations all route
            // through this method, so none can persist an intermediate eviction chunk.
            try await withCheckedThrowingContinuation { continuation in
                deferredStorageEvictionDurableWaiters.append(continuation)
            }
            return
        }
        try await persistEpisodesNow(episodes, manifestRevision: manifestRevision)
    }

    private func persistEpisodesNow(_ episodes: [WatchEpisode], manifestRevision: Int64? = nil) async throws {
        if let manifestRevision {
            inMemoryManifestRevision = max(lastAppliedManifestRevision, manifestRevision)
        }
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let committedRevision = inMemoryManifestRevision
        let archive = WatchManifestArchive(
            manifestRevision: committedRevision,
            runtimeStateGeneration: runtimeStateGeneration,
            episodes: episodes
        )
        do {
            let commit = try await persistenceWriter.persist(
                archive: archive,
                supportDirectory: supportDirectory,
                manifestURL: manifestURL,
                generation: generation
            )
            recordCommittedArchive(commit)
            scheduleRuntimeStateCleanup(atOrBefore: commit.archive.runtimeStateGeneration)
        } catch {
            do {
                let commit = try await awaitCommittedSnapshot(
                    afterFailureAt: generation,
                    initialError: error
                )
                recordCommittedArchive(commit)
                scheduleRuntimeStateCleanup(atOrBefore: commit.archive.runtimeStateGeneration)
            } catch {
                restoreLastCommittedArchive()
                throw error
            }
        }
    }

    private func awaitCommittedSnapshot(
        afterFailureAt generation: UInt64,
        initialError: any Error
    ) async throws -> WatchManifestPersistenceCommit {
        var failedGeneration = generation
        var latestError = initialError
        while persistenceGeneration > failedGeneration {
            let targetGeneration = persistenceGeneration
            do {
                return try await persistenceWriter.waitForCommit(atLeast: targetGeneration)
            } catch {
                failedGeneration = targetGeneration
                latestError = error
            }
        }
        throw latestError
    }

    private func recordCommittedArchive(_ commit: WatchManifestPersistenceCommit) {
        guard commit.generation >= lastCommittedGeneration else { return }
        lastCommittedArchive = commit.archive
        lastCommittedGeneration = commit.generation
        runtimeStateGeneration = max(runtimeStateGeneration, commit.archive.runtimeStateGeneration)
        loadState = .loaded
        lastAppliedManifestRevision = max(0, commit.archive.manifestRevision)
        inMemoryManifestRevision = max(inMemoryManifestRevision, lastAppliedManifestRevision)
        if pendingManifestRevision <= lastAppliedManifestRevision {
            pendingManifestRevision = lastAppliedManifestRevision
        }
    }

    private func restoreLastCommittedArchive() {
        episodes = lastCommittedArchive.episodes
        invalidateEpisodeCollectionCaches(membershipChanged: true)
        runtimeStateGeneration = max(
            runtimeStateGeneration,
            lastCommittedArchive.runtimeStateGeneration
        )
        lastAppliedManifestRevision = max(0, lastCommittedArchive.manifestRevision)
        pendingManifestRevision = lastAppliedManifestRevision
        inMemoryManifestRevision = lastAppliedManifestRevision
    }

    private func reserveIncomingManifestRevision(_ revision: Int64?) -> Bool {
        guard let revision, revision > 0 else {
            guard lastAppliedManifestRevision == 0 && pendingManifestRevision == 0 else {
                return false
            }
            manifestMutationGeneration &+= 1
            return true
        }
        guard revision > max(lastAppliedManifestRevision, pendingManifestRevision) else {
            return false
        }
        pendingManifestRevision = revision
        manifestMutationGeneration &+= 1
        return true
    }

    private func releaseIncomingManifestRevision(
        _ revision: Int64?,
        reservationGeneration: UInt64
    ) {
        guard reservationGeneration == manifestMutationGeneration else { return }
        if let revision, revision > 0, pendingManifestRevision != revision {
            return
        }
        pendingManifestRevision = lastAppliedManifestRevision
        manifestMutationGeneration &+= 1
    }

    private nonisolated static func uniqueManifestEntries(_ entries: [WatchManifestEntry]) -> [WatchManifestEntry] {
        var uniqueEntries: [WatchManifestEntry] = []
        var indexByHash: [String: Int] = [:]
        for entry in entries where !entry.episodeHash.isEmpty {
            if let index = indexByHash[entry.episodeHash] {
                uniqueEntries[index] = entry
            } else {
                indexByHash[entry.episodeHash] = uniqueEntries.count
                uniqueEntries.append(entry)
            }
        }
        return uniqueEntries
    }

    private nonisolated static func uniqueStoredEpisodes(
        _ episodes: [WatchEpisode]
    ) -> (episodes: [WatchEpisode], removedCount: Int) {
        var uniqueEpisodes: [WatchEpisode] = []
        var indexByHash: [String: Int] = [:]
        var removedCount = 0

        for episode in episodes {
            guard !episode.episodeHash.isEmpty else {
                removedCount += 1
                continue
            }
            if let index = indexByHash[episode.episodeHash] {
                removedCount += 1
                let existing = uniqueEpisodes[index]
                let existingHasLocalFile = hasReusableLocalFile(existing)
                let candidateHasLocalFile = hasReusableLocalFile(episode)
                if candidateHasLocalFile || !existingHasLocalFile {
                    uniqueEpisodes[index] = episode
                }
            } else {
                indexByHash[episode.episodeHash] = uniqueEpisodes.count
                uniqueEpisodes.append(episode)
            }
        }
        return (uniqueEpisodes, removedCount)
    }

    @discardableResult
    private func removeDuplicateEpisodes(reason: String) -> Int {
        let result = Self.uniqueStoredEpisodes(episodes)
        guard result.removedCount > 0 else { return 0 }
        episodes = result.episodes
        invalidateEpisodeCollectionCaches(membershipChanged: true)
        WatchDiagnostics.log(
            "manifest-duplicates-removed",
            message: "Doppelte Watch-Manifest-Eintraege entfernt",
            metadata: ["reason": reason, "removedCount": "\(result.removedCount)"]
        )
        return result.removedCount
    }

    private nonisolated static func hasReusableLocalFile(_ episode: WatchEpisode) -> Bool {
        guard episode.localFileURL != nil else { return false }
        return episode.status == .downloaded || episode.status == .removing
    }

    private nonisolated static func normalizeStoredLocalFileURLs(
        in episodes: [WatchEpisode],
        affectedHashes: Set<String>?
    ) async -> WatchManifestNormalizationResult {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let downloadsDirectory = documentsDirectory.appendingPathComponent("Episodes", isDirectory: true)
            try? fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

            var summary = WatchManifestNormalizationSummary()
            var changes: [WatchManifestNormalizationChange] = []
            var normalizedEpisodes = episodes
            for index in normalizedEpisodes.indices {
                let originalEpisode = normalizedEpisodes[index]
                guard affectedHashes?.contains(originalEpisode.episodeHash) ?? true,
                      let storedURL = originalEpisode.localFileURL else {
                    continue
                }
                summary.checked += 1

                var fileNames: [String] = []
                let storedFileName = storedURL.lastPathComponent
                if !storedFileName.isEmpty {
                    fileNames.append(storedFileName)
                }
                let mediaExtension = originalEpisode.mediaURL.pathExtension
                let computedFileName = mediaExtension.isEmpty
                    ? originalEpisode.episodeHash
                    : "\(originalEpisode.episodeHash).\(mediaExtension)"
                if !computedFileName.isEmpty, !fileNames.contains(computedFileName) {
                    fileNames.append(computedFileName)
                }

                var resolvedURL: URL?
                for fileName in fileNames {
                    let candidateURL = downloadsDirectory.appendingPathComponent(fileName)
                    if fileManager.fileExists(atPath: candidateURL.path) {
                        resolvedURL = candidateURL
                        break
                    }
                }
                if resolvedURL == nil, fileManager.fileExists(atPath: storedURL.path) {
                    resolvedURL = storedURL
                }

                if let resolvedURL {
                    if resolvedURL != storedURL {
                        normalizedEpisodes[index].localFileURL = resolvedURL
                        changes.append(WatchManifestNormalizationChange(
                            originalEpisode: originalEpisode,
                            resolvedURL: resolvedURL
                        ))
                        summary.rerooted += 1
                    } else {
                        summary.unchanged += 1
                    }
                } else {
                    clearLocalFileState(for: &normalizedEpisodes[index])
                    changes.append(WatchManifestNormalizationChange(
                        originalEpisode: originalEpisode,
                        resolvedURL: nil
                    ))
                    summary.missing += 1
                }
            }
            return WatchManifestNormalizationResult(
                episodes: normalizedEpisodes,
                changes: changes,
                summary: summary
            )
        }.value
    }

    @discardableResult
    private func applyNormalizationResult(
        _ result: WatchManifestNormalizationResult,
        reason: String
    ) -> WatchManifestNormalizationSummary {
        guard !result.changes.isEmpty else { return result.summary }
        var nextEpisodes = episodes
        var appliedChanges: [WatchManifestNormalizationChange] = []
        var mutations: [(previous: WatchEpisode, updated: WatchEpisode)] = []
        var indicesByIdentity: [WatchManifestNormalizationIdentity: [Int]] = [:]
        for index in nextEpisodes.indices {
            let identity = WatchManifestNormalizationIdentity(episode: nextEpisodes[index])
            indicesByIdentity[identity, default: []].append(index)
        }
        for change in result.changes {
            let identity = WatchManifestNormalizationIdentity(episode: change.originalEpisode)
            guard let matchingIndices = indicesByIdentity.removeValue(forKey: identity) else {
                continue
            }
            for index in matchingIndices {
                let previousEpisode = nextEpisodes[index]
                if let resolvedURL = change.resolvedURL {
                    nextEpisodes[index].localFileURL = resolvedURL
                } else {
                    Self.clearLocalFileState(for: &nextEpisodes[index])
                }
                if nextEpisodes[index] != previousEpisode {
                    mutations.append((previousEpisode, nextEpisodes[index]))
                }
                appliedChanges.append(change)
            }
        }
        if !mutations.isEmpty {
            episodes = nextEpisodes
            for mutation in mutations {
                recordEpisodeMutation(previous: mutation.previous, updated: mutation.updated)
            }
        }
        logNormalizationChanges(appliedChanges, reason: reason)
        return result.summary
    }

    private func logNormalizationChanges(
        _ changes: [WatchManifestNormalizationChange],
        reason: String
    ) {
        var rerootedCount = 0
        var missingCount = 0
        var rerootedSample: WatchManifestNormalizationChange?
        var missingSample: WatchManifestNormalizationChange?
        for change in changes {
            guard change.originalEpisode.localFileURL != nil else { continue }
            if change.resolvedURL != nil {
                rerootedCount += 1
                rerootedSample = rerootedSample ?? change
            } else {
                missingCount += 1
                missingSample = missingSample ?? change
            }
        }

        if let change = rerootedSample,
           let storedURL = change.originalEpisode.localFileURL,
           let resolvedURL = change.resolvedURL {
            var metadata = WatchDiagnostics.metadata(for: change.originalEpisode, prefix: "sample.")
            metadata["reason"] = reason
            metadata["changeCount"] = "\(rerootedCount)"
            metadata["storedPathHash"] = WatchDiagnostics.stableHash(storedURL.path)
            metadata["resolvedPathHash"] = WatchDiagnostics.stableHash(resolvedURL.path)
            metadata["resolvedFileName"] = resolvedURL.lastPathComponent
            metadata["pathRerooted"] = "true"
            WatchDiagnostics.log(
                "watch-local-file-rerooted",
                message: "Watch-Dateipfade auf aktuellen Container normalisiert",
                metadata: metadata
            )
        }

        if let change = missingSample,
           let storedURL = change.originalEpisode.localFileURL {
            var metadata = WatchDiagnostics.metadata(for: change.originalEpisode, prefix: "sample.")
            metadata["reason"] = reason
            metadata["changeCount"] = "\(missingCount)"
            metadata["storedPathHash"] = WatchDiagnostics.stableHash(storedURL.path)
            metadata["localFileMissing"] = "true"
            WatchDiagnostics.log(
                "watch-local-file-missing",
                message: "Watch-Dateien fehlen im alten und aktuellen Container",
                metadata: metadata
            )
        }
    }

    private nonisolated static func clearLocalFileState(for episode: inout WatchEpisode) {
        let pendingRemoval = episode.status == .removing
        episode.status = pendingRemoval ? .removing : .queued
        episode.localFileURL = nil
        episode.actualFileSize = 0
        episode.actualDuration = 0
        episode.downloadedBytes = 0
        episode.chapters = []
        episode.chapterArtworkBaseURL = nil
    }

    private nonisolated static func recordMergeDecision(
        entry: WatchManifestEntry,
        existing: WatchEpisode?,
        result: WatchEpisode,
        diagnostics: inout [WatchManifestMergeDiagnosticCategory: WatchManifestMergeDiagnosticAggregate]
    ) {
        guard let existing else { return }
        let wasDownloaded = existing.status == .downloaded && existing.localFileURL != nil
        let keptDownloaded = wasDownloaded && result.status == .downloaded && result.localFileURL != nil
        let resetDownloaded = wasDownloaded && !keptDownloaded
        let mediaURLChanged = existing.mediaURL != entry.mediaURL
        guard resetDownloaded || mediaURLChanged || existing.localFileURL != result.localFileURL else { return }

        let category: WatchManifestMergeDiagnosticCategory
        if resetDownloaded {
            category = .downloadReset
        } else if mediaURLChanged {
            category = .mediaURLChanged
        } else {
            category = .localFileStateChanged
        }
        if var aggregate = diagnostics[category] {
            aggregate.count += 1
            diagnostics[category] = aggregate
            return
        }
        diagnostics[category] = WatchManifestMergeDiagnosticAggregate(
            count: 1,
            sample: WatchManifestMergeDiagnosticSample(
                result: result,
                wasDownloaded: wasDownloaded,
                keptDownloaded: keptDownloaded,
                resetDownloaded: resetDownloaded,
                mediaURLChanged: mediaURLChanged,
                entryExpectedFileSize: entry.expectedFileSize,
                existingActualFileSize: existing.actualFileSize
            )
        )
    }

    private func logMergeDecisions(
        _ diagnostics: [WatchManifestMergeDiagnosticCategory: WatchManifestMergeDiagnosticAggregate],
        reason: String
    ) {
        for category in WatchManifestMergeDiagnosticCategory.allCases {
            guard let aggregate = diagnostics[category] else { continue }
            let sample = aggregate.sample
            var metadata = WatchDiagnostics.metadata(for: sample.result, prefix: "sample.")
            metadata["category"] = category.rawValue
            metadata["changeCount"] = "\(aggregate.count)"
            metadata["reason"] = reason
            metadata["sample.wasDownloaded"] = sample.wasDownloaded ? "true" : "false"
            metadata["sample.keptDownloaded"] = sample.keptDownloaded ? "true" : "false"
            metadata["sample.resetToQueued"] = sample.resetDownloaded ? "true" : "false"
            metadata["sample.mediaURLChanged"] = sample.mediaURLChanged ? "true" : "false"
            metadata["sample.entryExpectedFileSize"] = "\(sample.entryExpectedFileSize)"
            metadata["sample.existingActualFileSize"] = "\(sample.existingActualFileSize)"
            let message: String
            switch category {
            case .downloadReset:
                message = "Watch-Downloadzustände zurückgesetzt"
            case .mediaURLChanged:
                message = "Watch-Medien-URLs geändert"
            case .localFileStateChanged:
                message = "Lokale Watch-Dateizustände geändert"
            }
            WatchDiagnostics.log(
                "manifest-merge-episode",
                message: message,
                metadata: metadata
            )
        }
    }

    private nonisolated static func statusCountsMetadata(
        for episodes: [WatchEpisode],
        prefix: String
    ) -> [String: String] {
        var counts: [WatchEpisodeStatus: Int] = [:]
        for episode in episodes {
            counts[episode.status, default: 0] += 1
        }
        return [
            "\(prefix).episodeCount": "\(episodes.count)",
            "\(prefix).queued": "\(counts[.queued, default: 0])",
            "\(prefix).downloading": "\(counts[.downloading, default: 0])",
            "\(prefix).downloaded": "\(counts[.downloaded, default: 0])",
            "\(prefix).failed": "\(counts[.failed, default: 0])",
            "\(prefix).evicted": "\(counts[.evicted, default: 0])",
            "\(prefix).removing": "\(counts[.removing, default: 0])",
        ]
    }

    private func statusCountsMetadata(prefix: String) -> [String: String] {
        Self.statusCountsMetadata(for: episodes, prefix: prefix)
    }

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WatchManifest", isDirectory: true)
    }

    private var manifestURL: URL {
        supportDirectory.appendingPathComponent("manifest.json")
    }

    private var runtimeStateDirectory: URL {
        supportDirectory.appendingPathComponent("RuntimeState", isDirectory: true)
    }

    private static func isValidHexColor(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6 else { return false }
        return hex.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789ABCDEFabcdef").contains($0) }
    }
}

private extension Dictionary where Key == String, Value == String {
    func mapKeys(_ transform: (String) -> String) -> [String: String] {
        var mapped: [String: String] = [:]
        for (key, value) in self {
            mapped[transform(key)] = value
        }
        return mapped
    }
}
