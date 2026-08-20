//
//  TranscriptionQueue.swift
//  Instacast
//
//  Manages the queue of episodes to be transcribed.
//  Sequential processing (one at a time). Persists across app restarts.
//  Automatic resume on app launch. Background processing via BGTasks.
//

import Foundation
import UIKit
import BackgroundTasks
import AVFoundation

let ICTranscriptionInternalStatusDetailNotification = Notification.Name("ICTranscriptionInternalStatusDetailNotification")

private final class ICMetadataParserSendableBox: @unchecked Sendable {
    let parser: ICMetadataParser

    init(parser: ICMetadataParser) {
        self.parser = parser
    }
}

// MARK: - Log Entry

/// One line in the per-episode transcription log. Entries are appended from queue and
/// engine code, persisted to disk, and rendered in TranscriptionLogViewController.
@objc class ICTranscriptionLogEntry: NSObject, @unchecked Sendable {
    @objc let timestamp: Date
    @objc let phase: String        // "queued", "download", "music", "model", "transcribe", "chapters", "done", "error"
    @objc let message: String
    @objc let detailText: String?  // free-form extras: "632 MB", "12 cues", "25.3 s"

    @objc init(timestamp: Date, phase: String, message: String, detailText: String?) {
        self.timestamp = timestamp
        self.phase = phase
        self.message = message
        self.detailText = detailText
    }
}

/// Persistent per-episode log of everything the transcription pipeline did. Flushed to
/// `{hash}_log.json` in the transcript cache directory. Accessible via TranscriptionLogger.shared.
@MainActor
@objc class TranscriptionLogger: NSObject {
    private static let _shared = TranscriptionLogger()
    @objc static var shared: TranscriptionLogger { _shared }

    private var cache: [String: [ICTranscriptionLogEntry]] = [:]

    private struct StoredEntry: Codable {
        let timestamp: Date
        let phase: String
        let message: String
        let detailText: String?
    }

    private func fileURL(for episodeHash: String) -> URL {
        return TranscriptionEngine.shared.transcriptCacheDirectory()
            .appendingPathComponent("\(episodeHash)_log.json")
    }

    @objc func append(episodeHash: String, phase: String, message: String, detailText: String? = nil) {
        let entry = ICTranscriptionLogEntry(timestamp: Date(), phase: phase, message: message, detailText: detailText)
        var entries = load(episodeHash: episodeHash)
        entries.append(entry)
        cache[episodeHash] = entries
        persist(episodeHash: episodeHash)
        NSLog("[TranscriptionLog][%@] %@: %@%@", episodeHash, phase, message, detailText.map { " (\($0))" } ?? "")
        var metadata: [String: String] = [
            "episodeHash": episodeHash,
            "phase": phase,
        ]
        if let detailText, !detailText.isEmpty {
            metadata["detailText"] = detailText
        }
        ICDiagnosticLogger.shared.logEvent("transcription-log", message: message, metadata: metadata as NSDictionary)
    }

    @objc func entries(episodeHash: String) -> [ICTranscriptionLogEntry] {
        return load(episodeHash: episodeHash)
    }

    @objc func clearLog(episodeHash: String) {
        cache.removeValue(forKey: episodeHash)
        try? FileManager.default.removeItem(at: fileURL(for: episodeHash))
        ICDiagnosticLogger.shared.logEvent("transcription-log", message: "Per-Episode-Log entfernt", metadata: [
            "episodeHash": episodeHash,
            "logPath": fileURL(for: episodeHash).path,
        ] as NSDictionary)
    }

    /// Ensure the log for a newly queued episode starts from scratch.
    @objc func resetLog(episodeHash: String) {
        cache[episodeHash] = []
        try? FileManager.default.removeItem(at: fileURL(for: episodeHash))
        ICDiagnosticLogger.shared.logEvent("transcription-log", message: "Per-Episode-Log zurückgesetzt", metadata: [
            "episodeHash": episodeHash,
            "logPath": fileURL(for: episodeHash).path,
        ] as NSDictionary)
    }

    private func load(episodeHash: String) -> [ICTranscriptionLogEntry] {
        if let cached = cache[episodeHash] { return cached }
        guard let data = try? Data(contentsOf: fileURL(for: episodeHash)),
              let stored = try? JSONDecoder().decode([StoredEntry].self, from: data) else {
            return []
        }
        let entries = stored.map { ICTranscriptionLogEntry(timestamp: $0.timestamp, phase: $0.phase, message: $0.message, detailText: $0.detailText) }
        cache[episodeHash] = entries
        return entries
    }

    private func persist(episodeHash: String) {
        guard let entries = cache[episodeHash] else { return }
        let stored = entries.map { StoredEntry(timestamp: $0.timestamp, phase: $0.phase, message: $0.message, detailText: $0.detailText) }
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: fileURL(for: episodeHash), options: .atomic)
        }
    }
}

// MARK: - Queue Item

@objc class ICTranscriptionQueueItem: NSObject, @unchecked Sendable {
    @objc let episodeHash: String
    @objc let episodeTitle: String
    @objc let feedTitle: String
    @objc var audioURL: URL?
    @objc let language: String?
    @objc var status: ICTranscriptionStatus
    @objc var progress: Float
    @objc var error: String?
    @objc var statusDetail: String?
    @objc var statusStartedAt: Date?
    @objc var progressBaseline: Float = 0
    @objc var progressBaselineStartedAt: Date?
    @objc var completedAt: Date?
    @objc var chapterOnly = false
    @objc var automaticallyScheduled = false
    @objc var shouldGenerateAnalysis = true
    @objc var retryAttempt = 0
    @objc var remoteAnalysisReplacementAttempts = 0
    var lastCountedRemoteAnalysisJobKey: String?
    var lastCountedRemoteAnalysisResponseID: String?
    @objc var nextRetryAt: Date?
    @objc var requiresExplicitRetryAfterCrash = false
    @objc var usesServerTranscription = false

    @objc init(episodeHash: String, episodeTitle: String, feedTitle: String,
               audioURL: URL?, language: String?) {
        self.episodeHash = episodeHash
        self.episodeTitle = episodeTitle
        self.feedTitle = feedTitle
        self.audioURL = audioURL
        self.language = language
        self.status = .queued
        self.progress = 0
        self.error = nil
        self.statusDetail = nil
        self.statusStartedAt = nil
        self.completedAt = nil
    }
}

// MARK: - Persisted Queue

private struct PersistedQueue: Codable {
    var items: [PersistedItem]
    var pendingCacheDeletionHashes: [String]?

    struct PersistedItem: Codable {
        let episodeHash: String
        let episodeTitle: String
        let feedTitle: String
        let language: String?
        let statusRawValue: Int?
        let completedAt: Date?
        let chapterOnly: Bool?
        let error: String?
        let automaticallyScheduled: Bool
        let shouldGenerateAnalysis: Bool
        let retryAttempt: Int?
        let remoteAnalysisReplacementAttempts: Int?
        let lastCountedRemoteAnalysisJobKey: String?
        let lastCountedRemoteAnalysisResponseID: String?
        let nextRetryAt: Date?
        let requiresExplicitRetryAfterCrash: Bool

        private enum CodingKeys: String, CodingKey {
            case episodeHash
            case episodeTitle
            case feedTitle
            case language
            case statusRawValue
            case completedAt
            case chapterOnly
            case error
            case automaticallyScheduled
            case shouldGenerateAnalysis
            case retryAttempt
            case remoteAnalysisReplacementAttempts
            case lastCountedRemoteAnalysisJobKey
            case lastCountedRemoteAnalysisResponseID
            case nextRetryAt
            case requiresExplicitRetryAfterCrash
        }

        init(episodeHash: String,
             episodeTitle: String,
             feedTitle: String,
             language: String?,
             statusRawValue: Int?,
             completedAt: Date?,
             chapterOnly: Bool?,
             error: String?,
             automaticallyScheduled: Bool,
             shouldGenerateAnalysis: Bool,
             retryAttempt: Int?,
             remoteAnalysisReplacementAttempts: Int?,
             lastCountedRemoteAnalysisJobKey: String?,
             lastCountedRemoteAnalysisResponseID: String?,
             nextRetryAt: Date?,
             requiresExplicitRetryAfterCrash: Bool) {
            self.episodeHash = episodeHash
            self.episodeTitle = episodeTitle
            self.feedTitle = feedTitle
            self.language = language
            self.statusRawValue = statusRawValue
            self.completedAt = completedAt
            self.chapterOnly = chapterOnly
            self.error = error
            self.automaticallyScheduled = automaticallyScheduled
            self.shouldGenerateAnalysis = shouldGenerateAnalysis
            self.retryAttempt = retryAttempt
            self.remoteAnalysisReplacementAttempts = remoteAnalysisReplacementAttempts
            self.lastCountedRemoteAnalysisJobKey = lastCountedRemoteAnalysisJobKey
            self.lastCountedRemoteAnalysisResponseID = lastCountedRemoteAnalysisResponseID
            self.nextRetryAt = nextRetryAt
            self.requiresExplicitRetryAfterCrash = requiresExplicitRetryAfterCrash
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            episodeHash = try values.decode(String.self, forKey: .episodeHash)
            episodeTitle = try values.decode(String.self, forKey: .episodeTitle)
            feedTitle = try values.decode(String.self, forKey: .feedTitle)
            language = try values.decodeIfPresent(String.self, forKey: .language)
            statusRawValue = try values.decodeIfPresent(Int.self, forKey: .statusRawValue)
            completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
            chapterOnly = try values.decodeIfPresent(Bool.self, forKey: .chapterOnly)
            error = try values.decodeIfPresent(String.self, forKey: .error)
            automaticallyScheduled = try values.decodeIfPresent(Bool.self, forKey: .automaticallyScheduled) ?? false
            shouldGenerateAnalysis = try values.decodeIfPresent(Bool.self, forKey: .shouldGenerateAnalysis) ?? true
            retryAttempt = try values.decodeIfPresent(Int.self, forKey: .retryAttempt)
            remoteAnalysisReplacementAttempts = try values.decodeIfPresent(Int.self, forKey: .remoteAnalysisReplacementAttempts)
            lastCountedRemoteAnalysisJobKey = try values.decodeIfPresent(String.self, forKey: .lastCountedRemoteAnalysisJobKey)
            lastCountedRemoteAnalysisResponseID = try values.decodeIfPresent(String.self, forKey: .lastCountedRemoteAnalysisResponseID)
            nextRetryAt = try values.decodeIfPresent(Date.self, forKey: .nextRetryAt)
            requiresExplicitRetryAfterCrash = try values.decodeIfPresent(Bool.self, forKey: .requiresExplicitRetryAfterCrash) ?? false
        }
    }
}

private struct PersistedAutomaticDiscoveryOutbox: Codable {
    let episodeHashes: [String]
}

private let ICPersistedTranscriptionQueueWriteQueue = DispatchQueue(
    label: "com.vemedio.instacast.transcription-queue-persistence",
    qos: .utility
)

private var ICPersistedAutomaticDiscoveryOutboxURL: URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("TranscriptionDiscoveryOutbox.json")
}

private func ICLoadPersistedAutomaticDiscoveryHashes() throws -> Set<String> {
    let url = ICPersistedAutomaticDiscoveryOutboxURL
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    let persisted = try JSONDecoder().decode(PersistedAutomaticDiscoveryOutbox.self, from: data)
    return Set(persisted.episodeHashes.filter { !$0.isEmpty })
}

private func ICCommitPersistedAutomaticDiscoveryOutbox(
    adding addedHashes: Set<String> = [],
    removing removedHashes: Set<String> = []
) throws {
    var hashes = try ICLoadPersistedAutomaticDiscoveryHashes()
    hashes.formUnion(addedHashes)
    hashes.subtract(removedHashes)
    let persisted = PersistedAutomaticDiscoveryOutbox(episodeHashes: hashes.sorted())
    let data = try JSONEncoder().encode(persisted)
    let url = ICPersistedAutomaticDiscoveryOutboxURL
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: url, options: .atomic)
}

private func ICPersistAutomaticDiscoveryHashesBeforeHandoff(_ episodeHashes: Set<String>) -> NSError? {
    var persistenceError: NSError?
    // This tiny delivery record is the one intentional synchronous write: returning
    // before its atomic replacement completes would reopen the Core Data/queue kill window.
    ICPersistedTranscriptionQueueWriteQueue.sync {
        do {
            try ICCommitPersistedAutomaticDiscoveryOutbox(adding: episodeHashes)
        } catch {
            persistenceError = error as NSError
            NSLog("[TranscriptionQueue] Discovery outbox persistence failed: %@", (error as NSError).localizedDescription)
        }
    }
    return persistenceError
}

private func ICUpdatePersistedAutomaticDiscoveryOutbox(
    adding addedHashes: Set<String> = [],
    removing removedHashes: Set<String> = [],
    completion: (@Sendable (NSError?) -> Void)? = nil
) {
    ICPersistedTranscriptionQueueWriteQueue.async {
        do {
            try ICCommitPersistedAutomaticDiscoveryOutbox(
                adding: addedHashes,
                removing: removedHashes
            )
            completion?(nil)
        } catch {
            NSLog("[TranscriptionQueue] Discovery outbox persistence failed: %@", (error as NSError).localizedDescription)
            completion?(error as NSError)
        }
    }
}

private func ICWritePersistedTranscriptionQueueData(
    _ data: Data,
    to url: URL,
    completion: (@Sendable (NSError?) -> Void)? = nil
) {
    ICPersistedTranscriptionQueueWriteQueue.async {
        do {
            try data.write(to: url, options: .atomic)
            completion?(nil)
        } catch {
            NSLog("[TranscriptionQueue] Queue persistence failed: %@", (error as NSError).localizedDescription)
            completion?(error as NSError)
        }
    }
}

/// Lets synchronous pre-delete observers register asynchronous persistence work.
/// CacheManager waits on its utility deletion queue, never on the main thread.
@objc(ICCacheDeletionPreparation)
final class ICCacheDeletionPreparation: NSObject, @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var firstError: NSError?

    @objc(beginPreparation)
    func beginPreparation() {
        group.enter()
    }

    @objc(finishPreparationWithError:)
    func finishPreparation(withError error: NSError?) {
        lock.lock()
        if firstError == nil {
            firstError = error
        }
        lock.unlock()
        group.leave()
    }

    @objc(waitForPreparation)
    func waitForPreparation() -> NSError? {
        group.wait()
        lock.lock()
        let error = firstError
        lock.unlock()
        return error
    }
}

// MARK: - TranscriptionQueue

@MainActor
@objc class TranscriptionQueue: NSObject {

    private static let _shared = TranscriptionQueue()
    @objc static var shared: TranscriptionQueue { _shared }
    private static let backgroundTaskRequestedKey = "TranscriptionBackgroundTaskRequested"
    private static let continuedBackgroundActiveKey = "TranscriptionBackgroundContinuedActive"
    private static let backgroundExecutionPathKey = "TranscriptionBackgroundExecutionPath"
    private static let completedItemRetentionInterval: TimeInterval = 30 * 60
    private static let automaticProcessingTaskIdentifier = "com.iteconomy.instacastplus.transcription.processing"
    private static let automaticRetryBaseDelay: TimeInterval = 30
    private static let automaticRetryMaximumDelay: TimeInterval = 6 * 60 * 60
    private static let maximumAutomaticRemoteAnalysisReplacements = 2
    private nonisolated static let maximumPodcastTranscriptBytes = 16 * 1024 * 1024

    @objc private(set) var items: [ICTranscriptionQueueItem] = []
    @objc var displayItems: [ICTranscriptionQueueItem] {
        items + ServerTranscriptionManager.shared.items
    }
    @objc private(set) var isProcessing = false

    private var engine: TranscriptionEngine { TranscriptionEngine.shared }
    private var analyzer: AudioAnalyzer { AudioAnalyzer.shared }
    private var chapterGen: ChapterGenerator { ChapterGenerator.shared }

    private var currentTask: Task<Void, Never>?
    private var currentProcessingRunID: UUID?
    private var chapterTask: Task<Void, Never>?  // Tracked separately so cancelAll/dequeue can stop it
    private var speechModelPreparationTask: Task<Void, Never>?
    private var speechModelPreparationRunID: UUID?
    private var computeProfileTransitionTask: Task<Void, Never>?
    private var computeProfileTransitionID: UUID?
    private var retryWakeTask: Task<Void, Never>?
    /// Process-local proof that iOS has delivered a BGProcessing or
    /// BGContinuedProcessing task. A submitted request is deliberately not a grant.
    private var grantedBackgroundExecutionPath: String?
    /// Compute path currently applied to WhisperKit. A continued-task grant can
    /// arrive while the scene is still active; in that case this remains nil so
    /// foreground GPU inference continues without interruption.
    private var appliedWhisperKitExecutionPath: String?
    private var pendingDownloadHashes: Set<String> = [] // Tracks episodes being auto-downloaded
    private var pendingCacheDeletionHashes: Set<String> = []
    private var cacheClearInProgress = false
    private var backgroundContinuationTask: UIBackgroundTaskIdentifier = .invalid
    private var backgroundPausedEpisodeHashes: Set<String> = []
    private var completedPruneScheduled = false
    private var pendingQueuePersistenceCount = 0
    private var lastQueuePersistenceError: NSError?

    /// A background task may only release its execution grant after the last
    /// queue snapshot has reached the atomic file-write completion callback.
    @objc var hasPendingQueuePersistence: Bool {
        pendingQueuePersistenceCount > 0
    }

    /// The most recent atomic queue snapshot outcome. A later successful snapshot
    /// clears an earlier error because it durably contains the current queue state.
    @objc var queuePersistenceError: NSError? {
        lastQueuePersistenceError
    }

    @objc func retryQueuePersistenceAfterFailure() {
        guard lastQueuePersistenceError != nil,
              pendingQueuePersistenceCount == 0 else { return }
        persistQueue()
    }

    private func beginProcessingRun() -> UUID {
        let runID = UUID()
        currentProcessingRunID = runID
        return runID
    }

    private func processingRunIsCurrent(_ runID: UUID) -> Bool {
        currentProcessingRunID == runID
    }

    private func clearProcessingRun(_ runID: UUID) {
        if currentProcessingRunID == runID {
            currentProcessingRunID = nil
        }
    }

    private func invalidateProcessingRun() {
        currentProcessingRunID = nil
    }

    // Episode-scoped unexpected-termination marker. Automatic jobs and durable
    // remote chapter jobs resume from persisted state; only unsafe manual work is
    // quarantined so one interrupted episode never blocks the rest of the queue.
    private static let crashGuardKey = "TranscriptionQueue_ModelLoadingInProgress"
    private static let crashGuardEpisodeHashKey = "TranscriptionQueue_GuardedEpisodeHash"
    private static let crashGuardProtectedStatuses: Set<ICTranscriptionStatus> = [
        .queued,
        .analyzingMusic,
        .downloadingModel,
        .transcribing,
        .generatingChapters,
    ]

    private func canAutoResumeRemoteChapterJobAfterUnexpectedTermination(_ item: ICTranscriptionQueueItem) -> Bool {
        if item.chapterOnly,
           hasChapterGenerationTranscript(episodeHash: item.episodeHash),
           ICDownloadableModelStore.selectedModel(for: .textToChapters).usesRemoteChapterService {
            return true
        }
        guard item.automaticallyScheduled else { return false }
        if item.chapterOnly {
            return hasChapterGenerationTranscript(episodeHash: item.episodeHash)
        }
        return true
    }

    private func armCrashGuard(for item: ICTranscriptionQueueItem) {
        UserDefaults.standard.set(item.episodeHash, forKey: Self.crashGuardEpisodeHashKey)
        UserDefaults.standard.set(true, forKey: Self.crashGuardKey)
    }

    private func clearCrashGuard() {
        UserDefaults.standard.set(false, forKey: Self.crashGuardKey)
        UserDefaults.standard.removeObject(forKey: Self.crashGuardEpisodeHashKey)
    }

    override init() {
        super.init()
        // Execution grants cannot survive a process death. These values are kept
        // only for diagnostics/compute-profile visibility while this process is alive.
        UserDefaults.standard.removeObject(forKey: TranscriptionQueue.backgroundExecutionPathKey)
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.continuedBackgroundActiveKey)
        appliedWhisperKitExecutionPath = nil
        WhisperKitBackend.setActiveBackgroundExecutionPath(nil)
        loadPersistedQueue()
        ChapterGenerator.shared.resumePendingOpenAIBackgroundCancellations()

        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ICOpenAIBackgroundCancellationWorkDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.scheduleAutomaticBackgroundProcessingIfNeeded()
                self.postQueueChangeNotification()
            }
        }

        // Cancel transcription when episode cache is removed
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cacheFilesWillBeDeleted(_:)),
                                               name: NSNotification.Name("CacheManagerWillDeleteCacheFilesNotification"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cacheFilesWereDeleted(_:)),
                                               name: NSNotification.Name("CacheManagerDidDeleteCacheFilesNotification"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cacheDeletionWasRestored(_:)),
                                               name: NSNotification.Name("CacheManagerDidRestoreCacheNotification"),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(cacheIndexDidFinishBuilding(_:)),
                                               name: NSNotification.Name("CacheManagerDidFinishBuildingCacheIndexNotification"),
                                               object: nil)

        // Single observer for download completion (registered ONCE, not per-download)
        NotificationCenter.default.addObserver(forName: NSNotification.Name("CacheManagerDidEndCachingNotification"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in self._handleDownloadCompletion() }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("CacheManagerDidFailCachingEpisodeNotification"), object: nil, queue: .main) { [weak self] notification in
            guard let self,
                  let episode = notification.userInfo?["episode"] as? NSObject,
                  let episodeHash = episode.value(forKey: "objectHash") as? String else { return }
            let downloadError = notification.userInfo?["error"] as? NSError
            let message = downloadError?.localizedDescription
                ?? NSLocalizedString("The episode download could not be completed.", comment: "")
            Task { @MainActor in
                self._handleDownloadFailure(episodeHash: episodeHash, message: message, error: downloadError)
            }
        }

        // Release WhisperKit model on memory warning (frees ~200-600 MB)
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if !self.isProcessing {
                    await WhisperKitBackend.shared.releaseModel()
                    NSLog("[TranscriptionQueue] Released WhisperKit model due to memory warning")
                }
            }
        }

        NotificationCenter.default.addObserver(forName: ICTranscriptionInternalStatusDetailNotification, object: nil, queue: .main) { [weak self] note in
            guard let self = self,
                  let episodeHash = note.userInfo?["episodeHash"] as? String,
                  let detail = note.userInfo?["detail"] as? String else { return }
            Task { @MainActor in
                self.updateStatusDetail(for: episodeHash, detail: detail)
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.applyGrantedWhisperKitExecutionPathForCurrentLifecycle(reason: "applicationDidEnterBackground")
                self?.refreshBackgroundContinuation(reason: "applicationDidEnterBackground")
                _ = self?.pausePipelineForBackgroundIfNeeded(reason: "applicationDidEnterBackground")
            }
        }

        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.applyForegroundWhisperKitExecutionPath(reason: "applicationWillEnterForeground")
                self?.refreshBackgroundContinuation(reason: "applicationWillEnterForeground")
                self?.resumeIfNeeded()
            }
        }

        reconcilePersistedAutomaticDiscoveryOutbox()
        NSLog("[TranscriptionQueue] Initialized. Queue items: %d", items.count)

        if items.contains(where: { $0.automaticallyScheduled && $0.status == .queued })
            || ServerTranscriptionManager.shared.hasPendingAutomaticItems
            || chapterGen.hasPendingOpenAIBackgroundCancellationWork {
            scheduleAutomaticBackgroundProcessing(earliestBeginDate: earliestAutomaticBackgroundWorkDate())
            scheduleRetryWakeIfNeeded()
        }
    }

    // MARK: - Public API

    /// Add an episode to the transcription queue.
    /// Returns false if already queued or already transcribed.
    @objc func enqueue(episodeHash: String, episodeTitle: String, feedTitle: String,
                       audioURL: URL?, language: String?) -> Bool {
        enqueueJob(
            episodeHash: episodeHash,
            episodeTitle: episodeTitle,
            feedTitle: feedTitle,
            audioURL: audioURL,
            language: language,
            chapterOnly: false,
            automaticallyScheduled: false,
            shouldGenerateAnalysis: true
        )
    }

    @discardableResult
    private func enqueueJob(episodeHash: String,
                            episodeTitle: String,
                            feedTitle: String,
                            audioURL: URL?,
                            language: String?,
                            chapterOnly: Bool,
                            automaticallyScheduled: Bool,
                            shouldGenerateAnalysis: Bool,
                            knownEpisode: CDEpisode? = nil,
                            startImmediately: Bool = true,
                            persistImmediately: Bool = true) -> Bool {
        guard ICAITranscriptionFeaturesAvailable() else { return false }
        guard !cacheClearInProgress else { return false }
        guard UserDefaults.standard.bool(forKey: kLocalTranscriptionEnabled) else {
            ICDiagnosticLogger.shared.logEvent(
                "queue",
                message: "Lokaler Auftrag nicht erstellt, weil lokale Transkription deaktiviert ist",
                metadata: ["episodeHash": episodeHash, "chapterOnly": chapterOnly] as NSDictionary
            )
            return false
        }

        if chapterOnly {
            guard hasChapterGenerationTranscript(episodeHash: episodeHash, knownEpisode: knownEpisode) else { return false }
        } else {
            // A transcription job has nothing to do when an SRT already exists.
            guard !engine.hasSRT(for: episodeHash) else { return false }
        }

        let replaceFailedManualItem = !automaticallyScheduled && !chapterOnly
        if replaceFailedManualItem,
           items.contains(where: { item in
               item.episodeHash == episodeHash && item.status == .failed
           }) {
            chapterGen.cancelOpenAIBackgroundAnalysis(for: episodeHash)
            items.removeAll { item in
                item.episodeHash == episodeHash && item.status == .failed
            }
            ICDiagnosticLogger.shared.logEvent(
                "queue",
                message: "Fehlgeschlagenen Job durch manuelle Transkription ersetzt",
                metadata: ["episodeHash": episodeHash] as NSDictionary
            )
        }

        // Don't add if already in queue. Running and queued work is never replaced.
        guard !items.contains(where: { $0.episodeHash == episodeHash }) else { return false }

        let item = ICTranscriptionQueueItem(
            episodeHash: episodeHash,
            episodeTitle: episodeTitle,
            feedTitle: feedTitle,
            audioURL: audioURL,
            language: language
        )
        item.chapterOnly = chapterOnly
        item.automaticallyScheduled = automaticallyScheduled
        item.shouldGenerateAnalysis = shouldGenerateAnalysis
        items.append(item)
        if persistImmediately {
            persistQueue()
            postQueueChangeNotification()
        }

        // Start a fresh per-episode log so the user sees this run, not the previous one.
        TranscriptionLogger.shared.resetLog(episodeHash: episodeHash)
        let audioSizeDetail: String? = {
            guard let url = audioURL,
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64 else { return nil }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }()
        TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "queued",
                                          message: "In Warteschlange aufgenommen",
                                          detailText: audioSizeDetail)
        ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "queued", audioURL: audioURL)

        if automaticallyScheduled && persistImmediately {
            scheduleAutomaticBackgroundProcessing(earliestBeginDate: nil)
        }

        // Auto-start if not already processing
        if startImmediately && !isProcessing {
            processNext()
        }

        return true
    }

    private struct AutomaticProcessingDecision {
        let transcribe: Bool
        let analyze: Bool
        let transcribeSource: String
        let analyzeSource: String
        let transcribeRawValue: String
        let analyzeRawValue: String
    }

    private struct RevalidatedAutomaticRuntimeIntent {
        let transcribe: Bool
        let analyze: Bool
        let analysisRequested: Bool
        let analysisUnavailableReason: String?
    }

    private enum AutomaticAnalysisRequestRevalidationError: LocalizedError {
        case processingDisabled
        case analysisDisabled
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .processingDisabled:
                return NSLocalizedString("Automatische Verarbeitung ist für diesen Podcast nicht mehr aktiviert.", comment: "")
            case .analysisDisabled:
                return NSLocalizedString("Automatische Analyse ist für diesen Podcast deaktiviert.", comment: "")
            case .unavailable(let reason):
                return reason
            }
        }
    }

    private func resolvedAutomaticSetting(feed: CDFeed,
                                          feedKey: String,
                                          globalKey: String) -> (enabled: Bool, source: String, rawValue: String) {
        let rawValue = feed.string(forKey: feedKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "default"
        switch rawValue {
        case "yes":
            return (true, "feed", rawValue)
        case "no":
            return (false, "feed", rawValue)
        default:
            return (UserDefaults.standard.bool(forKey: globalKey), "global", rawValue)
        }
    }

    /// The stored preference only decides when both backends are available. With
    /// exactly one enabled backend the automatic run uses that one — the chooser is
    /// hidden in the settings then, so a stale preference must not disable automatic
    /// processing. nil means no backend is enabled at all.
    @objc static func resolvedAutomaticBackend() -> String? {
        guard ICAITranscriptionFeaturesAvailable() else { return nil }
        let localEnabled = UserDefaults.standard.bool(forKey: kLocalTranscriptionEnabled)
        let serverEnabled = UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled)
        switch (localEnabled, serverEnabled) {
        case (false, false):
            return nil
        case (true, false):
            return "local"
        case (false, true):
            return "server"
        case (true, true):
            return UserDefaults.standard.string(forKey: kAutomaticTranscriptionBackend) == "server" ? "server" : "local"
        }
    }

    private func automaticProcessingDecision(for episode: CDEpisode) -> AutomaticProcessingDecision? {
        guard Self.resolvedAutomaticBackend() != nil else { return nil }
        guard let feed = episode.feed, feed.subscribed else { return nil }
        let transcription = resolvedAutomaticSetting(
            feed: feed,
            feedKey: kFeedPropertyAutoTranscribe,
            globalKey: kTranscriptionAutoDefault
        )
        let analysis = resolvedAutomaticSetting(
            feed: feed,
            feedKey: kFeedPropertyAutoChapters,
            globalKey: kChapterAutoDefault
        )
        return AutomaticProcessingDecision(
            transcribe: transcription.enabled,
            analyze: analysis.enabled,
            transcribeSource: transcription.source,
            analyzeSource: analysis.source,
            transcribeRawValue: transcription.rawValue,
            analyzeRawValue: analysis.rawValue
        )
    }

    /// Persisted queue intent is only a recovery hint. Subscription state,
    /// per-feed overrides, the selected model, and credentials are authoritative
    /// each time an automatic job crosses a work boundary.
    private func revalidatedAutomaticRuntimeIntent(
        for item: ICTranscriptionQueueItem,
        stage: String
    ) -> RevalidatedAutomaticRuntimeIntent? {
        guard let episode = findEpisode(hash: item.episodeHash) else {
            ICDiagnosticLogger.shared.logEvent(
                "automatic-runtime-revalidation",
                message: "Episode für automatischen Job nicht mehr gefunden",
                metadata: [
                    "episodeHash": item.episodeHash,
                    "stage": stage,
                    "episodeFound": false,
                ] as NSDictionary
            )
            return nil
        }
        guard let decision = automaticProcessingDecision(for: episode) else {
            ICDiagnosticLogger.shared.logEvent(
                "automatic-runtime-revalidation",
                message: "Automatischer Job ist nicht mehr konfiguriert",
                metadata: [
                    "episodeHash": item.episodeHash,
                    "stage": stage,
                    "episodeFound": true,
                    "subscribed": episode.feed?.subscribed ?? false,
                ] as NSDictionary
            )
            return nil
        }

        let selectedModel = ICDownloadableModelStore.selectedModel(for: .textToChapters)
        let selectedModelCanGenerate = ICDownloadableModelStore.selectedChapterModelCanGenerate()
        let analysisAuthorized = decision.analyze && selectedModelCanGenerate
        let analysisUnavailableReason: String?
        if decision.analyze && !selectedModelCanGenerate {
            analysisUnavailableReason = ICDownloadableModelStore.selectedChapterModelUnavailableReason()
        } else {
            analysisUnavailableReason = nil
        }

        ICDiagnosticLogger.shared.logEvent(
            "automatic-runtime-revalidation",
            message: analysisAuthorized || !decision.analyze
                ? "Automatischen Job gegen aktuelle Konfiguration geprüft"
                : "Automatische Analyse wegen ungültiger Laufzeitkonfiguration gesperrt",
            metadata: [
                "episodeHash": item.episodeHash,
                "stage": stage,
                "autoTranscribe": decision.transcribe,
                "autoAnalysisRequested": decision.analyze,
                "autoAnalysisAuthorized": analysisAuthorized,
                "transcribeSource": decision.transcribeSource,
                "analysisSource": decision.analyzeSource,
                "transcribeRaw": decision.transcribeRawValue,
                "analysisRaw": decision.analyzeRawValue,
                "selectedModel": selectedModel.identifier,
                "selectedModelCanGenerate": selectedModelCanGenerate,
                "reason": analysisUnavailableReason ?? "",
            ] as NSDictionary
        )

        return RevalidatedAutomaticRuntimeIntent(
            transcribe: decision.transcribe,
            analyze: analysisAuthorized,
            analysisRequested: decision.analyze,
            analysisUnavailableReason: analysisUnavailableReason
        )
    }

    private func revalidateAutomaticCandidateBeforeStart(
        _ item: ICTranscriptionQueueItem
    ) -> RevalidatedAutomaticRuntimeIntent? {
        revalidatedAutomaticRuntimeIntent(for: item, stage: "before-candidate-start")
    }

    private func revalidateAutomaticAnalysisImmediatelyBeforeRequest(
        _ item: ICTranscriptionQueueItem
    ) throws {
        guard item.automaticallyScheduled else { return }
        guard let runtimeIntent = revalidatedAutomaticRuntimeIntent(
            for: item,
            stage: "immediately-before-semantic-request"
        ) else {
            item.shouldGenerateAnalysis = false
            chapterGen.cancelOpenAIBackgroundAnalysis(for: item.episodeHash)
            throw AutomaticAnalysisRequestRevalidationError.processingDisabled
        }

        item.shouldGenerateAnalysis = runtimeIntent.analyze
        guard runtimeIntent.transcribe || runtimeIntent.analysisRequested else {
            chapterGen.cancelOpenAIBackgroundAnalysis(for: item.episodeHash)
            throw AutomaticAnalysisRequestRevalidationError.processingDisabled
        }
        if let reason = runtimeIntent.analysisUnavailableReason {
            chapterGen.cancelOpenAIBackgroundAnalysis(for: item.episodeHash)
            throw AutomaticAnalysisRequestRevalidationError.unavailable(reason)
        }
        guard runtimeIntent.analyze else {
            chapterGen.cancelOpenAIBackgroundAnalysis(for: item.episodeHash)
            throw AutomaticAnalysisRequestRevalidationError.analysisDisabled
        }
    }

    private func removeAutomaticQueueItemAfterRuntimeRevalidation(
        _ item: ICTranscriptionQueueItem,
        stage: String,
        reason: String
    ) {
        chapterGen.cancelOpenAIBackgroundAnalysis(for: item.episodeHash)
        pendingDownloadHashes.remove(item.episodeHash)
        items.removeAll { $0 === item }
        TranscriptionLogger.shared.append(
            episodeHash: item.episodeHash,
            phase: "automatic",
            message: "Automatischen Job nach Konfigurationsprüfung beendet",
            detailText: reason
        )
        ICDiagnosticLogger.shared.logEvent(
            "automatic-runtime-revalidation",
            message: "Automatischen Queue-Job entfernt",
            metadata: [
                "episodeHash": item.episodeHash,
                "stage": stage,
                "reason": reason,
            ] as NSDictionary
        )
        persistQueue()
        postQueueChangeNotification()
    }

    private func finishActiveAutomaticPipelineAfterRuntimeRevalidation(
        _ item: ICTranscriptionQueueItem,
        runID: UUID,
        stage: String,
        reason: String
    ) {
        guard processingRunIsCurrent(runID) else { return }
        clearProcessingRun(runID)
        clearCrashGuard()
        isProcessing = false
        currentTask = nil
        removeAutomaticQueueItemAfterRuntimeRevalidation(item, stage: stage, reason: reason)
        refreshBackgroundContinuation(reason: "automatic-runtime-intent-ended-active-pipeline")
        NotificationCenter.default.post(
            name: NSNotification.Name("ICTranscriptionDidChangeNotification"),
            object: nil,
            userInfo: ["episodeHash": item.episodeHash]
        )
        processNext()
        releaseModelIfIdle(reason: "automatic-runtime-intent-ended-active-pipeline")
    }

    private func finishAutomaticChapterTaskAfterRuntimeRevalidation(
        _ item: ICTranscriptionQueueItem,
        stage: String,
        reason: String
    ) {
        chapterTask = nil
        clearCrashGuard()
        removeAutomaticQueueItemAfterRuntimeRevalidation(item, stage: stage, reason: reason)
        refreshBackgroundContinuation(reason: "automatic-runtime-intent-ended-chapter-task")
        NotificationCenter.default.post(
            name: NSNotification.Name("ICTranscriptionDidChangeNotification"),
            object: nil,
            userInfo: ["episodeHash": item.episodeHash]
        )
        processNext()
        releaseModelIfIdle(reason: "automatic-runtime-intent-ended-chapter-task")
    }

    @objc(recordAutomaticDiscoveryForEpisodes:)
    func recordAutomaticDiscovery(for episodes: [CDEpisode]) -> NSError? {
        guard ICAITranscriptionFeaturesAvailable() else { return nil }
        let episodeHashes = Set(episodes.compactMap { episode -> String? in
            guard let episodeHash = episode.objectHash, !episodeHash.isEmpty else { return nil }
            return episodeHash
        })
        guard !episodeHashes.isEmpty else { return nil }

        let error = ICPersistAutomaticDiscoveryHashesBeforeHandoff(episodeHashes)
        let message = error == nil
            ? "Neue Folgen vor Queue-Handoff dauerhaft vorgemerkt"
            : "Neue Folgen konnten nicht dauerhaft vorgemerkt werden"
        ICDiagnosticLogger.shared.logEvent(
            "automatic-transcription-discovery",
            message: message,
            metadata: [
                "episodeCount": episodeHashes.count,
                "episodeHashes": episodeHashes.sorted().joined(separator: ","),
                "error": error?.localizedDescription ?? "",
            ] as NSDictionary
        )
        return error
    }

    private func acknowledgeAutomaticDiscovery(_ episodeHashes: Set<String>) {
        guard !episodeHashes.isEmpty else { return }
        ICUpdatePersistedAutomaticDiscoveryOutbox(removing: episodeHashes) { error in
            Task { @MainActor in
                ICDiagnosticLogger.shared.logEvent(
                    "automatic-transcription-discovery",
                    message: error == nil
                        ? "Discovery nach dauerhaftem Queue-Entscheid bestätigt"
                        : "Discovery-Bestätigung konnte nicht gespeichert werden",
                    metadata: [
                        "episodeCount": episodeHashes.count,
                        "episodeHashes": episodeHashes.sorted().joined(separator: ","),
                        "error": error?.localizedDescription ?? "",
                    ] as NSDictionary
                )
            }
        }
    }

    private func reconcilePersistedAutomaticDiscoveryOutbox() {
        guard ICAITranscriptionFeaturesAvailable() else { return }
        let persistedHashes: Set<String>
        do {
            persistedHashes = try ICLoadPersistedAutomaticDiscoveryHashes()
        } catch {
            ICDiagnosticLogger.shared.logEvent(
                "automatic-transcription-discovery",
                message: "Persistierte Discovery-Outbox konnte nicht gelesen werden",
                metadata: ["error": error.localizedDescription] as NSDictionary
            )
            return
        }
        guard !persistedHashes.isEmpty,
              let dmanager = DatabaseManager.shared() else { return }

        let fetchedEpisodes = dmanager.episodes(withObjectHashes: persistedHashes.sorted()) as? [CDEpisode] ?? []
        var episodesByHash: [String: CDEpisode] = [:]
        for episode in fetchedEpisodes {
            guard let episodeHash = episode.objectHash, persistedHashes.contains(episodeHash) else { continue }
            episodesByHash[episodeHash] = episode
        }
        let missingEpisodeHashes = persistedHashes.subtracting(episodesByHash.keys)
        ICDiagnosticLogger.shared.logEvent(
            "automatic-transcription-discovery",
            message: "Persistierte Discovery-Outbox beim Start abgeglichen",
            metadata: [
                "resolvedCount": episodesByHash.count,
                "missingCount": missingEpisodeHashes.count,
                "missingEpisodeHashes": missingEpisodeHashes.sorted().joined(separator: ","),
            ] as NSDictionary
        )
        guard !episodesByHash.isEmpty else { return }
        automaticProcessingDecision(episodes: Array(episodesByHash.values))
    }

    private func automaticProcessingDecision(episodes: [CDEpisode]) {
        var episodesByHash: [String: CDEpisode] = [:]
        episodesByHash.reserveCapacity(episodes.count)
        for episode in episodes {
            guard let episodeHash = episode.objectHash, !episodeHash.isEmpty else { continue }
            episodesByHash[episodeHash] = episode
        }
        let discoveryHashesToAcknowledge = Set(episodesByHash.keys)
        guard !discoveryHashesToAcknowledge.isEmpty else { return }
        var didEnqueueAny = false
        let automaticBackend = Self.resolvedAutomaticBackend() ?? "local"
        for episodeHash in episodesByHash.keys.sorted() {
            guard let episode = episodesByHash[episodeHash],
                  let decision = automaticProcessingDecision(for: episode) else {
                continue
            }

            if automaticBackend == "server" {
                guard decision.transcribe || decision.analyze else { continue }
                ServerTranscriptionManager.shared.enqueueAutomaticEpisodes([episode])
                didEnqueueAny = true
                ICDiagnosticLogger.shared.logEvent(
                    "automatic-transcription-decision",
                    message: "Automatische Server-Verarbeitung geplant",
                    metadata: [
                        "episodeHash": episodeHash,
                        "episodeTitle": episode.title ?? "",
                        "feedTitle": episode.feed?.title ?? "",
                        "backend": "server",
                    ] as NSDictionary
                )
                continue
            }

            let hasTranscript = hasChapterGenerationTranscript(episodeHash: episodeHash, knownEpisode: episode)
            let chapterOnly = decision.analyze && hasTranscript
            let needsTranscription = !hasTranscript && (decision.transcribe || decision.analyze)
            let shouldSchedule = chapterOnly || needsTranscription
            let detail = [
                "autoTranscribe=\(decision.transcribe)",
                "autoAnalysis=\(decision.analyze)",
                "transcribeSource=\(decision.transcribeSource)",
                "analysisSource=\(decision.analyzeSource)",
                "transcribeRaw=\(decision.transcribeRawValue)",
                "analysisRaw=\(decision.analyzeRawValue)",
                "hasTranscript=\(hasTranscript)",
                "chapterOnly=\(chapterOnly)",
            ].joined(separator: ", ")

            guard shouldSchedule else {
                ICDiagnosticLogger.shared.logEvent(
                    "automatic-transcription-decision",
                    message: "Automatische Verarbeitung übersprungen",
                    metadata: [
                        "episodeHash": episodeHash,
                        "episodeTitle": episode.title ?? "",
                        "feedTitle": episode.feed?.title ?? "",
                        "detail": detail,
                    ] as NSDictionary
                )
                continue
            }

            let enqueued = enqueueJob(
                episodeHash: episodeHash,
                episodeTitle: episode.title ?? episodeHash,
                feedTitle: episode.feed?.title ?? "",
                audioURL: chapterOnly ? nil : resolveAudioURL(for: episode),
                language: episode.feed?.language,
                chapterOnly: chapterOnly,
                automaticallyScheduled: true,
                shouldGenerateAnalysis: decision.analyze,
                knownEpisode: episode,
                startImmediately: false,
                persistImmediately: false
            )
            didEnqueueAny = didEnqueueAny || enqueued

            let message = enqueued ? "Automatische Verarbeitung geplant" : "Automatische Verarbeitung bereits geplant"
            TranscriptionLogger.shared.append(
                episodeHash: episodeHash,
                phase: "queued",
                message: message,
                detailText: detail
            )
            ICDiagnosticLogger.shared.logEvent(
                "automatic-transcription-decision",
                message: message,
                metadata: [
                    "episodeHash": episodeHash,
                    "episodeTitle": episode.title ?? "",
                    "feedTitle": episode.feed?.title ?? "",
                    "autoTranscribe": decision.transcribe,
                    "autoAnalysis": decision.analyze,
                    "transcribeSource": decision.transcribeSource,
                    "analysisSource": decision.analyzeSource,
                    "hasTranscript": hasTranscript,
                    "chapterOnly": chapterOnly,
                    "enqueued": enqueued,
                ] as NSDictionary
            )
        }

        let shouldStartAfterPersistence = didEnqueueAny
        persistQueue { error in
            Task { @MainActor in
                guard error == nil else {
                    ICDiagnosticLogger.shared.logEvent(
                        "automatic-transcription-decision",
                        message: "Automatische Warteschlange konnte nicht dauerhaft gespeichert werden",
                        metadata: ["error": error?.localizedDescription ?? ""] as NSDictionary
                    )
                    return
                }
                self.acknowledgeAutomaticDiscovery(discoveryHashesToAcknowledge)
                guard shouldStartAfterPersistence else { return }
                self.postQueueChangeNotification()
                self.scheduleAutomaticBackgroundProcessing(earliestBeginDate: nil)
                if !self.isProcessing {
                    self.processNext()
                }
            }
        }
    }

    /// Durable pipeline handoff from SubscriptionManager. The UI notification is
    /// intentionally not the trigger: the queue singleton must exist before the
    /// episode-added event can be considered delivered.
    @objc(scheduleAutomaticProcessingForEpisodes:)
    func scheduleAutomaticProcessing(for episodes: [CDEpisode]) {
        guard ICAITranscriptionFeaturesAvailable() else { return }
        automaticProcessingDecision(episodes: episodes)
    }

    /// Remove an episode from the queue. Cancels transcription if currently processing.
    @objc func dequeue(episodeHash: String) {
        chapterGen.cancelOpenAIBackgroundAnalysis(for: episodeHash)
        // If dequeuing the currently processing item, cancel its transcription
        var needsProcessNext = false
        var didCancelCurrent = false
        var shouldCleanupBrokenArtifacts = false
        var cleanupAsChapterArtifacts = false
        if let item = items.first(where: { $0.episodeHash == episodeHash }) {
            shouldCleanupBrokenArtifacts = item.status == .failed || (item.status == .queued && item.error != nil)
            cleanupAsChapterArtifacts = item.chapterOnly || engine.hasSRT(for: item.episodeHash)
            if item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel {
                invalidateProcessingRun()
                currentTask?.cancel()
                currentTask = nil
                engine.cancelTranscription()
                isProcessing = false
                needsProcessNext = true
                didCancelCurrent = true
            } else if item.status == .generatingChapters {
                // Chapter generation can run inside currentTask (auto after transcription)
                // OR in chapterTask (standalone via generateChapters API). Cancel both
                // because we can't tell from here which one owns the active step.
                invalidateProcessingRun()
                currentTask?.cancel()
                currentTask = nil
                chapterTask?.cancel()
                chapterTask = nil
                isProcessing = false
                needsProcessNext = true
                didCancelCurrent = true
            }
        }
        pendingDownloadHashes.remove(episodeHash)
        items.removeAll { $0.episodeHash == episodeHash }
        // If the user explicitly cancelled the active run, drop the crash guard now —
        // the abort was deliberate, not a kill, so we mustn't show "previous run was
        // aborted" on next launch.
        if didCancelCurrent {
            analyzer.cancelAnalysis()
            cancelSpeechModelPreparation(reason: "dequeue-cancelled-active-item")
            clearCrashGuard()
            refreshBackgroundContinuation(reason: "dequeue-cancelled-active-item")
        }
        if pendingDownloadHashes.isEmpty && !items.contains(where: { $0.status == .queued || $0.status == .analyzingMusic || $0.status == .downloadingModel || $0.status == .transcribing }) {
            cancelSpeechModelPreparation(reason: "dequeue-no-pending-transcription")
        }
        if shouldCleanupBrokenArtifacts {
            cleanupBrokenArtifacts(episodeHash: episodeHash, chapterOnly: cleanupAsChapterArtifacts)
        }
        persistQueue()
        postQueueChangeNotification()
        // Defer processNext to avoid modifying items during UIKit row-delete animation
        if needsProcessNext && items.contains(where: { $0.status == .queued }) {
            DispatchQueue.main.async { [weak self] in
                self?.processNext()
            }
        }
    }

    /// Remove all items from the queue and cancel current transcription.
    @objc func cancelAll() {
        let cancelledEpisodeHashes = Set(items.map(\.episodeHash))
        for episodeHash in cancelledEpisodeHashes {
            chapterGen.cancelOpenAIBackgroundAnalysis(for: episodeHash)
        }
        invalidateProcessingRun()
        currentTask?.cancel()
        currentTask = nil
        chapterTask?.cancel()
        chapterTask = nil
        computeProfileTransitionTask?.cancel()
        computeProfileTransitionTask = nil
        computeProfileTransitionID = nil
        cancelSpeechModelPreparation(reason: "cancelAll")
        engine.cancelTranscription()
        analyzer.cancelAnalysis()
        items.removeAll()
        isProcessing = false
        chapterTask = nil
        retryWakeTask?.cancel()
        retryWakeTask = nil
        // Explicit user cancel — drop the crash guard so the next launch isn't
        // misclassified as crash-recovery.
        clearCrashGuard()
        refreshBackgroundContinuation(reason: "cancelAll")
        persistQueue()
        postQueueChangeNotification()
        releaseModelIfIdle(reason: "cancelAll")
    }

    @objc func enqueueExistingEpisode(episodeHash: String) -> Bool {
        guard let episode = findEpisode(hash: episodeHash) else {
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Episode fuer Transkription nicht gefunden",
                                               metadata: ["episodeHash": episodeHash] as NSDictionary)
            return false
        }
        return enqueue(episodeHash: episodeHash,
                       episodeTitle: episode.title ?? episodeHash,
                       feedTitle: episode.feed?.title ?? "",
                       audioURL: resolveAudioURL(for: episodeHash),
                       language: episode.feed?.language)
    }

    @objc func generateChaptersForExistingEpisode(episodeHash: String) -> Bool {
        guard let episode = findEpisode(hash: episodeHash) else {
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Episode fuer Kapitelerstellung nicht gefunden",
                                               metadata: ["episodeHash": episodeHash] as NSDictionary)
            return false
        }
        guard hasChapterGenerationTranscript(episodeHash: episodeHash) else {
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Transkript fuer Kapitelerstellung fehlt",
                                               metadata: ["episodeHash": episodeHash] as NSDictionary)
            return false
        }
        guard ICDownloadableModelStore.selectedChapterModelIsReady() else {
            TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                              phase: "chapters",
                                              message: "Kapitelerstellung nicht gestartet",
                                              detailText: NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: ""))
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Kapitelmodell fuer Kapitelerstellung nicht bereit",
                                               metadata: [
                                                "episodeHash": episodeHash,
                                                "reason": NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: ""),
                                               ] as NSDictionary)
            return false
        }
        guard ICDownloadableModelStore.selectedChapterModelCanGenerate() else {
            let reason = ICDownloadableModelStore.selectedChapterModelUnavailableReason()
            TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                              phase: "chapters",
                                              message: "Kapitelerstellung nicht gestartet",
                                              detailText: reason)
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Kapitelmodell fuer Kapitelerstellung nicht verfuegbar",
                                               metadata: [
                                                "episodeHash": episodeHash,
                                                "reason": reason,
                                               ] as NSDictionary)
            return false
        }
        return generateChapters(episodeHash: episodeHash,
                                episodeTitle: episode.title ?? episodeHash,
                                feedTitle: episode.feed?.title ?? "")
    }

    @objc func debugQueueSnapshot() -> NSArray {
        let snapshot = items.map { item -> NSDictionary in
            [
                "episodeHash": item.episodeHash,
                "episodeTitle": item.episodeTitle,
                "feedTitle": item.feedTitle,
                "status": item.status.rawValue,
                "statusName": Self.debugStatusName(item.status),
                "progress": item.progress,
                "error": item.error ?? "",
                "statusDetail": item.statusDetail ?? "",
                "statusStartedAt": item.statusStartedAt.map(Self.debugTimestampString) ?? "",
                "completedAt": item.completedAt.map(Self.debugTimestampString) ?? "",
                "chapterOnly": item.chapterOnly,
                "automaticallyScheduled": item.automaticallyScheduled,
                "shouldGenerateAnalysis": item.shouldGenerateAnalysis,
                "retryAttempt": item.retryAttempt,
                "nextRetryAt": item.nextRetryAt.map(Self.debugTimestampString) ?? "",
                "requiresExplicitRetryAfterCrash": item.requiresExplicitRetryAfterCrash,
            ] as NSDictionary
        }
        return snapshot as NSArray
    }

    @objc func debugInspection(episodeHash: String) -> NSDictionary {
        let srtURL = ICTranscriptionPaths.srtURL(for: episodeHash)
        let chaptersURL = ICTranscriptionPaths.chaptersJSONURL(for: episodeHash)
        let analysisURL = ICTranscriptionPaths.analysisJSONURL(for: episodeHash)
        let musicURL = ICTranscriptionPaths.musicTimelineURL(for: episodeHash)
        let checkpointURL = ICTranscriptionPaths.checkpointURL(for: episodeHash)
        let logURL = TranscriptionEngine.shared.transcriptCacheDirectory()
            .appendingPathComponent("\(episodeHash)_log.json")
        let chapterDebugURL = TranscriptionEngine.shared.transcriptCacheDirectory()
            .appendingPathComponent("\(episodeHash)_chapter_debug.json")
        let chapters = ChapterGenerator.shared.loadChapters(for: episodeHash) ?? []
        let logEntries = TranscriptionLogger.shared.entries(episodeHash: episodeHash).map { entry -> NSDictionary in
            [
                "timestamp": Self.debugTimestampString(entry.timestamp),
                "phase": entry.phase,
                "message": entry.message,
                "detailText": entry.detailText ?? "",
            ] as NSDictionary
        }

        return [
            "episodeHash": episodeHash,
            "queue": debugQueueSnapshot(),
            "artifacts": [
                "srt": Self.debugFileSnapshot(srtURL),
                "chapters": Self.debugFileSnapshot(chaptersURL),
                "analysis": Self.debugFileSnapshot(analysisURL),
                "music": Self.debugFileSnapshot(musicURL),
                "checkpoint": Self.debugFileSnapshot(checkpointURL),
                "episodeLog": Self.debugFileSnapshot(logURL),
                "chapterDebug": Self.debugFileSnapshot(chapterDebugURL),
            ],
            "chapters": chapters.map { chapter -> NSDictionary in
                [
                    "start": chapter.start,
                    "end": chapter.end,
                    "title": chapter.title,
                    "isSponsor": chapter.isSponsor,
                ] as NSDictionary
            },
            "log": logEntries,
        ] as NSDictionary
    }

    /// Generate chapters for an episode that already has a transcript.
    @objc func generateChapters(episodeHash: String, episodeTitle: String, feedTitle: String) -> Bool {
        guard ICAITranscriptionFeaturesAvailable() else { return false }
        guard UserDefaults.standard.bool(forKey: kLocalTranscriptionEnabled) else { return false }
        guard ICDownloadableModelStore.selectedChapterModelIsReady() else {
            NSLog("[TranscriptionQueue] Cannot generate chapters: chapter model is not downloaded")
            return false
        }

        guard ICDownloadableModelStore.selectedChapterModelCanGenerate() else {
            NSLog("[TranscriptionQueue] Cannot generate chapters: %@", ICDownloadableModelStore.selectedChapterModelUnavailableReason())
            return false
        }

        let activeStatuses: Set<ICTranscriptionStatus> = [.queued, .analyzingMusic, .downloadingModel, .transcribing, .generatingChapters]
        guard !items.contains(where: { $0.episodeHash == episodeHash && activeStatuses.contains($0.status) }) else {
            NSLog("[TranscriptionQueue] Episode %@ already in queue, skipping chapter generation", episodeHash)
            return false
        }
        items.removeAll { $0.episodeHash == episodeHash && ($0.status == .completed || $0.status == .failed) }

        guard hasChapterGenerationTranscript(episodeHash: episodeHash) else {
            NSLog("[TranscriptionQueue] No usable transcript for %@", episodeHash)
            return false
        }

        // Add to queue with special "chapters only" status
        let item = ICTranscriptionQueueItem(
            episodeHash: episodeHash,
            episodeTitle: episodeTitle,
            feedTitle: feedTitle,
            audioURL: nil,
            language: nil
        )
        item.chapterOnly = true
        items.append(item)
        persistQueue()
        postQueueChangeNotification()

        TranscriptionLogger.shared.resetLog(episodeHash: episodeHash)
        TranscriptionLogger.shared.append(
            episodeHash: episodeHash,
            phase: "queued",
            message: "Kapitelerstellung in Warteschlange aufgenommen",
            detailText: nil
        )

        if !isProcessing && chapterTask == nil {
            processNext()
        }
        return true
    }

    private enum GeneratedSemanticArtifacts {
        case analysis(EpisodeAnalysisResult)
        case chapters([ICGeneratedChapter])

        var chapters: [ICGeneratedChapter] {
            switch self {
            case .analysis(let result):
                return result.chapters
            case .chapters(let chapters):
                return chapters
            }
        }

        var summaryCharacterCount: Int {
            switch self {
            case .analysis(let result):
                return result.summary.count
            case .chapters:
                return 0
            }
        }
    }

    private struct PublisherChapterSnapshot {
        let title: String
        let start: Double
        let end: Double
        let linkURL: URL?
    }

    private struct EmbeddedPublisherChapterMetadata {
        let chapters: [PublisherChapterSnapshot]
        let timelineDuration: Double
    }

    /// CDChapter is authoritative whenever it already exists. Podcasting 2.0
    /// chapters commonly omit duration, so only those missing ends are derived
    /// from the next publisher start (or the known episode timeline).
    private func storedPublisherChapters(for episode: CDEpisode,
                                         transcriptEnd: Double) throws -> [PublisherChapterSnapshot] {
        let publisherChapters = (episode.sortedChapters() as? [CDChapter]) ?? []
        guard !publisherChapters.isEmpty else { return [] }

        var previousStart = -Double.infinity
        for chapter in publisherChapters {
            let title = chapter.title ?? ""
            guard chapter.timecode.isFinite,
                  chapter.duration.isFinite,
                  chapter.duration >= 0,
                  chapter.timecode >= 0,
                  chapter.timecode > previousStart,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NSError(
                    domain: "TranscriptionQueue.PublisherChapters",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Vorhandene Podcast-Kapitel haben keine gültige chronologische Zeitachse.", comment: "")]
                )
            }
            previousStart = chapter.timecode
        }

        let lastPublisherChapter = publisherChapters[publisherChapters.count - 1]
        let maximumExplicitEnd = publisherChapters
            .filter { $0.duration > 0 }
            .map { $0.timecode + $0.duration }
            .max() ?? 0
        let timelineEnd = max(transcriptEnd, Double(episode.duration), maximumExplicitEnd)
        guard timelineEnd > lastPublisherChapter.timecode else {
            throw NSError(
                domain: "TranscriptionQueue.PublisherChapters",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Das Ende der vorhandenen Podcast-Kapitel ist unbekannt.", comment: "")]
            )
        }

        var snapshots: [PublisherChapterSnapshot] = []
        snapshots.reserveCapacity(publisherChapters.count)
        for (index, chapter) in publisherChapters.enumerated() {
            let nextPublisherStart = index + 1 < publisherChapters.count
                ? publisherChapters[index + 1].timecode
                : nil
            let explicitEnd = chapter.duration > 0
                ? chapter.timecode + chapter.duration
                : nil
            if let explicitEnd,
               let nextPublisherStart,
               explicitEnd > nextPublisherStart + 0.001 {
                throw NSError(
                    domain: "TranscriptionQueue.PublisherChapters",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Vorhandene Podcast-Kapitel haben überlappende explizite Grenzen.", comment: "")]
                )
            }
            let end = explicitEnd ?? nextPublisherStart ?? timelineEnd
            guard end.isFinite,
                  end > chapter.timecode,
                  end <= timelineEnd + 0.001 else {
                throw NSError(
                    domain: "TranscriptionQueue.PublisherChapters",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Vorhandene Podcast-Kapitel haben ungültige Endgrenzen.", comment: "")]
                )
            }
            snapshots.append(PublisherChapterSnapshot(
                title: chapter.title ?? "",
                start: chapter.timecode,
                end: end,
                linkURL: chapter.linkURL
            ))
        }
        return snapshots
    }

    /// Loads raw embedded metadata before a never-played episode reaches the
    /// remote semantic model. A parser error remains an error (with its original
    /// cause for retry classification); an unsupported metadata format is an
    /// evidenced, successful "no embedded chapters" result.
    private func loadEmbeddedPublisherChapters(from mediaURL: URL,
                                               episodeHash: String,
                                               episodeDuration: Double) async throws -> EmbeddedPublisherChapterMetadata {
        let metadataSource = mediaURL.isFileURL ? "local-cache" : "podcast-media"
        guard let parser = ICMetadataParser(assetURL: mediaURL) else {
            throw NSError(
                domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel konnten nicht gelesen werden.", comment: "")]
            )
        }
        let parserBox = ICMetadataParserSendableBox(parser: parser)
        let metadata: EmbeddedPublisherChapterMetadata = try await withCheckedThrowingContinuation { continuation in
            parserBox.parser.loadAsynchronously { success, error in
                if let error {
                    let wrapped = NSError(
                        domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel konnten nicht gelesen werden.", comment: ""),
                            NSUnderlyingErrorKey: error,
                        ]
                    )
                    ICDiagnosticLogger.shared.logEvent(
                        "embedded-publisher-chapters",
                        message: "Eingebettete Medien-Kapitel konnten nicht gelesen werden",
                        metadata: [
                            "episodeHash": episodeHash,
                            "source": metadataSource,
                            "parserSuccess": success,
                            "errorDomain": (error as NSError).domain,
                            "errorCode": (error as NSError).code,
                        ] as NSDictionary
                    )
                    continuation.resume(throwing: wrapped)
                    return
                }

                guard success, let metadataAsset = parserBox.parser.metadataAsset else {
                    ICDiagnosticLogger.shared.logEvent(
                        "embedded-publisher-chapters",
                        message: "Mediendatei enthält kein unterstütztes eingebettetes Kapitel-Format",
                        metadata: [
                            "episodeHash": episodeHash,
                            "source": metadataSource,
                            "parserSuccess": success,
                            "chapterCount": 0,
                        ] as NSDictionary
                    )
                    continuation.resume(returning: EmbeddedPublisherChapterMetadata(
                        chapters: [],
                        timelineDuration: 0
                    ))
                    return
                }

                let parsedDuration = CMTimeGetSeconds(metadataAsset.duration)
                let finiteParsedDuration = parsedDuration.isFinite && parsedDuration > 0 ? parsedDuration : 0
                let finiteEpisodeDuration = episodeDuration.isFinite && episodeDuration > 0 ? episodeDuration : 0
                let trackDuration = max(finiteParsedDuration, finiteEpisodeDuration)
                let embeddedChapters = (metadataAsset.chapters as? [ICMetadataChapter]) ?? []
                var parsedSnapshots: [PublisherChapterSnapshot] = []
                parsedSnapshots.reserveCapacity(embeddedChapters.count)
                var previousStart = -Double.infinity
                var previousEnd = 0.0

                for chapter in embeddedChapters {
                    let title = (chapter.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = CMTimeGetSeconds(chapter.start)
                    let duration = chapter.duration(withTrackDuration: trackDuration)
                    let end = start + duration
                    guard start.isFinite,
                          duration.isFinite,
                          end.isFinite,
                          start >= 0,
                          start > previousStart,
                          start + 0.001 >= previousEnd,
                          duration > 0,
                          !title.isEmpty else {
                        let validationError = NSError(
                            domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel haben keine gültige chronologische Zeitachse.", comment: "")]
                        )
                        ICDiagnosticLogger.shared.logEvent(
                            "embedded-publisher-chapters",
                            message: "Eingebettete Medien-Kapitel haben eine ungültige Zeitachse",
                            metadata: [
                                "episodeHash": episodeHash,
                                "source": metadataSource,
                                "chapterCount": embeddedChapters.count,
                                "invalidStart": start,
                                "invalidDuration": duration,
                            ] as NSDictionary
                        )
                        continuation.resume(throwing: validationError)
                        return
                    }
                    parsedSnapshots.append(PublisherChapterSnapshot(
                        title: title,
                        start: start,
                        end: end,
                        linkURL: chapter.link
                    ))
                    previousStart = start
                    previousEnd = end
                }

                ICDiagnosticLogger.shared.logEvent(
                    "embedded-publisher-chapters",
                    message: "Eingebettete Publisher-Kapitel gelesen",
                    metadata: [
                        "episodeHash": episodeHash,
                        "source": metadataSource,
                        "parserSuccess": success,
                        "chapterCount": parsedSnapshots.count,
                        "trackDuration": trackDuration,
                    ] as NSDictionary
                )
                continuation.resume(returning: EmbeddedPublisherChapterMetadata(
                    chapters: parsedSnapshots,
                    timelineDuration: max(trackDuration, parsedSnapshots.map { $0.end }.max() ?? 0)
                ))
            }
        }
        try Task.checkCancellation()
        return metadata
    }

    /// Materializes only raw embedded publisher metadata. This gives playback a
    /// durable link/end provenance even if the episode has never been played;
    /// generated sponsor overlays are persisted only in the analysis artifact.
    private func persistEmbeddedPublisherChapters(_ snapshots: [PublisherChapterSnapshot],
                                                  for episode: CDEpisode,
                                                  episodeHash: String) throws -> Bool {
        guard !snapshots.isEmpty else { return false }
        let storedPublisherChapters = (episode.sortedChapters() as? [CDChapter]) ?? []
        guard storedPublisherChapters.isEmpty else { return false }
        guard let databaseManager = DatabaseManager.shared() else {
            throw NSError(
                domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel konnten nicht dauerhaft gespeichert werden.", comment: "")]
            )
        }

        guard let context = databaseManager.objectContext else {
            throw NSError(
                domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel konnten nicht dauerhaft gespeichert werden.", comment: "")]
            )
        }
        var insertedChapters: [CDChapter] = []
        insertedChapters.reserveCapacity(snapshots.count)
        for (index, snapshot) in snapshots.enumerated() {
            guard let chapter = NSEntityDescription.insertNewObject(
                forEntityName: "Chapter",
                into: context
            ) as? CDChapter else {
                for insertedChapter in insertedChapters {
                    context.delete(insertedChapter)
                }
                throw NSError(
                    domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel konnten nicht dauerhaft gespeichert werden.", comment: "")]
                )
            }
            chapter.index = Int32(index)
            chapter.title = snapshot.title
            chapter.timecode = snapshot.start
            chapter.duration = snapshot.end - snapshot.start
            chapter.linkURL = snapshot.linkURL
            episode.addChaptersObject(chapter)
            insertedChapters.append(chapter)
        }

        if let saveError = databaseManager.saveReturningError() {
            for insertedChapter in insertedChapters where insertedChapter.managedObjectContext != nil {
                context.delete(insertedChapter)
            }
            throw NSError(
                domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel konnten nicht dauerhaft gespeichert werden.", comment: ""),
                    NSUnderlyingErrorKey: saveError,
                ]
            )
        }

        ICDiagnosticLogger.shared.logEvent(
            "embedded-publisher-chapters",
            message: "Rohe eingebettete Publisher-Kapitel dauerhaft gespeichert",
            metadata: [
                "episodeHash": episodeHash,
                "chapterCount": snapshots.count,
                "linkCount": snapshots.filter { $0.linkURL != nil }.count,
            ] as NSDictionary
        )
        return true
    }

    private func generatedPublisherTimeline(from publisherChapters: [PublisherChapterSnapshot],
                                            timelineEnd: Double,
                                            episodeTitle: String) throws -> [ICGeneratedChapter] {
        guard let lastPublisherChapter = publisherChapters.last,
              timelineEnd > lastPublisherChapter.start else {
            throw NSError(
                domain: "TranscriptionQueue.PublisherChapters",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Das Ende der vorhandenen Podcast-Kapitel ist unbekannt.", comment: "")]
            )
        }

        var generated: [ICGeneratedChapter] = []
        var cursor = 0.0
        for chapter in publisherChapters {
            guard chapter.start + 0.001 >= cursor,
                  chapter.end > chapter.start,
                  chapter.end <= timelineEnd + 0.001 else {
                throw NSError(
                    domain: "TranscriptionQueue.PublisherChapters",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Vorhandene Podcast-Kapitel haben ungültige Endgrenzen.", comment: "")]
                )
            }
            if cursor < chapter.start {
                generated.append(ICGeneratedChapter(start: cursor,
                                                    end: chapter.start,
                                                    title: episodeTitle,
                                                    isSponsor: false))
            }
            generated.append(ICGeneratedChapter(start: chapter.start,
                                                end: chapter.end,
                                                title: chapter.title,
                                                isSponsor: false))
            cursor = chapter.end
        }
        if cursor < timelineEnd {
            generated.append(ICGeneratedChapter(start: cursor,
                                                end: timelineEnd,
                                                title: episodeTitle,
                                                isSponsor: false))
        }
        return generated
    }

    /// Snapshots publisher chapters on the main actor before an asynchronous
    /// model request. Existing CDChapter stays authoritative; otherwise the raw
    /// embedded media chapters are parsed and durably materialized first.
    private func existingGeneratedChapters(for episodeHash: String,
                                           transcriptStart _: Double,
                                           transcriptEnd: Double,
                                           episodeTitle: String) async throws -> [ICGeneratedChapter]? {
        guard let episode = findEpisode(hash: episodeHash) else { return nil }
        let authoritativeStoredChapters = try storedPublisherChapters(for: episode, transcriptEnd: transcriptEnd)
        if !authoritativeStoredChapters.isEmpty {
            let timelineEnd = max(transcriptEnd,
                                  max(Double(episode.duration), authoritativeStoredChapters.map { $0.end }.max() ?? 0))
            return try generatedPublisherTimeline(from: authoritativeStoredChapters,
                                                  timelineEnd: timelineEnd,
                                                  episodeTitle: episodeTitle)
        }

        let mediaURL = resolveAudioURL(for: episode) ?? episode.preferedMedium()?.fileURL
        guard let mediaURL else {
            ICDiagnosticLogger.shared.logEvent(
                "embedded-publisher-chapters",
                message: "Keine Mediendatei für die Publisher-Kapitelprüfung verfügbar",
                metadata: ["episodeHash": episodeHash] as NSDictionary
            )
            return nil
        }
        let embeddedPublisherMetadata = try await loadEmbeddedPublisherChapters(
            from: mediaURL,
            episodeHash: episodeHash,
            episodeDuration: Double(episode.duration)
        )
        let embeddedPublisherChapters = embeddedPublisherMetadata.chapters
        guard !embeddedPublisherChapters.isEmpty else { return nil }

        // The parser completion resumes on the main actor. Re-check Core Data so
        // playback cannot lose authority if it persisted publisher chapters while
        // the asynchronous metadata request was in flight.
        let publisherChaptersAfterParsing = try storedPublisherChapters(for: episode, transcriptEnd: transcriptEnd)
        if !publisherChaptersAfterParsing.isEmpty {
            let timelineEnd = max(transcriptEnd,
                                  max(Double(episode.duration), publisherChaptersAfterParsing.map { $0.end }.max() ?? 0))
            return try generatedPublisherTimeline(from: publisherChaptersAfterParsing,
                                                  timelineEnd: timelineEnd,
                                                  episodeTitle: episodeTitle)
        }

        let persisted = try persistEmbeddedPublisherChapters(
            embeddedPublisherChapters,
            for: episode,
            episodeHash: episodeHash
        )
        guard persisted else {
            let authoritativeChapters = try storedPublisherChapters(for: episode, transcriptEnd: transcriptEnd)
            guard !authoritativeChapters.isEmpty else {
                throw NSError(
                    domain: "TranscriptionQueue.EmbeddedPublisherChapters",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Eingebettete Medien-Kapitel konnten nicht dauerhaft gespeichert werden.", comment: "")]
                )
            }
            let timelineEnd = max(transcriptEnd,
                                  max(Double(episode.duration), authoritativeChapters.map { $0.end }.max() ?? 0))
            return try generatedPublisherTimeline(from: authoritativeChapters,
                                                  timelineEnd: timelineEnd,
                                                  episodeTitle: episodeTitle)
        }

        let timelineEnd = max(
            embeddedPublisherMetadata.timelineDuration,
            max(transcriptEnd,
                max(Double(episode.duration), embeddedPublisherChapters.map { $0.end }.max() ?? 0))
        )
        return try generatedPublisherTimeline(from: embeddedPublisherChapters,
                                              timelineEnd: timelineEnd,
                                              episodeTitle: episodeTitle)
    }

    private func generateSemanticArtifacts(from cues: [ICTranscriptCue],
                                           musicSegments: [ICAudioSegment]?,
                                           episodeHash: String,
                                           episodeTitle: String,
                                           feedTitle: String,
                                           automaticItem: ICTranscriptionQueueItem?,
                                           status: ((String) -> Void)?,
                                           progress: ((Float, Int, Int) -> Void)?) async throws -> GeneratedSemanticArtifacts {
        let existingChapters = try await existingGeneratedChapters(
            for: episodeHash,
            transcriptStart: cues.first?.start ?? 0,
            transcriptEnd: cues.last?.end ?? 0,
            episodeTitle: episodeTitle
        )
        if let automaticItem {
            try revalidateAutomaticAnalysisImmediatelyBeforeRequest(automaticItem)
        }
        let selectedModel = ICDownloadableModelStore.selectedModel(for: .textToChapters)
        if selectedModel.usesRemoteChapterService {
            let transcriptEnd = cues.last?.end ?? 0
            let musicEnd = musicSegments?.map { $0.end }.max() ?? 0
            let publisherChapterEnd = existingChapters?.map { $0.end }.max() ?? 0
            let mediaDuration = Double(findEpisode(hash: episodeHash)?.duration ?? 0)
            let timelineDuration = max(max(transcriptEnd, musicEnd),
                                       max(publisherChapterEnd, mediaDuration))
            let result = try await chapterGen.analyzeEpisodeAsync(
                fromCues: cues,
                musicSegments: musicSegments,
                existingChapters: existingChapters,
                timelineDuration: timelineDuration,
                status: status,
                progress: progress,
                debugEpisodeHash: episodeHash,
                episodeTitle: episodeTitle,
                feedTitle: feedTitle
            )
            return .analysis(result)
        }

        guard existingChapters == nil else {
            throw NSError(
                domain: "TranscriptionQueue.SemanticAnalysis",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Vorhandene Podcast-Kapitel können nur mit einem Remote-Kapitelmodell um belegte Sponsoren und eine Zusammenfassung ergänzt werden.", comment: "")]
            )
        }
        let chapters = try await chapterGen.generateChaptersAsync(
            fromCues: cues,
            musicSegments: musicSegments,
            status: status,
            progress: progress,
            debugEpisodeHash: episodeHash,
            episodeTitle: episodeTitle,
            feedTitle: feedTitle
        )
        return .chapters(chapters)
    }

    private func verifyAnalysisTranscriptRevision(_ result: EpisodeAnalysisResult,
                                                  episodeHash: String) async throws {
        let persistedCues = try await loadCuesForChapterGeneration(episodeHash: episodeHash)
        guard !persistedCues.isEmpty,
              chapterGen.transcriptRevision(for: persistedCues) == result.transcriptRevision else {
            throw NSError(
                domain: "TranscriptionQueue.AnalysisRevision",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Episodenanalyse verworfen — das gespeicherte Transkript wurde während der Analyse geändert.", comment: "")]
            )
        }
    }

    private func saveSemanticArtifacts(_ artifacts: GeneratedSemanticArtifacts,
                                       for episodeHash: String) async throws {
        switch artifacts {
        case .analysis(let result):
            try await verifyAnalysisTranscriptRevision(result, episodeHash: episodeHash)
            try chapterGen.saveAnalysisResult(result, for: episodeHash)
        case .chapters(let chapters):
            try chapterGen.saveChaptersThrowing(chapters, for: episodeHash)
        }
    }

    private func startChapterGenerationTask(for item: ICTranscriptionQueueItem, startReason: String) {
        let episodeHash = item.episodeHash
        armCrashGuard(for: item)
        beginStep(for: item,
                  status: .generatingChapters,
                  detail: NSLocalizedString("Transkript wird für die Kapitel-Erstellung vorbereitet.", comment: ""))
        postQueueChangeNotification()
        refreshBackgroundContinuation(reason: startReason)

        chapterTask = Task {
            await MainActor.run {
                self.postQueueChangeNotification()
                self.refreshBackgroundContinuation(reason: "chapter-task-started")
            }

            let cues: [ICTranscriptCue]
            do {
                cues = try await self.loadCuesForChapterGeneration(episodeHash: episodeHash)
            } catch {
                let wasCancelled = error is CancellationError || Task.isCancelled
                let detailedError = TranscriptionQueue.detailedErrorMessage(for: error)
                await MainActor.run {
                    self.chapterTask = nil
                    self.clearCrashGuard()
                    if wasCancelled {
                        let pausedForBackground = self.backgroundPausedEpisodeHashes.remove(episodeHash) != nil
                        if !pausedForBackground && item.nextRetryAt == nil {
                            self.items.removeAll { $0 === item }
                        }
                        self.persistQueue()
                    } else {
                        let continuedWithAudio = self.prepareAutomaticTranscriptionAfterUnusableExternalTranscript(
                            item,
                            error: error
                        )
                        if continuedWithAudio {
                            TranscriptionLogger.shared.append(
                                episodeHash: episodeHash,
                                phase: "transcript-import",
                                message: "Podcast-Transkript konnte nicht verwendet werden; Audio-Transkription wird gestartet",
                                detailText: detailedError
                            )
                            self.persistQueue()
                        } else {
                            TranscriptionLogger.shared.append(
                                episodeHash: episodeHash,
                                phase: "error",
                                message: "Podcast-Transkript konnte nicht verwendet werden",
                                detailText: detailedError
                            )
                            if !self.scheduleRetry(for: item, error: error, stage: "transcript-import") {
                                item.status = .failed
                                item.statusDetail = nil
                                item.statusStartedAt = nil
                                item.nextRetryAt = nil
                                item.error = detailedError
                                self.persistQueue()
                            }
                        }
                    }
                    self.postQueueChangeNotification()
                    self.refreshBackgroundContinuation(reason: wasCancelled
                        ? "chapter-task-cancelled-during-transcript-import"
                        : "chapter-task-transcript-import-failed")
                    self.processNext()
                    self.releaseModelIfIdle(reason: "chapter-task-transcript-import-finished")
                }
                return
            }

            // Load cached music timeline if available (no re-analysis needed)
            var musicSegments: [ICAudioSegment]? = nil
            if AudioAnalyzer.shared.hasCachedTimeline(for: episodeHash) {
                // hasCachedTimeline checks the cache, analyze() returns cached result immediately
                // We need a real audio URL for the API, but since cached data exists it won't be used
                if let resolvedURL = self.resolveAudioURL(for: episodeHash) {
                    do {
                        musicSegments = try await AudioAnalyzer.shared.analyzeAsync(audioURL: resolvedURL, episodeHash: episodeHash)
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            await MainActor.run {
                                self.chapterTask = nil
                                self.clearCrashGuard()
                                let pausedForBackground = self.backgroundPausedEpisodeHashes.remove(episodeHash) != nil
                                if !pausedForBackground && item.nextRetryAt == nil {
                                    self.items.removeAll { $0 === item }
                                }
                                self.persistQueue()
                                self.postQueueChangeNotification()
                                self.refreshBackgroundContinuation(reason: "chapter-task-cancelled")
                                self.releaseModelIfIdle(reason: "chapter-task-cancelled")
                            }
                            return
                        }
                        NSLog("[TranscriptionQueue] Cached music timeline load failed: %@", error.localizedDescription)
                        musicSegments = nil
                    }
                }
            }

            NSLog("[TranscriptionQueue] Generating chapters for %@ (%d cues)", episodeHash, cues.count)

            let detailUpdater: (String) -> Void = { detail in
                NotificationCenter.default.post(
                    name: ICTranscriptionInternalStatusDetailNotification,
                    object: nil,
                    userInfo: ["episodeHash": episodeHash, "detail": detail]
                )
            }
            var chapterError: Error? = nil
            let semanticArtifacts: GeneratedSemanticArtifacts?
            do {
                semanticArtifacts = try await self.generateSemanticArtifacts(
                    from: cues,
                    musicSegments: musicSegments,
                    episodeHash: episodeHash,
                    episodeTitle: item.episodeTitle,
                    feedTitle: item.feedTitle,
                    automaticItem: item,
                    status: detailUpdater,
                    progress: { [weak self] progress, chunkIndex, totalChunks in
                        self?.recordProgressSample(for: item,
                                                   progress: progress,
                                                   status: .generatingChapters)
                        self?.postProgressNotification(episodeHash: episodeHash, progress: progress, status: .generatingChapters)
                    }
                )
            } catch {
                semanticArtifacts = nil
                if let runtimeError = error as? AutomaticAnalysisRequestRevalidationError {
                    switch runtimeError {
                    case .processingDisabled, .analysisDisabled:
                        await MainActor.run {
                            self.finishAutomaticChapterTaskAfterRuntimeRevalidation(
                                item,
                                stage: "immediately-before-semantic-request",
                                reason: runtimeError.localizedDescription
                            )
                        }
                        return
                    case .unavailable:
                        chapterError = runtimeError
                    }
                } else {
                    chapterError = error
                    NSLog("[TranscriptionQueue] Chapter generation error: %@", error.localizedDescription)
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    self.chapterTask = nil
                    self.clearCrashGuard()
                    let pausedForBackground = self.backgroundPausedEpisodeHashes.remove(episodeHash) != nil
                    if !pausedForBackground && item.nextRetryAt == nil {
                        self.items.removeAll { $0 === item }
                    }
                    self.persistQueue()
                    self.postQueueChangeNotification()
                    self.refreshBackgroundContinuation(reason: "chapter-task-cancelled-after-generation")
                    self.releaseModelIfIdle(reason: "chapter-task-cancelled-after-generation")
                }
                return
            }

            self.chapterTask = nil
            self.clearCrashGuard()
            var finalError: Error?
            if let semanticArtifacts, !semanticArtifacts.chapters.isEmpty {
                do {
                    try await self.saveSemanticArtifacts(semanticArtifacts, for: episodeHash)
                    item.status = .completed
                    item.progress = 1.0
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.completedAt = Date()
                    item.retryAttempt = 0
                    item.remoteAnalysisReplacementAttempts = 0
                    item.lastCountedRemoteAnalysisJobKey = nil
                    item.lastCountedRemoteAnalysisResponseID = nil
                    item.nextRetryAt = nil
                    NSLog("[TranscriptionQueue] Generated %d chapters", semanticArtifacts.chapters.count)
                    TranscriptionLogger.shared.append(
                        episodeHash: episodeHash,
                        phase: "chapters",
                        message: semanticArtifacts.summaryCharacterCount > 0
                            ? "Episodenanalyse gespeichert"
                            : "Kapitel gespeichert",
                        detailText: "\(semanticArtifacts.chapters.count) Kapitel, \(semanticArtifacts.chapters.filter { $0.isSponsor }.count) Sponsor, \(semanticArtifacts.summaryCharacterCount) Summary-Zeichen"
                    )
                } catch {
                    finalError = error
                }
            } else {
                finalError = chapterError ?? NSError(
                    domain: "ChapterGenerator",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelerkennung fehlgeschlagen.", comment: "")]
                )
            }
            if let finalError,
               !self.scheduleRetry(for: item, error: finalError, stage: "chapter-generation") {
                item.status = .failed
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.nextRetryAt = nil
                item.error = TranscriptionQueue.detailedErrorMessage(for: finalError)
            }
            let committedAnalysisEpisodeHash = item.status == .completed ? episodeHash : nil
            self.persistQueue { error in
                guard error == nil, let committedAnalysisEpisodeHash else { return }
                Task { @MainActor in
                    ChapterGenerator.shared.finalizeOpenAIBackgroundJobAfterPersistedAnalysis(
                        for: committedAnalysisEpisodeHash
                    )
                }
            }
            self.postQueueChangeNotification()
            self.refreshBackgroundContinuation(reason: "chapter-task-finished")
            NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])
            self.scheduleCompletedItemPrune()
            self.processNext()
            self.releaseModelIfIdle(reason: "chapter-task-finished")
        }
    }

    /// Podcasting 2.0 may advertise untimed plain text. It is useful for reading,
    /// but it cannot ground chapter or sponsor boundaries. An automatic analysis
    /// request therefore continues through the already configured audio-
    /// transcription stage instead of activating fabricated timing.
    private func prepareAutomaticTranscriptionAfterUnusableExternalTranscript(
        _ item: ICTranscriptionQueueItem,
        error: Error
    ) -> Bool {
        let failure = error as NSError
        guard item.automaticallyScheduled,
              item.chapterOnly,
              item.shouldGenerateAnalysis,
              failure.domain == "TranscriptionQueue.TranscriptValidation",
              !engine.hasSRT(for: item.episodeHash),
              let episode = findEpisode(hash: item.episodeHash) else {
            return false
        }

        item.chapterOnly = false
        item.audioURL = resolveAudioURL(for: episode)
        item.status = .queued
        item.progress = 0
        item.statusDetail = NSLocalizedString("Podcast-Transkript hat keine verlässlichen Zeitmarken. Die Audiodatei wird transkribiert.", comment: "")
        item.statusStartedAt = nil
        item.error = failure.localizedDescription
        item.nextRetryAt = nil
        TranscriptionLogger.shared.append(
            episodeHash: item.episodeHash,
            phase: "transcript-import",
            message: "Podcast-Transkript ohne verlässliche Zeitmarken",
            detailText: failure.localizedDescription
        )
        ICDiagnosticLogger.shared.logEvent(
            "transcript-import",
            message: "Automatischer Analysejob wechselt zur Audio-Transkription",
            metadata: [
                "episodeHash": item.episodeHash,
                "error": failure.localizedDescription,
            ] as NSDictionary
        )
        return true
    }

    @objc(hasChapterGenerationTranscriptWithEpisodeHash:)
    func hasChapterGenerationTranscript(episodeHash: String) -> Bool {
        hasChapterGenerationTranscript(episodeHash: episodeHash, knownEpisode: nil)
    }

    private func hasChapterGenerationTranscript(episodeHash: String,
                                                knownEpisode: CDEpisode?) -> Bool {
        if engine.hasSRT(for: episodeHash) {
            return true
        }
        guard let episode = knownEpisode ?? findEpisode(hash: episodeHash) else {
            return false
        }
        return chapterGenerationTranscriptDescriptors(for: episode).contains {
            !transcriptURLAttemptStrings(for: $0, episode: episode).isEmpty
        }
    }

    private func loadCuesForChapterGeneration(episodeHash: String) async throws -> [ICTranscriptCue] {
        let srtURL = TranscriptionEngine.shared.srtURL(for: episodeHash)
        if FileManager.default.fileExists(atPath: srtURL.path) {
            let cues = loadCuesFromSRT(url: srtURL)
            guard !cues.isEmpty else {
                throw NSError(
                    domain: "TranscriptionQueue.TranscriptValidation",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Das gespeicherte Transkript enthält keine gültigen Zeitmarken.", comment: "")]
                )
            }
            return cues
        }

        guard let episode = findEpisode(hash: episodeHash) else {
            throw NSError(
                domain: "TranscriptionQueue.TranscriptValidation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Episode für das Podcast-Transkript wurde nicht gefunden.", comment: "")]
            )
        }

        var lastError: Error?
        var lastTransientError: Error?
        for descriptor in chapterGenerationTranscriptDescriptors(for: episode) {
            for urlString in transcriptURLAttemptStrings(for: descriptor, episode: episode) {
                guard let url = URL(string: urlString), url.scheme != nil else { continue }
                do {
                    let loaded = try await loadPodcastTranscriptData(from: url, episode: episode)
                    let descriptorForParsing = descriptor.merging(["resolvedURL": urlString]) { _, new in new }
                    let cues = parseTranscriptData(loaded.data, descriptor: descriptorForParsing, response: loaded.response)
                    guard !cues.isEmpty else {
                        throw NSError(
                            domain: "TranscriptionQueue.TranscriptValidation",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Podcast-Transkript enthält keine verlässlichen Zeitmarken und kann nicht für Kapitelgrenzen verwendet werden.", comment: "")]
                        )
                    }
                    try engine.saveImportedTranscriptCues(cues, for: episodeHash)
                    let persistedCues = loadCuesFromSRT(url: srtURL)
                    guard !persistedCues.isEmpty else {
                        throw NSError(
                            domain: "TranscriptionQueue.TranscriptValidation",
                            code: 4,
                            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Zeitcodiertes Podcast-Transkript konnte nicht stabil gespeichert werden.", comment: "")]
                        )
                    }
                    return persistedCues
                } catch {
                    lastError = error
                    if Self.isTransientPipelineError(error) {
                        lastTransientError = error
                    }
                }
            }
        }
        throw lastTransientError ?? lastError ?? NSError(
            domain: "TranscriptionQueue.TranscriptValidation",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kein verwendbares zeitcodiertes Podcast-Transkript gefunden.", comment: "")]
        )
    }

    /// Parse SRT file into transcript cues
    private func loadCuesFromSRT(url: URL) -> [ICTranscriptCue] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseArrowTimedTranscript(content)
    }

    private func parseSRTTime(_ str: String) -> Double {
        let cleaned = str.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty else { return -1 }
        if cleaned.hasSuffix("ms") {
            guard let value = Double(cleaned.dropLast(2)) else { return -1 }
            return value / 1000.0
        }
        if cleaned.hasSuffix("s") && !cleaned.contains(":") {
            return Double(cleaned.dropLast()) ?? -1
        }
        if cleaned.hasSuffix("m") && !cleaned.contains(":") {
            guard let value = Double(cleaned.dropLast()) else { return -1 }
            return value * 60.0
        }
        if cleaned.hasSuffix("h") && !cleaned.contains(":") {
            guard let value = Double(cleaned.dropLast()) else { return -1 }
            return value * 3600.0
        }

        let parts = cleaned.components(separatedBy: ":")
        if parts.count == 1 {
            return Double(parts[0]) ?? -1
        }

        var seconds = 0.0
        var factor = 1.0
        for part in parts.reversed() {
            guard let value = Double(part) else { return -1 }
            seconds += value * factor
            factor *= 60.0
        }
        return seconds
    }

    private func chapterGenerationTranscriptDescriptors(for episode: CDEpisode) -> [[String: String]] {
        guard let rawSources = episode.transcripts as? [[String: Any]] else { return [] }
        return rawSources.compactMap { source in
            guard let url = source["url"] as? String,
                  !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            var descriptor = ["url": url]
            for key in ["type", "language", "rel", "title", "fallbackURL", "href"] {
                if let value = source[key] as? String, !value.isEmpty {
                    descriptor[key] = value
                }
            }
            return descriptor
        }
    }

    private func transcriptURLAttemptStrings(for descriptor: [String: String], episode: CDEpisode) -> [String] {
        var attempts: [String] = []
        var seen: Set<String> = []
        appendTranscriptURLAttempt(descriptor["url"], episode: episode, attempts: &attempts, seen: &seen)
        appendTranscriptURLAttempt(descriptor["fallbackURL"], episode: episode, attempts: &attempts, seen: &seen)
        appendTranscriptURLAttempt(descriptor["href"], episode: episode, attempts: &attempts, seen: &seen)
        return attempts
    }

    private func appendTranscriptURLAttempt(_ rawValue: String?,
                                            episode: CDEpisode,
                                            attempts: inout [String],
                                            seen: inout Set<String>) {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return
        }

        func add(_ value: String) {
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil,
                  !seen.contains(value) else { return }
            seen.insert(value)
            attempts.append(value)
        }

        if trimmed.hasPrefix("//") {
            var schemes: [String] = []
            for baseURL in [episode.feed?.sourceURL, episode.feed?.linkURL] {
                guard let scheme = baseURL?.scheme?.lowercased(),
                      (scheme == "http" || scheme == "https"),
                      !schemes.contains(scheme) else { continue }
                schemes.append(scheme)
            }
            if !schemes.contains("https") {
                schemes.append("https")
            }
            if !schemes.contains("http") {
                schemes.append("http")
            }
            for scheme in schemes {
                add("\(scheme):\(trimmed)")
            }
            return
        }

        if let directURL = URL(string: trimmed), directURL.scheme != nil {
            add(directURL.absoluteString)
            return
        }

        var addedResolvedURL = false
        if let sourceURL = episode.feed?.sourceURL,
           let resolved = URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL {
            add(resolved.absoluteString)
            addedResolvedURL = true
        }
        if let linkURL = episode.feed?.linkURL,
           let resolved = URL(string: trimmed, relativeTo: linkURL)?.absoluteURL {
            add(resolved.absoluteString)
            addedResolvedURL = true
        }
        if !addedResolvedURL, let directURL = URL(string: trimmed), directURL.scheme != nil {
            add(directURL.absoluteString)
        }
    }

    private func loadPodcastTranscriptData(from url: URL,
                                           episode: CDEpisode) async throws -> (data: Data, response: URLResponse?) {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            throw URLError(.unsupportedURL)
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30.0)
        request.setValue(
            "text/vtt,application/x-subrip,text/plain,application/json,application/ttml+xml,text/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if podcastTranscriptMayUseFeedCredentials(url, episode: episode),
           let username = episode.feed?.username, !username.isEmpty,
           let password = episode.feed?.password, !password.isEmpty,
           let credentials = "\(username):\(password)".data(using: .utf8) {
            request.setValue("Basic \(credentials.base64EncodedString())",
                             forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw NSError(
                    domain: "TranscriptionQueue.TranscriptHTTP",
                    code: httpResponse.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            format: NSLocalizedString("Podcast-Transkript konnte nicht geladen werden. HTTP %d", comment: ""),
                            httpResponse.statusCode
                        ),
                        "HTTPStatusCode": httpResponse.statusCode,
                    ]
                )
            }
            guard data.count <= Self.maximumPodcastTranscriptBytes else {
                throw NSError(
                    domain: "TranscriptionQueue.TranscriptValidation",
                    code: 10,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Podcast-Transkript überschreitet die zulässige Downloadgröße.", comment: "")]
                )
            }
            guard !data.isEmpty else {
                throw NSError(
                    domain: "TranscriptionQueue.TranscriptValidation",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Podcast-Transkript ist leer.", comment: "")]
                )
            }
            ICDiagnosticLogger.shared.logEvent(
                "transcript-import",
                message: "Podcast-Transkript geladen",
                metadata: [
                    "host": url.host ?? "",
                    "statusCode": httpResponse.statusCode,
                    "bytes": data.count,
                ] as NSDictionary
            )
            return (data, response)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ICDiagnosticLogger.shared.logEvent(
                "transcript-import",
                message: "Podcast-Transkriptabruf fehlgeschlagen",
                metadata: [
                    "host": url.host ?? "",
                    "error": Self.detailedErrorMessage(for: error),
                ] as NSDictionary
            )
            throw error
        }
    }

    private func podcastTranscriptMayUseFeedCredentials(_ url: URL, episode: CDEpisode) -> Bool {
        guard let feedURL = episode.feed?.sourceURL else { return false }
        return originTuple(for: url) == originTuple(for: feedURL)
    }

    private func originTuple(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : -1))
        guard port > 0 else { return nil }
        return "\(scheme)|\(host)|\(port)"
    }

    private func parseTranscriptData(_ data: Data, descriptor: [String: String], response: URLResponse?) -> [ICTranscriptCue] {
        let descriptorType = descriptor["type"]?.lowercased() ?? ""
        let mimeType = response?.mimeType?.lowercased() ?? ""
        let urlString = descriptor["resolvedURL"] ?? descriptor["url"] ?? ""
        let urlExtension = URL(string: urlString)?.pathExtension.lowercased() ?? ""

        let maybeJSON = transcriptType(descriptorType, contains: "json") || transcriptType(mimeType, contains: "json") || urlExtension == "json"
        if maybeJSON {
            let jsonCues = parseTranscriptJSON(data)
            if !jsonCues.isEmpty {
                return jsonCues
            }
        }

        guard let text = decodedTranscriptString(from: data), !text.isEmpty else {
            return []
        }

        let maybeTTML = transcriptType(descriptorType, contains: "ttml") ||
            transcriptType(mimeType, contains: "ttml") ||
            urlExtension == "ttml" ||
            urlExtension == "dfxp" ||
            transcriptType(descriptorType, contains: "xml")
        if maybeTTML || text.range(of: "<tt", options: .caseInsensitive) != nil {
            let ttmlCues = parseTTMLTranscript(text)
            if !ttmlCues.isEmpty {
                return ttmlCues
            }
        }

        if urlExtension == "lrc" {
            let lrcCues = parseLRCTranscript(text)
            if !lrcCues.isEmpty {
                return lrcCues
            }
        }

        let timedTextCues = parseArrowTimedTranscript(text)
        if !timedTextCues.isEmpty {
            return timedTextCues
        }

        let lrcCues = parseLRCTranscript(text)
        if !lrcCues.isEmpty {
            return lrcCues
        }

        let jsonCues = parseTranscriptJSON(data)
        if !jsonCues.isEmpty {
            return jsonCues
        }

        return []
    }

    private func decodedTranscriptString(from data: Data) -> String? {
        let encodings: [String.Encoding] = [.utf8, .unicode, .utf16LittleEndian, .utf16BigEndian, .isoLatin1]
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private func parseArrowTimedTranscript(_ text: String) -> [ICTranscriptCue] {
        let rawLines = text.components(separatedBy: .newlines)
        var cues: [ICTranscriptCue] = []
        var index = 0

        while index < rawLines.count {
            var line = rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("WEBVTT") || line.hasPrefix("NOTE") {
                index += 1
                continue
            }

            if !line.contains("-->") {
                if index + 1 < rawLines.count {
                    let maybeTimeLine = rawLines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                    if maybeTimeLine.contains("-->") {
                        line = maybeTimeLine
                        index += 1
                    } else {
                        index += 1
                        continue
                    }
                } else {
                    break
                }
            }

            let parts = line.components(separatedBy: "-->")
            guard parts.count >= 2 else {
                index += 1
                continue
            }
            let startString = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let endString = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .first ?? ""
            let start = parseSRTTime(startString)
            let end = parseSRTTime(endString)
            index += 1

            var lineParts: [String] = []
            while index < rawLines.count {
                let cueLine = rawLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if cueLine.isEmpty {
                    index += 1
                    break
                }
                lineParts.append(cueLine)
                index += 1
            }

            let cueText = stripTranscriptHTML(lineParts.joined(separator: "\n"))
            if !cueText.isEmpty {
                cues.append(ICTranscriptCue(start: start, end: end, text: cueText))
            }
        }

        return normalizeTranscriptCues(cues)
    }

    private func parseLRCTranscript(_ text: String) -> [ICTranscriptCue] {
        guard let regex = try? NSRegularExpression(pattern: "\\[(\\d{1,2}:\\d{2}(?:[\\.:]\\d{1,3})?)\\]") else {
            return []
        }
        var cues: [ICTranscriptCue] = []
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = regex.matches(in: line, options: [], range: range)
            guard !matches.isEmpty else { continue }
            let cueText = stripTranscriptHTML(regex.stringByReplacingMatches(in: line, options: [], range: range, withTemplate: ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cueText.isEmpty else { continue }
            for match in matches {
                guard let timeRange = Range(match.range(at: 1), in: line) else { continue }
                cues.append(ICTranscriptCue(start: parseSRTTime(String(line[timeRange])), end: 0, text: cueText))
            }
        }
        return normalizeTranscriptCues(cues)
    }

    private func parseTTMLTranscript(_ text: String) -> [ICTranscriptCue] {
        guard let regex = try? NSRegularExpression(pattern: "<p\\b([^>]*)>(.*?)</p>",
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        var cues: [ICTranscriptCue] = []
        for match in matches {
            guard let attrsRange = Range(match.range(at: 1), in: text),
                  let innerRange = Range(match.range(at: 2), in: text) else {
                continue
            }
            let attrs = String(text[attrsRange])
            let inner = String(text[innerRange])
            let start = parseSRTTime(xmlAttribute("begin", in: attrs) ?? "")
            var end = parseSRTTime(xmlAttribute("end", in: attrs) ?? "")
            if !(end > start), let durationString = xmlAttribute("dur", in: attrs) {
                let duration = parseSRTTime(durationString)
                if duration > 0 {
                    end = start + duration
                }
            }
            let cueText = stripTranscriptHTML(inner.replacingOccurrences(of: "<br/>", with: "\n")
                .replacingOccurrences(of: "<br />", with: "\n"))
            if !cueText.isEmpty {
                cues.append(ICTranscriptCue(start: start, end: end, text: cueText))
            }
        }
        return normalizeTranscriptCues(cues)
    }

    private func xmlAttribute(_ key: String, in attributes: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\(NSRegularExpression.escapedPattern(for: key))\\s*=\\s*['\\\"]([^'\\\"]+)['\\\"]",
                                                   options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)
        guard let match = regex.firstMatch(in: attributes, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: attributes) else {
            return nil
        }
        return String(attributes[valueRange])
    }

    private func parseTranscriptJSON(_ data: Data) -> [ICTranscriptCue] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        var cues: [ICTranscriptCue] = []
        collectJSONCues(object, into: &cues)
        return normalizeTranscriptCues(cues)
    }

    private func collectJSONCues(_ object: Any, into cues: inout [ICTranscriptCue]) {
        if let array = object as? [Any] {
            for entry in array {
                collectJSONCues(entry, into: &cues)
            }
            return
        }

        guard let dict = object as? [String: Any] else {
            return
        }

        let startKeys = ["start", "startTime", "start_time", "begin", "from", "t"]
        let endKeys = ["end", "endTime", "end_time", "to", "until"]
        let durationKeys = ["duration", "dur", "d"]
        let start = firstTranscriptTimeValue(in: dict, keys: startKeys)
        var end = firstTranscriptTimeValue(in: dict, keys: endKeys)
        let duration = firstTranscriptTimeValue(in: dict, keys: durationKeys)
        if start >= 0, !(end > start), duration > 0 {
            end = start + duration
        }

        if start >= 0,
           let text = firstTranscriptTextValue(in: dict),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cues.append(ICTranscriptCue(start: start, end: end, text: stripTranscriptHTML(text)))
        }

        for value in dict.values {
            collectJSONCues(value, into: &cues)
        }
    }

    private func firstTranscriptTimeValue(in dict: [String: Any], keys: [String]) -> Double {
        for key in keys {
            if let number = dict[key] as? NSNumber {
                return number.doubleValue
            }
            if let string = dict[key] as? String {
                return parseSRTTime(string)
            }
        }
        return -1
    }

    private func firstTranscriptTextValue(in dict: [String: Any]) -> String? {
        for key in ["text", "value", "line", "cue", "utterance", "transcript"] {
            if let value = dict[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizeTranscriptCues(_ cues: [ICTranscriptCue]) -> [ICTranscriptCue] {
        guard !cues.isEmpty else { return [] }
        let sorted = cues.sorted { $0.start < $1.start }
        var normalized: [ICTranscriptCue] = []
        var previousEnd = -Double.infinity
        var rejectedCueCount = 0
        for cue in sorted {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  cue.start.isFinite,
                  cue.end.isFinite,
                  cue.start >= 0,
                  cue.end > cue.start,
                  cue.start >= previousEnd - 0.001 else {
                rejectedCueCount += 1
                continue
            }
            normalized.append(ICTranscriptCue(start: cue.start, end: cue.end, text: text))
            previousEnd = cue.end
        }
        if rejectedCueCount > 0 {
            NSLog("[TranscriptionQueue] Podcast transcript cues normalized: rejected=%d input=%d output=%d",
                  rejectedCueCount, cues.count, normalized.count)
            ICDiagnosticLogger.shared.logEvent(
                "transcript-import",
                message: "Podcast transcript cues normalized",
                metadata: [
                    "rejectedCueCount": rejectedCueCount,
                    "inputCueCount": cues.count,
                    "outputCueCount": normalized.count,
                ] as NSDictionary
            )
        }
        return normalized
    }

    private func stripTranscriptHTML(_ text: String) -> String {
        var stripped = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&nbsp;": " ",
        ]
        for (entity, replacement) in entities {
            stripped = stripped.replacingOccurrences(of: entity, with: replacement)
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptType(_ value: String, contains token: String) -> Bool {
        value.range(of: token, options: .caseInsensitive) != nil
    }

    /// Reorder queue items (for drag & drop in UI).
    @objc func reorderItems(_ newOrder: [ICTranscriptionQueueItem]) {
        items = newOrder
        persistQueue()
    }

    /// Resume processing (called on app launch or foreground).
    @objc func resumeIfNeeded() {
        guard ICAITranscriptionFeaturesAvailable() else { return }
        ServerTranscriptionManager.shared.resumeIfNeeded()
        guard reconcilePendingCacheDeletionsIfReady() else { return }
        recoverOrphanedAutomaticCheckpoints()
        chapterGen.resumePendingOpenAIBackgroundCancellations()
        guard !items.isEmpty else { return }

        if isProcessing && currentTask == nil {
            NSLog("[TranscriptionQueue] Resetting stuck isProcessing flag")
            isProcessing = false
        }

        guard !isProcessing else {
            ICDiagnosticLogger.shared.logEvent("queue", message: "resumeIfNeeded übersprungen (aktiver Lauf lebt noch)", metadata: [
                "queueCount": items.count,
            ] as NSDictionary)
            return
        }
        guard chapterTask == nil else {
            ICDiagnosticLogger.shared.logEvent("queue", message: "resumeIfNeeded übersprungen (Kapitelerstellung läuft)", metadata: [
                "queueCount": items.count,
            ] as NSDictionary)
            return
        }

        if UserDefaults.standard.bool(forKey: TranscriptionQueue.crashGuardKey) {
            let previousEndedUnexpectedly = ICDiagnosticLogger.shared.previousSessionEndedUnexpectedly
            let guardedEpisodeHash = UserDefaults.standard.string(forKey: Self.crashGuardEpisodeHashKey)
            let guardedItem = guardedEpisodeHash.flatMap { hash in
                items.first(where: { $0.episodeHash == hash })
            } ?? items.first(where: { Self.crashGuardProtectedStatuses.contains($0.status) })
            let shouldQuarantineGuardedItem = guardedItem.map {
                !canAutoResumeRemoteChapterJobAfterUnexpectedTermination($0)
            } ?? false
            if previousEndedUnexpectedly || shouldQuarantineGuardedItem,
               let item = guardedItem {
                NSLog("[TranscriptionQueue] Crash guard active — last run was killed before completing")
                ICDiagnosticLogger.shared.logEvent("queue", message: "Crash-Guard aktiv", metadata: [
                    "queueCount": items.count,
                    "previousSessionState": ICDiagnosticLogger.shared.previousSessionState ?? "",
                    "previousEndedUnexpectedly": previousEndedUnexpectedly,
                    "guardedEpisodeHash": item.episodeHash,
                    "canAutoResume": canAutoResumeRemoteChapterJobAfterUnexpectedTermination(item),
                ] as NSDictionary)
                let interruptedMessage = NSLocalizedString("Unterbrochen. Tippe zum Fortsetzen.", comment: "")
                var didMarkInterruptedItem = false
                var didPrepareAutoResumeItem = false
                if canAutoResumeRemoteChapterJobAfterUnexpectedTermination(item) {
                    item.status = .queued
                    item.progress = 0
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.error = nil
                    item.requiresExplicitRetryAfterCrash = false
                    if item.automaticallyScheduled {
                        let interruption = self.backgroundInterruptionError(
                            reason: NSLocalizedString("Vorheriger automatischer Durchlauf wurde unterbrochen.", comment: "")
                        )
                        _ = self.scheduleRetry(for: item, error: interruption, stage: "crash-recovery")
                    }
                    didPrepareAutoResumeItem = true
                    ICDiagnosticLogger.shared.logEvent("queue",
                                                       message: "Crash-Guard: Cloud-Kapiteljob wird automatisch fortgesetzt",
                                                       metadata: [
                                                        "episodeHash": item.episodeHash,
                                                        "automaticallyScheduled": item.automaticallyScheduled,
                                                        "checkpointExists": self.engine.hasCheckpoint(for: item.episodeHash),
                                                       ] as NSDictionary)
                } else {
                    let alreadyMarkedInterrupted = item.requiresExplicitRetryAfterCrash && item.error == interruptedMessage
                    if !alreadyMarkedInterrupted {
                        TranscriptionLogger.shared.append(episodeHash: item.episodeHash, phase: "error",
                                                          message: "Vorheriger Durchlauf wurde abgebrochen (App-Beendigung oder Crash)", detailText: nil)
                        didMarkInterruptedItem = true
                    }
                    item.status = .queued
                    item.progress = 0
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.error = interruptedMessage
                    item.completedAt = nil
                    item.nextRetryAt = nil
                    item.requiresExplicitRetryAfterCrash = true
                }
                if didMarkInterruptedItem || didPrepareAutoResumeItem {
                    persistQueue()
                }
                postQueueChangeNotification()
                clearCrashGuard()
                ICDiagnosticLogger.shared.logEvent("queue",
                                                   message: "Crash-Guard ausgewertet; automatische Jobs bleiben fortsetzbar",
                                                   metadata: [
                                                    "queueCount": items.count,
                                                    "autoResumableRemoteChapterItems": didPrepareAutoResumeItem ? 1 : 0,
                                                    "manualRetryItems": item.requiresExplicitRetryAfterCrash ? 1 : 0,
                                                   ] as NSDictionary)
            } else {
                clearCrashGuard()
                ICDiagnosticLogger.shared.logEvent("queue", message: "Crash-Guard nach erwartetem Lifecycle-Ende ignoriert", metadata: [
                    "queueCount": items.count,
                    "previousSessionState": ICDiagnosticLogger.shared.previousSessionState ?? "",
                ] as NSDictionary)
            }
        }

        // Reset any stuck items back to queued
        for item in items {
            if item.status == .transcribing || item.status == .analyzingMusic || item.status == .downloadingModel || item.status == .generatingChapters {
                NSLog("[TranscriptionQueue] Resetting stuck item %@ from status %ld to queued", item.episodeHash, item.status.rawValue)
                item.status = .queued
                item.progress = 0
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.error = nil
            }
            if engine.hasCheckpoint(for: item.episodeHash) {
                NSLog("[TranscriptionQueue] Found interrupted transcription for %@, resuming", item.episodeHash)
                item.status = .queued
            }
        }

        processNext()
    }

    private func recoverOrphanedAutomaticCheckpoints() {
        let directory = engine.transcriptCacheDirectory()
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let checkpointSuffix = "_checkpoint.json"
        var recoveredItems: [ICTranscriptionQueueItem] = []
        for checkpointURL in fileURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let fileName = checkpointURL.lastPathComponent
            guard fileName.hasSuffix(checkpointSuffix) else { continue }
            let episodeHash = String(fileName.dropLast(checkpointSuffix.count))
            guard !episodeHash.isEmpty,
                  !items.contains(where: { $0.episodeHash == episodeHash }),
                  !engine.hasSRT(for: episodeHash),
                  engine.hasCheckpoint(for: episodeHash),
                  let episode = findEpisode(hash: episodeHash),
                  let decision = automaticProcessingDecision(for: episode),
                  decision.transcribe || decision.analyze else {
                continue
            }

            let enqueued = enqueueJob(
                episodeHash: episodeHash,
                episodeTitle: episode.title ?? episodeHash,
                feedTitle: episode.feed?.title ?? "",
                audioURL: resolveAudioURL(for: episode),
                language: episode.feed?.language,
                chapterOnly: false,
                automaticallyScheduled: true,
                shouldGenerateAnalysis: decision.analyze,
                knownEpisode: episode,
                startImmediately: false
            )
            guard enqueued,
                  let item = items.first(where: { $0.episodeHash == episodeHash }) else { continue }
            recoveredItems.append(item)

            TranscriptionLogger.shared.append(
                episodeHash: episodeHash,
                phase: "recovery",
                message: "Verwaisten Transkriptions-Checkpoint wiederhergestellt",
                detailText: "autoTranscribe=\(decision.transcribe), autoAnalysis=\(decision.analyze)"
            )
            ICDiagnosticLogger.shared.logEvent(
                "orphan-checkpoint-recovery",
                message: "Konfigurierten automatischen Job aus Checkpoint wiederhergestellt",
                metadata: [
                    "episodeHash": episodeHash,
                    "checkpointPath": checkpointURL.path,
                    "autoTranscribe": decision.transcribe,
                    "autoAnalysis": decision.analyze,
                ] as NSDictionary
            )
        }

        guard !recoveredItems.isEmpty else { return }
        clearCrashGuard()
        for item in recoveredItems {
            _ = scheduleRetry(
                for: item,
                error: backgroundInterruptionError(
                    reason: NSLocalizedString("Automatischer Lauf wurde vor dem Speichern der Warteschlange unterbrochen.", comment: "")
                ),
                stage: "orphan-checkpoint-recovery"
            )
        }
    }

    /// Manual retry from queue UI. Clears crash guard and starts processing.
    @objc func retryProcessing() {
        clearCrashGuard()
        guard !isProcessing else { return }
        for item in items where item.status == .queued {
            item.requiresExplicitRetryAfterCrash = false
            item.error = nil
            item.statusDetail = nil
            item.statusStartedAt = nil
            item.retryAttempt = 0
            item.remoteAnalysisReplacementAttempts = 0
            item.lastCountedRemoteAnalysisJobKey = nil
            item.lastCountedRemoteAnalysisResponseID = nil
            item.nextRetryAt = nil
            engine.resetCheckpointFailureCounter(for: item.episodeHash)
        }
        processNext()
    }

    @objc func retry(episodeHash: String) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash }) else { return }
        guard item.status == .failed || item.status == .queued else { return }

        clearCrashGuard()
        backgroundPausedEpisodeHashes.remove(episodeHash)
        let shouldPreserveTranscriptCheckpoint = !item.chapterOnly
            && !engine.hasSRT(for: episodeHash)
            && engine.hasCheckpoint(for: episodeHash)
        if !shouldPreserveTranscriptCheckpoint {
            cleanupBrokenArtifacts(for: item)
        }
        engine.resetCheckpointFailureCounter(for: episodeHash)
        if item.chapterOnly || engine.hasSRT(for: episodeHash) {
            item.chapterOnly = true
            item.audioURL = nil
        } else {
            item.chapterOnly = false
        }
        item.status = .queued
        item.requiresExplicitRetryAfterCrash = false
        item.progress = 0
        item.progressBaseline = 0
        item.progressBaselineStartedAt = nil
        item.error = nil
        item.statusDetail = nil
        item.statusStartedAt = nil
        item.completedAt = nil
        item.retryAttempt = 0
        item.remoteAnalysisReplacementAttempts = 0
        item.lastCountedRemoteAnalysisJobKey = nil
        item.lastCountedRemoteAnalysisResponseID = nil
        item.nextRetryAt = nil
        persistQueue { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                guard error == nil else {
                    ICDiagnosticLogger.shared.logEvent(
                        "openai-background-response",
                        message: "Expliziter Retry wartet auf erfolgreiche Queue-Persistenz",
                        metadata: [
                            "episodeHash": episodeHash,
                            "error": error?.localizedDescription ?? "",
                        ] as NSDictionary
                    )
                    return
                }
                ChapterGenerator.shared.prepareOpenAIBackgroundJobForExplicitRetry(for: episodeHash)
                if !self.isProcessing {
                    self.processNext()
                }
            }
        }
        postQueueChangeNotification()
    }

    private func cleanupBrokenArtifacts(for item: ICTranscriptionQueueItem) {
        cleanupBrokenArtifacts(episodeHash: item.episodeHash,
                               chapterOnly: item.chapterOnly || engine.hasSRT(for: item.episodeHash))
    }

    private func cleanupBrokenArtifacts(episodeHash: String) {
        cleanupBrokenArtifacts(episodeHash: episodeHash,
                               chapterOnly: engine.hasSRT(for: episodeHash))
    }

    private func cleanupBrokenArtifacts(episodeHash: String, chapterOnly: Bool) {
        if chapterOnly {
            ChapterGenerator.shared.invalidateChaptersCache(for: episodeHash)
            return
        }
        engine.removeSRT(for: episodeHash)
    }

    /// Number of items currently queued (including active)
    @objc var count: Int { items.count }

    @objc var activeItemCount: Int {
        displayItems.filter { $0.status != .completed && $0.status != .failed }.count
    }

    @objc(modelMutationBlockReasonForRole:)
    func modelMutationBlockReason(for role: ICDownloadableModelRole) -> String? {
        let blocksRole = items.contains { item in
            guard item.status != .completed && item.status != .failed else { return false }
            switch role {
            case .voiceToText:
                return !item.chapterOnly && (
                    item.status == .queued ||
                    item.status == .analyzingMusic ||
                    item.status == .downloadingModel ||
                    item.status == .transcribing
                )
            case .textToChapters:
                return item.chapterOnly ||
                    item.status == .queued ||
                    item.status == .analyzingMusic ||
                    item.status == .downloadingModel ||
                    item.status == .transcribing ||
                    item.status == .generatingChapters
            @unknown default:
                return false
            }
        }
        guard blocksRole else { return nil }
        return NSLocalizedString("Ein laufender Transkriptions- oder Kapitel-Job verwendet diesen Modellbereich. Beende oder brich den Job ab, bevor du das Modell änderst.", comment: "")
    }

    @objc(modelDeletionBlockReasonForModel:)
    func modelDeletionBlockReason(for model: ICDownloadableModel) -> String? {
        guard model.requiresDownload else { return nil }
        return modelMutationBlockReason(for: model.role)
    }

    /// Drives the sidebar entry. Must cover both queues — with server-only work the
    /// entry used to stay hidden, which made the queue (and its errors) unreachable.
    @objc var hasVisibleItems: Bool {
        pruneExpiredCompletedItems()
        ServerTranscriptionManager.shared.pruneExpiredCompletedItems()
        return !displayItems.isEmpty
    }

    /// Currently processing item
    @objc var currentItem: ICTranscriptionQueueItem? {
        items.first { $0.status != .completed && $0.status != .failed && $0.status != .queued }
            ?? items.first {
                $0.status == .queued &&
                    !$0.requiresExplicitRetryAfterCrash &&
                    ($0.nextRetryAt == nil || $0.nextRetryAt! <= Date()) &&
                    !($0.chapterOnly
                        ? shouldPauseChapterOnlyForBackground
                        : shouldPauseTranscriptionForBackground)
            }
    }

    private func earliestAutomaticRetryDate(now: Date = Date()) -> Date? {
        let queued = items.filter { $0.automaticallyScheduled && $0.status == .queued }
        guard !queued.isEmpty else { return nil }
        if queued.contains(where: { $0.nextRetryAt == nil || $0.nextRetryAt! <= now }) {
            return nil
        }
        return queued.compactMap(\.nextRetryAt).min()
    }

    private func earliestAutomaticBackgroundWorkDate(now: Date = Date()) -> Date? {
        var candidates: [Date] = []
        let automaticItems = items.filter {
            $0.automaticallyScheduled && $0.status == .queued
        }
        if !automaticItems.isEmpty {
            candidates.append(earliestAutomaticRetryDate(now: now) ?? now)
        }
        if let serverWorkDate = ServerTranscriptionManager.shared.earliestAutomaticWorkDate {
            candidates.append(serverWorkDate)
        }
        if let cancellationRetryDate = chapterGen.earliestOpenAIBackgroundCancellationRetryDate {
            candidates.append(cancellationRetryDate)
        }
        return candidates.min()
    }

    /// BGTaskScheduler is opportunistic and does not wake an app that remains
    /// active. Keep one cancellable in-process wake for the earliest durable retry.
    private func scheduleRetryWakeIfNeeded(now: Date = Date()) {
        retryWakeTask?.cancel()
        retryWakeTask = nil

        guard let retryDate = earliestAutomaticRetryDate(now: now) else { return }
        let delay = max(0, retryDate.timeIntervalSince(now))
        retryWakeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.retryWakeTask = nil
            ICDiagnosticLogger.shared.logEvent("automatic-retry", message: "Persistenter Wiederholungszeitpunkt erreicht", metadata: [
                "retryAt": Self.debugTimestampString(retryDate),
                "queueCount": self.items.count,
            ] as NSDictionary)
            self.processNext()
        }
    }

    private func scheduleAutomaticBackgroundProcessing(earliestBeginDate: Date?) {
        guard ICAITranscriptionFeaturesAvailable() else { return }
        let automaticItems = items.filter {
            $0.automaticallyScheduled && $0.status == .queued
        }
        let hasCancellationWork = chapterGen.hasPendingOpenAIBackgroundCancellationWork
        let serverAutomaticItems = ServerTranscriptionManager.shared.items.filter {
            $0.automaticallyScheduled && $0.status != .completed && $0.status != .failed
        }
        guard !automaticItems.isEmpty || !serverAutomaticItems.isEmpty || hasCancellationWork else { return }
        if let continuedPath = UserDefaults.standard.string(forKey: "ICTranscriptionActiveContinuedPath"),
           continuedPath.hasPrefix("continued-") {
            ICDiagnosticLogger.shared.logEvent(
                "background-task",
                message: "Automatischer BGProcessingTask wartet auf sichtbaren Continued-Lauf",
                metadata: [
                    "continuedPath": continuedPath,
                    "automaticQueueCount": automaticItems.count,
                ] as NSDictionary
            )
            return
        }

        let request = BGProcessingTaskRequest(identifier: Self.automaticProcessingTaskIdentifier)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = hasCancellationWork || automaticItems.contains { item in
            item.chapterOnly ||
                item.audioURL == nil ||
                (item.shouldGenerateAnalysis && ICDownloadableModelStore.selectedModel(for: .textToChapters).usesRemoteChapterService)
        } || !serverAutomaticItems.isEmpty
        request.earliestBeginDate = [earliestBeginDate, earliestAutomaticBackgroundWorkDate()]
            .compactMap { $0 }
            .min() ?? Date()

        do {
            try BGTaskScheduler.shared.submit(request)
            ICDiagnosticLogger.shared.logEvent("background-task", message: "Automatischer BGProcessingTask geplant", metadata: [
                "identifier": Self.automaticProcessingTaskIdentifier,
                "earliestBeginDate": Self.debugTimestampString(request.earliestBeginDate ?? Date()),
                "requiresNetwork": request.requiresNetworkConnectivity,
                "automaticQueueCount": automaticItems.count,
                "serverAutomaticQueueCount": serverAutomaticItems.count,
                "pendingCancellation": hasCancellationWork,
            ] as NSDictionary)
        } catch {
            ICDiagnosticLogger.shared.logEvent("background-task", message: "Automatischer BGProcessingTask konnte nicht geplant werden", metadata: [
                "identifier": Self.automaticProcessingTaskIdentifier,
                "earliestBeginDate": Self.debugTimestampString(request.earliestBeginDate ?? Date()),
                "error": Self.detailedErrorMessage(for: error),
                "automaticQueueCount": automaticItems.count,
                "pendingCancellation": hasCancellationWork,
            ] as NSDictionary)
        }
    }

    @objc(scheduleAutomaticBackgroundProcessingIfNeeded)
    func scheduleAutomaticBackgroundProcessingIfNeeded() {
        guard ICAITranscriptionFeaturesAvailable() else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.automaticProcessingTaskIdentifier)
            return
        }
        let automaticItems = items.filter {
            $0.automaticallyScheduled && $0.status == .queued
        }
        let hasCancellationWork = chapterGen.hasPendingOpenAIBackgroundCancellationWork
        let hasServerAutomaticItems = ServerTranscriptionManager.shared.hasPendingAutomaticItems
        guard !automaticItems.isEmpty || hasServerAutomaticItems || hasCancellationWork else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.automaticProcessingTaskIdentifier)
            ICDiagnosticLogger.shared.logEvent("background-task", message: "Kein automatischer BGProcessingTask erforderlich", metadata: [
                "identifier": Self.automaticProcessingTaskIdentifier,
            ] as NSDictionary)
            return
        }
        scheduleAutomaticBackgroundProcessing(earliestBeginDate: earliestAutomaticBackgroundWorkDate())
    }

    private nonisolated static func isTransientPipelineError(_ error: Error) -> Bool {
        var errors: [NSError] = []
        var current: NSError? = error as NSError
        while let candidate = current {
            errors.append(candidate)
            current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        let transientURLCodes: Set<Int> = [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
            NSURLErrorCannotLoadFromNetwork,
        ]
        let transientHTTPStatusCodes: Set<Int> = [408, 409, 425, 429]

        return errors.contains { candidate in
            if candidate.domain == "TranscriptionQueue.BackgroundInterruption" {
                return true
            }
            if candidate.domain == "ChapterGenerator.OpenAIBackground" {
                return true
            }
            if candidate.domain == NSURLErrorDomain && transientURLCodes.contains(candidate.code) {
                return true
            }
            if candidate.domain == "ChapterGenerator.RemoteHTTP" &&
                (transientHTTPStatusCodes.contains(candidate.code) || (500...599).contains(candidate.code)) {
                return true
            }
            if let statusCode = candidate.userInfo["HTTPStatusCode"] as? Int,
               transientHTTPStatusCodes.contains(statusCode) || (500...599).contains(statusCode) {
                return true
            }
            return false
        }
    }

    @discardableResult
    private func scheduleRetry(for item: ICTranscriptionQueueItem,
                               error: Error,
                               stage: String,
                               now: Date = Date()) -> Bool {
        guard item.automaticallyScheduled else {
            return false
        }

        let terminalOpenAIJob = chapterGen.terminalOpenAIBackgroundJobToken(for: item.episodeHash)
        let hasConfirmedTerminalOpenAIJob = terminalOpenAIJob.map { _ in true } ?? false
        guard Self.isTransientPipelineError(error) || hasConfirmedTerminalOpenAIJob else {
            return false
        }
        let shouldCountTerminalOpenAIJob: Bool
        if let terminalOpenAIJob {
            shouldCountTerminalOpenAIJob =
                terminalOpenAIJob.jobKey != item.lastCountedRemoteAnalysisJobKey ||
                terminalOpenAIJob.responseID != item.lastCountedRemoteAnalysisResponseID
        } else {
            shouldCountTerminalOpenAIJob = false
        }
        if shouldCountTerminalOpenAIJob,
           item.remoteAnalysisReplacementAttempts >= Self.maximumAutomaticRemoteAnalysisReplacements {
            ICDiagnosticLogger.shared.logEvent(
                "automatic-retry",
                message: "Automatische kostenpflichtige Neuanalyse nach drei Provider-Antworten gestoppt",
                metadata: [
                    "episodeHash": item.episodeHash,
                    "remoteAnalysisReplacementAttempts": item.remoteAnalysisReplacementAttempts,
                    "error": Self.detailedErrorMessage(for: error),
                ] as NSDictionary
            )
            return false
        }
        if let terminalOpenAIJob, shouldCountTerminalOpenAIJob {
            item.remoteAnalysisReplacementAttempts += 1
            item.lastCountedRemoteAnalysisJobKey = terminalOpenAIJob.jobKey
            item.lastCountedRemoteAnalysisResponseID = terminalOpenAIJob.responseID
        }

        let nextAttempt = min(item.retryAttempt + 1, 20)
        let exponent = min(max(nextAttempt - 1, 0), 10)
        let delay = min(
            Self.automaticRetryBaseDelay * pow(2, Double(exponent)),
            Self.automaticRetryMaximumDelay
        )
        let retryDate = now.addingTimeInterval(delay)
        let errorMessage = Self.detailedErrorMessage(for: error)

        item.status = .queued
        item.requiresExplicitRetryAfterCrash = false
        item.progress = 0
        item.statusDetail = String(
            format: NSLocalizedString("Vorübergehender Fehler. Nächster Versuch %@.", comment: ""),
            Self.debugTimestampString(retryDate)
        )
        item.statusStartedAt = nil
        item.error = errorMessage
        item.completedAt = nil
        item.retryAttempt = nextAttempt
        item.nextRetryAt = retryDate
        if item.shouldGenerateAnalysis && engine.hasSRT(for: item.episodeHash) {
            item.chapterOnly = true
            item.audioURL = nil
        }

        persistQueue { error in
            guard error == nil, let terminalOpenAIJob else { return }
            Task { @MainActor in
                ChapterGenerator.shared.retireTerminalOpenAIBackgroundJobAfterPersistedRetry(
                    terminalOpenAIJob
                )
            }
        }
        postQueueChangeNotification()
        TranscriptionLogger.shared.append(
            episodeHash: item.episodeHash,
            phase: "retry",
            message: "Vorübergehender Fehler — Wiederholung geplant",
            detailText: "\(stage), Versuch \(nextAttempt), \(Self.debugTimestampString(retryDate)): \(errorMessage)"
        )
        ICDiagnosticLogger.shared.logEvent("automatic-retry", message: "Persistenter Wiederholungsversuch geplant", metadata: [
            "episodeHash": item.episodeHash,
            "stage": stage,
            "retryAttempt": nextAttempt,
            "nextRetryAt": Self.debugTimestampString(retryDate),
            "delaySeconds": delay,
            "error": errorMessage,
            "checkpointExists": engine.hasCheckpoint(for: item.episodeHash),
            "chapterOnly": item.chapterOnly,
        ] as NSDictionary)
        scheduleAutomaticBackgroundProcessing(earliestBeginDate: retryDate)
        scheduleRetryWakeIfNeeded(now: now)
        return true
    }

    private func backgroundInterruptionError(reason: String) -> NSError {
        NSError(
            domain: "TranscriptionQueue.BackgroundInterruption",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }

    private var activeBackgroundExecutionPath: String? {
        grantedBackgroundExecutionPath
    }

    private var hasActiveSystemBackgroundGrant: Bool {
        switch activeBackgroundExecutionPath {
        case "legacy-processing", "continued-cpu", "continued-gpu":
            return true
        default:
            return false
        }
    }

    @objc var hasActiveBackgroundExecutionGrant: Bool {
        hasActiveSystemBackgroundGrant
    }

    private var hasActiveWhisperKitBackgroundExecution: Bool {
        engine.engineType == .whisperKit && hasActiveSystemBackgroundGrant
    }

    private var hasLifecycleManagedWork: Bool {
        isProcessing || chapterTask != nil || computeProfileTransitionTask != nil || !pendingDownloadHashes.isEmpty
    }

    private func refreshBackgroundContinuation(reason: String) {
        let shouldContinueInBackground = hasLifecycleManagedWork &&
            UIApplication.shared.applicationState == .background

        if shouldContinueInBackground {
            beginBackgroundContinuationIfNeeded(reason: reason)
        } else {
            endBackgroundContinuationIfNeeded(reason: reason)
        }
    }

    private func beginBackgroundContinuationIfNeeded(reason: String) {
        guard backgroundContinuationTask == .invalid else { return }

        let taskID = UIApplication.shared.beginBackgroundTask(withName: "InstacastPlus.TranscriptionQueue") { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundzeit abgelaufen", metadata: [
                    "reason": reason,
                    "queueCount": self.items.count,
                ] as NSDictionary)
                self.endBackgroundContinuationIfNeeded(reason: "background-task-expired")
                _ = self.pausePipelineForBackgroundIfNeeded(reason: "background-task-expired")
            }
        }

        guard taskID != .invalid else {
            ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundtask konnte nicht gestartet werden", metadata: [
                "reason": reason,
                "queueCount": items.count,
            ] as NSDictionary)
            return
        }

        backgroundContinuationTask = taskID
        ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundtask gestartet", metadata: [
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    private func endBackgroundContinuationIfNeeded(reason: String) {
        guard backgroundContinuationTask != .invalid else { return }
        let taskID = backgroundContinuationTask
        backgroundContinuationTask = .invalid
        UIApplication.shared.endBackgroundTask(taskID)
        ICDiagnosticLogger.shared.logEvent("background-task", message: "UIApplication-Hintergrundtask beendet", metadata: [
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    private func releaseModelIfIdle(reason: String) {
        guard engine.engineType == .whisperKit else { return }
        guard !hasLifecycleManagedWork else { return }
        guard !items.contains(where: {
            $0.status == .queued ||
            $0.status == .analyzingMusic ||
            $0.status == .downloadingModel ||
            $0.status == .transcribing ||
            $0.status == .generatingChapters
        }) else { return }

        let queueCount = items.count
        Task {
            await WhisperKitBackend.shared.releaseModel()
            ICDiagnosticLogger.shared.logEvent("model", message: "Whisper-Modell wegen Idle-Queue freigegeben", metadata: [
                "reason": reason,
                "queueCount": queueCount,
            ] as NSDictionary)
        }
    }

    @discardableResult
    private func pruneExpiredCompletedItems(now: Date = Date()) -> Bool {
        let beforeCount = items.count
        items.removeAll { item in
            guard item.status == .completed else { return false }
            guard let completedAt = item.completedAt else { return true }
            return now.timeIntervalSince(completedAt) >= Self.completedItemRetentionInterval
        }
        return items.count != beforeCount
    }

    private func scheduleCompletedItemPrune() {
        guard !completedPruneScheduled else { return }
        completedPruneScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.completedItemRetentionInterval) { [weak self] in
            guard let self = self else { return }
            self.completedPruneScheduled = false
            if self.pruneExpiredCompletedItems() {
                self.persistQueue()
                self.postQueueChangeNotification()
                self.releaseModelIfIdle(reason: "completed-item-pruned")
            }
            if self.items.contains(where: { $0.status == .completed }) {
                self.scheduleCompletedItemPrune()
            }
        }
    }

    private static func whisperKitComputeProfileName(for executionPath: String?) -> String {
        switch executionPath {
        case "legacy-processing", "continued-cpu":
            return "background-cpu-ane"
        default:
            return "foreground-gpu"
        }
    }

    private func beginWhisperKitComputeProfileTransitionIfNeeded(
        from oldPath: String?,
        to newPath: String?,
        reason: String
    ) {
        guard engine.engineType == .whisperKit else { return }
        let oldProfile = Self.whisperKitComputeProfileName(for: oldPath)
        let newProfile = Self.whisperKitComputeProfileName(for: newPath)
        guard oldProfile != newProfile else { return }

        cancelSpeechModelPreparation(reason: "compute-profile-changed")

        if isProcessing,
           let item = items.first(where: {
               $0.status == .downloadingModel ||
               $0.status == .transcribing
           }) {
            guard persistCheckpointBeforeInterruption(for: item, reason: reason) else { return }
            let task = currentTask
            invalidateProcessingRun()
            currentTask = nil
            isProcessing = false
            clearCrashGuard()
            item.status = .queued
            item.statusDetail = NSLocalizedString("Rechenprofil wird für die Hintergrundverarbeitung gewechselt.", comment: "")
            item.statusStartedAt = nil
            item.progressBaselineStartedAt = nil
            item.error = nil
            task?.cancel()
            analyzer.cancelAnalysis()
            engine.cancelTranscription()
            TranscriptionLogger.shared.append(
                episodeHash: item.episodeHash,
                phase: "model",
                message: "Rechenprofil gewechselt",
                detailText: "\(oldProfile) → \(newProfile), \(reason)"
            )
        }

        computeProfileTransitionTask?.cancel()
        let transitionID = UUID()
        computeProfileTransitionID = transitionID
        computeProfileTransitionTask = Task { [weak self] in
            await WhisperKitBackend.shared.releaseModel()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self,
                      self.computeProfileTransitionID == transitionID else { return }
                self.computeProfileTransitionID = nil
                self.computeProfileTransitionTask = nil
                self.refreshBackgroundContinuation(reason: "compute-profile-changed")
                self.processNext()
            }
        }

        persistQueue()
        postQueueChangeNotification()
        refreshBackgroundContinuation(reason: "compute-profile-changed")
        ICDiagnosticLogger.shared.logEvent("model", message: "compute-profile-changed", metadata: [
            "from": oldProfile,
            "to": newProfile,
            "executionPath": newPath ?? "foreground",
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
    }

    @discardableResult
    private func pauseWhisperKitForBackgroundIfNeeded() -> Bool {
        return pauseWhisperKitForBackgroundIfNeeded(reason: "applicationDidEnterBackground")
    }

    @discardableResult
    private func pauseWhisperKitForBackgroundIfNeeded(reason: String) -> Bool {
        guard shouldPauseWhisperKitForBackground else { return false }
        return pausePipelineForBackgroundIfNeeded(reason: reason)
    }

    @discardableResult
    private func pausePipelineForBackgroundIfNeeded(reason: String) -> Bool {
        guard UIApplication.shared.applicationState == .background,
              !hasActiveSystemBackgroundGrant else { return false }
        guard isProcessing || chapterTask != nil else { return false }
        guard let item = items.first(where: {
            $0.status == .analyzingMusic ||
            $0.status == .downloadingModel ||
            $0.status == .transcribing ||
            $0.status == .generatingChapters
        }) else { return false }

        let pausedStatus = item.status
        guard persistCheckpointBeforeInterruption(for: item, reason: reason) else { return false }
        let pipelineTask = currentTask
        let semanticTask = chapterTask
        finishBackgroundPause(for: item, reason: reason)
        if pausedStatus == .generatingChapters && semanticTask == nil {
            // The full pipeline task uses its run identifier, not the standalone
            // chapter-task cancellation handler, to recognize this pause.
            backgroundPausedEpisodeHashes.remove(item.episodeHash)
        }
        chapterTask = nil
        pipelineTask?.cancel()
        semanticTask?.cancel()
        analyzer.cancelAnalysis()
        engine.cancelTranscription()
        return true
    }

    private func persistCheckpointBeforeInterruption(for item: ICTranscriptionQueueItem,
                                                     reason: String) -> Bool {
        guard item.status == .transcribing else { return true }
        guard engine.persistCurrentCheckpointForInterruption() else {
            let detail = NSLocalizedString("Fortschritt konnte nicht gespeichert werden. Die Verarbeitung wird nicht abgebrochen.", comment: "")
            item.statusDetail = detail
            TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                              phase: "checkpoint",
                                              message: "Unterbrechung wegen fehlgeschlagenem Checkpoint abgelehnt",
                                              detailText: reason)
            ICDiagnosticLogger.shared.logEvent("checkpoint", message: "Unterbrechung wegen fehlgeschlagenem Checkpoint abgelehnt", metadata: [
                "episodeHash": item.episodeHash,
                "reason": reason,
            ] as NSDictionary)
            persistQueue()
            postQueueChangeNotification()
            return false
        }
        return true
    }

    private var shouldPauseChapterOnlyForBackground: Bool {
        UIApplication.shared.applicationState == .background &&
            !hasActiveSystemBackgroundGrant
    }

    private var shouldPauseTranscriptionForBackground: Bool {
        UIApplication.shared.applicationState == .background &&
            !hasActiveSystemBackgroundGrant
    }

    private var shouldPauseWhisperKitForBackground: Bool {
        engine.engineType == .whisperKit &&
            shouldPauseTranscriptionForBackground &&
            !hasActiveWhisperKitBackgroundExecution
    }

    private func applyGrantedWhisperKitExecutionPathForCurrentLifecycle(reason: String) {
        let desiredPath = UIApplication.shared.applicationState == .background
            ? grantedBackgroundExecutionPath
            : nil
        applyWhisperKitExecutionPath(desiredPath, reason: reason)
    }

    private func applyForegroundWhisperKitExecutionPath(reason: String) {
        applyWhisperKitExecutionPath(nil, reason: reason)
    }

    private func applyWhisperKitExecutionPath(_ path: String?, reason: String) {
        let previousPath = appliedWhisperKitExecutionPath
        guard previousPath != path else { return }
        appliedWhisperKitExecutionPath = path
        WhisperKitBackend.setActiveBackgroundExecutionPath(path)
        beginWhisperKitComputeProfileTransitionIfNeeded(
            from: previousPath,
            to: path,
            reason: reason
        )
    }

    @objc(activateBackgroundExecutionPathWithPath:detail:)
    func activateBackgroundExecutionPath(path: String, detail: String) {
        grantedBackgroundExecutionPath = path
        UserDefaults.standard.set(path, forKey: TranscriptionQueue.backgroundExecutionPathKey)
        UserDefaults.standard.set(path == "continued-cpu" || path == "continued-gpu",
                                  forKey: TranscriptionQueue.continuedBackgroundActiveKey)
        applyGrantedWhisperKitExecutionPathForCurrentLifecycle(reason: "background-path-activated")

        let activeItems = items.filter {
            $0.status == .queued ||
            $0.status == .analyzingMusic ||
            $0.status == .downloadingModel ||
            $0.status == .transcribing ||
            $0.status == .generatingChapters
        }
        for item in activeItems {
            TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                              phase: "background",
                                              message: "Hintergrundpfad aktiviert",
                                              detailText: "\(path): \(detail)")
        }

        ICDiagnosticLogger.shared.logEvent("background-task", message: "Hintergrundpfad aktiviert", metadata: [
            "path": path,
            "detail": detail,
            "queueCount": items.count,
        ] as NSDictionary)
        postQueueChangeNotification()
    }

    @objc(completeBackgroundExecutionPathWithSuccess:reason:)
    func completeBackgroundExecutionPath(success: Bool, reason: String) {
        let activePath = activeBackgroundExecutionPath
        let path = activePath ?? "unknown"
        grantedBackgroundExecutionPath = nil
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskRequestedKey)
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.continuedBackgroundActiveKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionQueue.backgroundExecutionPathKey)
        if !success {
            _ = pausePipelineForBackgroundIfNeeded(reason: reason)
        }
        applyForegroundWhisperKitExecutionPath(reason: reason)
        ICDiagnosticLogger.shared.logEvent("background-task", message: "Hintergrundpfad beendet", metadata: [
            "path": path,
            "reason": reason,
            "success": success,
            "queueCount": items.count,
        ] as NSDictionary)
        postQueueChangeNotification()
    }

    @objc(deactivateBackgroundExecutionPathWithReason:)
    func deactivateBackgroundExecutionPath(reason: String) {
        let activePath = activeBackgroundExecutionPath
        let path = activePath ?? "unknown"
        grantedBackgroundExecutionPath = nil
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskRequestedKey)
        UserDefaults.standard.set(false, forKey: TranscriptionQueue.continuedBackgroundActiveKey)
        UserDefaults.standard.removeObject(forKey: TranscriptionQueue.backgroundExecutionPathKey)
        _ = pausePipelineForBackgroundIfNeeded(reason: reason)
        applyForegroundWhisperKitExecutionPath(reason: reason)
        ICDiagnosticLogger.shared.logEvent("background-task", message: "Hintergrundpfad deaktiviert", metadata: [
            "path": path,
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
        postQueueChangeNotification()
    }

    @objc(expireContinuedBackgroundExecutionWithReason:)
    func expireContinuedBackgroundExecution(reason: String) {
        ICDiagnosticLogger.shared.logEvent("background-task", message: "BGContinuedProcessingTask abgelaufen", metadata: [
            "reason": reason,
            "queueCount": items.count,
        ] as NSDictionary)
        completeBackgroundExecutionPath(success: false, reason: reason)
    }

    private func finishBackgroundPause(for item: ICTranscriptionQueueItem, reason: String, error: Error? = nil) {
        backgroundPausedEpisodeHashes.insert(item.episodeHash)
        let pauseDetail = NSLocalizedString("Verarbeitung im Hintergrund pausiert. Wird mit verfügbarer Rechenzeit automatisch fortgesetzt.", comment: "")
        invalidateProcessingRun()
        clearCrashGuard()
        isProcessing = false
        currentTask = nil
        if item.shouldGenerateAnalysis && engine.hasSRT(for: item.episodeHash) {
            item.chapterOnly = true
            item.audioURL = nil
        }
        item.status = .queued
        item.statusDetail = pauseDetail
        item.statusStartedAt = nil
        item.progressBaselineStartedAt = nil
        item.nextRetryAt = nil
        item.error = nil
        item.completedAt = nil
        if item.automaticallyScheduled {
            scheduleAutomaticBackgroundProcessing(earliestBeginDate: nil)
        }
        refreshBackgroundContinuation(reason: reason)
        persistQueue()
        postQueueChangeNotification()

        TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                          phase: "background",
                                          message: "Verarbeitung im Hintergrund pausiert",
                                          detailText: error.map { TranscriptionQueue.detailedErrorMessage(for: $0) })
        ICDiagnosticLogger.shared.logEvent("queue", message: "Verarbeitung im Hintergrund pausiert", metadata: [
            "episodeHash": item.episodeHash,
            "reason": reason,
        ] as NSDictionary)
    }

    // MARK: - Processing

    private func startSpeechModelPreparationIfNeeded(episodeHash: String, reason: String) {
        guard engine.engineType == .whisperKit else { return }
        guard WhisperKitBackend.shared.isModelDownloadedSync() else { return }
        guard speechModelPreparationTask == nil else { return }

        let runID = UUID()
        speechModelPreparationRunID = runID
        ICDiagnosticLogger.shared.logEvent("model", message: "Sprachmodell-Vorbereitung vorgezogen", metadata: [
            "episodeHash": episodeHash,
            "reason": reason,
        ] as NSDictionary)

        speechModelPreparationTask = Task { [weak self] in
            do {
                try await WhisperKitBackend.shared.prepareModel()
                await MainActor.run {
                    self?.updateDownloadStatusAfterSpeechModelPreparation(
                        episodeHash: episodeHash,
                        error: nil
                    )
                }
                ICDiagnosticLogger.shared.logEvent("model", message: "Vorgezogene Sprachmodell-Vorbereitung abgeschlossen", metadata: [
                    "episodeHash": episodeHash,
                    "reason": reason,
                ] as NSDictionary)
            } catch is CancellationError {
                await MainActor.run {
                    self?.updateDownloadStatusAfterSpeechModelPreparation(
                        episodeHash: episodeHash,
                        error: nil
                    )
                }
                ICDiagnosticLogger.shared.logEvent("model", message: "Vorgezogene Sprachmodell-Vorbereitung abgebrochen", metadata: [
                    "episodeHash": episodeHash,
                    "reason": reason,
                ] as NSDictionary)
            } catch {
                await MainActor.run {
                    self?.updateDownloadStatusAfterSpeechModelPreparation(
                        episodeHash: episodeHash,
                        error: error
                    )
                }
                ICDiagnosticLogger.shared.logEvent("model", message: "Vorgezogene Sprachmodell-Vorbereitung fehlgeschlagen", metadata: [
                    "episodeHash": episodeHash,
                    "reason": reason,
                    "error": error.localizedDescription,
                ] as NSDictionary)
            }

            await MainActor.run {
                guard let self = self, self.speechModelPreparationRunID == runID else { return }
                self.speechModelPreparationRunID = nil
                self.speechModelPreparationTask = nil
            }
        }
    }

    private func updateDownloadStatusAfterSpeechModelPreparation(episodeHash: String,
                                                                 error: Error?) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash }),
              item.statusDetail == NSLocalizedString(
                "Episode wird heruntergeladen. Spracherkennungsmodell wird vorbereitet.",
                comment: ""
              ) else { return }
        item.statusDetail = error == nil
            ? NSLocalizedString("Episode wird heruntergeladen.", comment: "")
            : NSLocalizedString("Episode wird heruntergeladen. Modellvorbereitung fehlgeschlagen.", comment: "")
        persistQueue()
        postQueueChangeNotification()
    }

    private func cancelSpeechModelPreparation(reason: String) {
        guard speechModelPreparationTask != nil else { return }
        speechModelPreparationTask?.cancel()
        speechModelPreparationTask = nil
        speechModelPreparationRunID = nil
        ICDiagnosticLogger.shared.logEvent("model", message: "Vorgezogene Sprachmodell-Vorbereitung abgebrochen", metadata: [
            "reason": reason,
        ] as NSDictionary)
    }

    private func processNext() {
        guard ICAITranscriptionFeaturesAvailable() else { return }
        guard !cacheClearInProgress else { return }
        guard !isProcessing else { return }
        guard currentProcessingRunID == nil else { return }
        guard chapterTask == nil else { return }
        guard computeProfileTransitionTask == nil else { return }

        // Iteratively skip failed items (no recursion, no stack growth)
        var item: ICTranscriptionQueueItem?
        var resolvedAudioURL: URL?

        while true {
            // Find next queued item
            let now = Date()
            guard let candidate = items.first(where: {
                $0.status == .queued &&
                    !$0.requiresExplicitRetryAfterCrash &&
                    ($0.nextRetryAt == nil || $0.nextRetryAt! <= now) &&
                    !($0.chapterOnly
                        ? shouldPauseChapterOnlyForBackground
                        : shouldPauseTranscriptionForBackground) &&
                    !pendingCacheDeletionHashes.contains($0.episodeHash)
            }) else {
                let didPrune = pruneExpiredCompletedItems()
                persistQueue()
                if didPrune {
                    postQueueChangeNotification()
                }
                if let retryDate = earliestAutomaticRetryDate(now: now) {
                    scheduleAutomaticBackgroundProcessing(earliestBeginDate: retryDate)
                }
                scheduleRetryWakeIfNeeded(now: now)
                refreshBackgroundContinuation(reason: "queue-idle")
                releaseModelIfIdle(reason: "queue-idle")
                return
            }

            candidate.nextRetryAt = nil
            scheduleRetryWakeIfNeeded(now: now)

            if candidate.automaticallyScheduled {
                guard let runtimeIntent = revalidateAutomaticCandidateBeforeStart(candidate) else {
                    removeAutomaticQueueItemAfterRuntimeRevalidation(
                        candidate,
                        stage: "before-candidate-start",
                        reason: NSLocalizedString("Automatische Verarbeitung ist für diesen Podcast nicht mehr aktiviert.", comment: "")
                    )
                    continue
                }
                candidate.shouldGenerateAnalysis = runtimeIntent.analyze

                if candidate.chapterOnly {
                    if let reason = runtimeIntent.analysisUnavailableReason {
                        candidate.status = .failed
                        candidate.statusDetail = nil
                        candidate.statusStartedAt = nil
                        candidate.error = reason
                        persistQueue()
                        postQueueChangeNotification()
                        continue
                    }
                    guard runtimeIntent.analyze else {
                        removeAutomaticQueueItemAfterRuntimeRevalidation(
                            candidate,
                            stage: "before-chapter-only-start",
                            reason: NSLocalizedString("Automatische Analyse ist für diesen Podcast deaktiviert.", comment: "")
                        )
                        continue
                    }
                } else {
                    if let reason = runtimeIntent.analysisUnavailableReason,
                       !runtimeIntent.transcribe {
                        candidate.status = .failed
                        candidate.statusDetail = nil
                        candidate.statusStartedAt = nil
                        candidate.error = reason
                        persistQueue()
                        postQueueChangeNotification()
                        continue
                    }
                    guard runtimeIntent.transcribe || runtimeIntent.analyze else {
                        removeAutomaticQueueItemAfterRuntimeRevalidation(
                            candidate,
                            stage: "before-transcription-start",
                            reason: NSLocalizedString("Automatische Verarbeitung ist für diesen Podcast nicht mehr aktiviert.", comment: "")
                        )
                        continue
                    }
                }
            }

            if candidate.chapterOnly {
                guard hasChapterGenerationTranscript(episodeHash: candidate.episodeHash) else {
                    candidate.status = .failed
                    candidate.statusDetail = nil
                    candidate.statusStartedAt = nil
                    candidate.error = NSLocalizedString("Transkript konnte nicht geladen werden.", comment: "")
                    persistQueue()
                    postQueueChangeNotification()
                    continue
                }
                guard ICDownloadableModelStore.selectedChapterModelIsReady(),
                      ICDownloadableModelStore.selectedChapterModelCanGenerate() else {
                    candidate.status = .failed
                    candidate.statusDetail = nil
                    candidate.statusStartedAt = nil
                    candidate.error = ICDownloadableModelStore.selectedChapterModelUnavailableReason()
                    persistQueue()
                    postQueueChangeNotification()
                    continue
                }
                startChapterGenerationTask(for: candidate, startReason: "chapter-task-resumed")
                return
            }

            guard let cman = CacheManager.shared() else { return }
            cman.prepareCacheIndexIfNeeded()
            guard cman.isCacheIndexReady else { return }

            // Resolve audio URL
            if let url = candidate.audioURL, FileManager.default.fileExists(atPath: url.path) {
                resolvedAudioURL = url
            } else if let resolved = resolveAudioURL(for: candidate.episodeHash) {
                resolvedAudioURL = resolved
                candidate.audioURL = resolved
            } else {
                // Audio not available — try auto-downloading
                NSLog("[TranscriptionQueue] Audio not cached for %@, attempting auto-download", candidate.episodeHash)
                startSpeechModelPreparationIfNeeded(episodeHash: candidate.episodeHash, reason: "auto-download")
                let autoDownload = autoDownloadEpisode(hash: candidate.episodeHash)
                if autoDownload.started {
                    if engine.engineType == .whisperKit && WhisperKitBackend.shared.isModelDownloadedSync() {
                        candidate.statusDetail = NSLocalizedString("Episode wird heruntergeladen. Spracherkennungsmodell wird vorbereitet.", comment: "")
                    } else {
                        candidate.statusDetail = NSLocalizedString("Automatischer Download wurde gestartet.", comment: "")
                    }
                    candidate.error = NSLocalizedString("Episode wird heruntergeladen...", comment: "")
                    TranscriptionLogger.shared.append(episodeHash: candidate.episodeHash, phase: "download",
                                                      message: "Automatischer Download gestartet", detailText: nil)
                    postQueueChangeNotification()
                    return // Will resume in _handleDownloadCompletion
                }
                let downloadError = autoDownload.error ?? NSError(
                    domain: "TranscriptionQueue",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Audiodatei nicht verfügbar.", comment: "")]
                )
                if !scheduleRetry(for: candidate, error: downloadError, stage: "episode-download-start") {
                    candidate.status = .failed
                    candidate.statusDetail = nil
                    candidate.statusStartedAt = nil
                    candidate.nextRetryAt = nil
                    candidate.error = downloadError.localizedDescription
                }
                persistQueue()
                postQueueChangeNotification()
                continue // Try next item
            }

            // Check failure counter for OOM loop protection
            if let failures = loadCheckpointFailures(for: candidate.episodeHash), failures >= 6 {
                candidate.status = .failed
                candidate.statusDetail = nil
                candidate.statusStartedAt = nil
                candidate.error = NSLocalizedString("Transkription auf diesem Gerät nicht möglich.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // Check if WhisperKit model is downloaded
            if engine.engineType == .whisperKit && !WhisperKitBackend.shared.isModelDownloadedSync() {
                candidate.status = .failed
                candidate.statusDetail = nil
                candidate.statusStartedAt = nil
                candidate.error = NSLocalizedString("Sprachmodell nicht installiert. Bitte in Einstellungen > Transkription herunterladen.", comment: "")
                postQueueChangeNotification()
                continue // Try next item
            }

            // All checks passed — process this item
            item = candidate
            break
        }

        guard let item = item, let audioURL = resolvedAudioURL else { return }

        backgroundPausedEpisodeHashes.remove(item.episodeHash)
        isProcessing = true
        refreshBackgroundContinuation(reason: "pipeline-started")
        let episodeHash = item.episodeHash
        let detailUpdater: @Sendable (String) -> Void = { detail in
            NotificationCenter.default.post(
                name: ICTranscriptionInternalStatusDetailNotification,
                object: nil,
                userInfo: ["episodeHash": episodeHash, "detail": detail]
            )
        }

        // Bind unexpected termination to this exact episode. On restoration an
        // automatically scheduled episode gets a persistent interruption retry;
        // only an interrupted manual episode is quarantined for explicit retry.
        // Other queued automatic podcasts remain eligible and continue normally.
        armCrashGuard(for: item)

        let runID = beginProcessingRun()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline gestartet", metadata: [
                "episodeHash": episodeHash,
                "episodeTitle": item.episodeTitle,
                "feedTitle": item.feedTitle,
                "audioPath": audioURL.path,
            ] as NSDictionary)
            ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "pipeline-start", audioURL: audioURL)

            // Step 1: Music Analysis (SoundAnalysis, < 1 min). A compute-profile
            // transition re-enters the pipeline, but it must reuse the durable
            // timeline instead of presenting the cache read as a fresh analysis.
            let hasCachedAudioAnalysis = await MainActor.run {
                self.analyzer.hasCachedTimeline(for: episodeHash)
            }
            if !hasCachedAudioAnalysis {
                await MainActor.run {
                    self.beginStep(for: item,
                                   status: .analyzingMusic,
                                   detail: NSLocalizedString("Erkenne Musik, Sprache und Stille für spätere Kapitelgrenzen.", comment: ""))
                    self.postQueueChangeNotification()
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "music",
                                                      message: "Audioanalyse gestartet (SoundAnalysis)", detailText: nil)
                }
            }

            let musicStart = Date()
            let musicSegments: [ICAudioSegment]?
            let audioAnalysisError: Error?
            do {
                musicSegments = try await self.analyzer.analyzeAsync(audioURL: audioURL, episodeHash: episodeHash)
                audioAnalysisError = nil
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        self.clearProcessingRun(runID)
                        self.clearCrashGuard()
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-cancelled-during-audio-analysis")
                        self.postQueueChangeNotification()
                        self.processNext()
                    }
                    ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline abgebrochen während Audioanalyse", metadata: [
                        "episodeHash": episodeHash,
                    ] as NSDictionary)
                    return
                }
                NSLog("[TranscriptionQueue] Music analysis error: %@", error.localizedDescription)
                musicSegments = nil
                audioAnalysisError = error
            }
            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                let elapsed = -musicStart.timeIntervalSinceNow
                let musicCount = (musicSegments ?? []).filter { $0.type == "music" }.count
                if hasCachedAudioAnalysis, audioAnalysisError == nil {
                    TranscriptionLogger.shared.append(
                        episodeHash: episodeHash,
                        phase: "music",
                        message: "Audioanalyse aus gespeichertem Ergebnis übernommen",
                        detailText: "\(musicCount) Musiksegmente"
                    )
                } else if let audioAnalysisError {
                    let continuation = NSLocalizedString("Verarbeitung wird ohne Audiohinweise fortgesetzt.", comment: "")
                    TranscriptionLogger.shared.append(
                        episodeHash: episodeHash,
                        phase: "music",
                        message: NSLocalizedString("Audioanalyse fehlgeschlagen", comment: ""),
                        detailText: "\(continuation) \(TranscriptionQueue.detailedErrorMessage(for: audioAnalysisError))"
                    )
                } else {
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "music",
                                                      message: "Audioanalyse abgeschlossen",
                                                      detailText: String(format: "%.1f s, %d Musiksegmente", elapsed, musicCount))
                }
            }

            guard !Task.isCancelled else {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    self.clearProcessingRun(runID)
                    self.clearCrashGuard()
                    self.isProcessing = false
                    self.refreshBackgroundContinuation(reason: "pipeline-cancelled-after-audio-analysis")
                    self.processNext()
                }
                return
            }

            let pausedBeforeModelLoad = await MainActor.run { () -> Bool in
                guard self.processingRunIsCurrent(runID) else { return true }
                guard self.shouldPauseWhisperKitForBackground else { return false }
                self.finishBackgroundPause(for: item, reason: "pipeline-background-before-model-load")
                return true
            }
            if pausedBeforeModelLoad {
                return
            }

            // Step 2: Pre-load WhisperKit model. The backend coalesces concurrent
            // resume attempts so CoreML never opens the same model twice.
            if self.engine.engineType == .whisperKit {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    self.beginStep(for: item,
                                   status: .downloadingModel,
                                   detail: NSLocalizedString("Modell wird vorbereitet.", comment: ""))
                    self.postQueueChangeNotification()
                    let sizeBytes = WhisperKitBackend.shared.modelSizeOnDiskSync()
                    let sizeDetail = sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : nil
                    TranscriptionLogger.shared.append(
                        episodeHash: episodeHash, phase: "model",
                        message: "WhisperKit-Modell wird geladen (\(TranscriptionEngine.resolvedModelName()))",
                        detailText: sizeDetail)
                }

                let modelStart = Date()
                do {
                    try await WhisperKitBackend.shared.prepareModel(statusUpdate: detailUpdater)
                } catch {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        if TranscriptionEngine.isBackgroundGPUExecutionError(error) {
                            self.finishBackgroundPause(for: item, reason: "model-load-background-gpu-error", error: error)
                            return
                        }
                        let errMsg = TranscriptionQueue.detailedErrorMessage(for: error)
                        TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                          message: "Modell-Ladefehler", detailText: errMsg)
                        if !self.scheduleRetry(for: item, error: error, stage: "speech-model-load") {
                            item.status = .failed
                            item.statusDetail = nil
                            item.statusStartedAt = nil
                            item.nextRetryAt = nil
                            item.error = errMsg
                        }
                        // Normal error path — the pipeline terminates cleanly so clear the guard.
                        self.clearProcessingRun(runID)
                        self.clearCrashGuard()
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-model-load-failed")
                        self.postQueueChangeNotification()
                        self.processNext()
                    }
                    return
                }

                guard await MainActor.run(body: { self.processingRunIsCurrent(runID) }) else { return }
                await MainActor.run {
                    let elapsed = -modelStart.timeIntervalSinceNow
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "model",
                                                      message: "Modell geladen",
                                                      detailText: String(format: "%.1f s", elapsed))
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        self.clearProcessingRun(runID)
                        self.clearCrashGuard()
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-cancelled-during-model-load")
                        self.processNext()
                    }
                    ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline abgebrochen während Modell-Load", metadata: [
                        "episodeHash": episodeHash,
                    ] as NSDictionary)
                    return
                }
            }

            let pausedBeforeTranscription = await MainActor.run { () -> Bool in
                guard self.processingRunIsCurrent(runID) else { return true }
                guard self.shouldPauseWhisperKitForBackground else { return false }
                self.finishBackgroundPause(for: item, reason: "pipeline-background-before-transcription")
                return true
            }
            if pausedBeforeTranscription {
                return
            }

            // Step 3: Transcription — model is already in memory, this starts immediately
            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                self.beginStep(for: item,
                               status: .transcribing,
                               detail: NSLocalizedString("Warte auf das erste erkannte Transkriptsegment.", comment: ""))
                self.postQueueChangeNotification()
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "transcribe",
                                                  message: "Transkription gestartet", detailText: nil)
            }
            let transcribeStart = Date()

            let transcriptionOutcome = await withCheckedContinuation { (continuation: CheckedContinuation<(cues: [ICTranscriptCue]?, error: Error?), Never>) in
                self.engine.transcribe(
                    audioURL: audioURL,
                    episodeHash: episodeHash,
                    language: item.language,
                    statusDetail: detailUpdater,
                    progress: { [weak self] progress, status in
                        NSLog("[TranscriptionQueue] Progress received: %.1f%% status=%ld", progress * 100, status.rawValue)
                        DispatchQueue.main.async {
                            guard self?.processingRunIsCurrent(runID) == true else { return }
                            self?.recordProgressSample(for: item,
                                                       progress: progress,
                                                       status: status)
                            self?.postProgressNotification(episodeHash: episodeHash, progress: progress, status: status)
                        }
                    },
                    completion: { cues, error in
                        if let error = error {
                            NSLog("[TranscriptionQueue] Transcription error: %@", error.localizedDescription)
                        }
                        continuation.resume(returning: (cues, error))
                    }
                )
            }

            guard await MainActor.run(body: { self.processingRunIsCurrent(runID) }) else {
                await MainActor.run {
                    _ = self.backgroundPausedEpisodeHashes.remove(episodeHash)
                }
                return
            }
            if let error = transcriptionOutcome.error {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    if TranscriptionEngine.isBackgroundGPUExecutionError(error) {
                        self.finishBackgroundPause(for: item, reason: "transcription-background-gpu-error", error: error)
                        return
                    }
                    if self.backgroundPausedEpisodeHashes.remove(episodeHash) != nil {
                        self.clearProcessingRun(runID)
                        self.clearCrashGuard()
                        self.isProcessing = false
                        self.currentTask = nil
                        self.refreshBackgroundContinuation(reason: "pipeline-background-paused")
                        self.postQueueChangeNotification()
                        return
                    }

                    let errMsg = TranscriptionQueue.detailedErrorMessage(for: error)
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                      message: "Transkriptions-Fehler", detailText: errMsg)
                    if !self.scheduleRetry(for: item, error: error, stage: "transcription") {
                        item.status = .failed
                        item.statusDetail = nil
                        item.statusStartedAt = nil
                        item.nextRetryAt = nil
                        item.error = errMsg
                    }
                    self.clearProcessingRun(runID)
                    self.clearCrashGuard()
                    self.isProcessing = false
                    self.currentTask = nil
                    self.refreshBackgroundContinuation(reason: "pipeline-transcription-error")
                    self.postQueueChangeNotification()
                    self.processNext()
                }
                return
            }

            guard let transcriptCues = transcriptionOutcome.cues, !Task.isCancelled else {
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    if self.backgroundPausedEpisodeHashes.remove(episodeHash) != nil {
                        self.clearProcessingRun(runID)
                        self.clearCrashGuard()
                        self.isProcessing = false
                        self.currentTask = nil
                        self.refreshBackgroundContinuation(reason: "pipeline-background-paused")
                        self.postQueueChangeNotification()
                        return
                    }
                    if item.status != .failed {
                        item.status = .failed
                        item.statusDetail = nil
                        item.statusStartedAt = nil
                        item.error = NSLocalizedString("Transkription fehlgeschlagen.", comment: "")
                    }
                    // Normal error/cancel path — pipeline terminated cleanly.
                    self.clearProcessingRun(runID)
                    self.clearCrashGuard()
                    self.isProcessing = false
                    self.refreshBackgroundContinuation(reason: "pipeline-transcription-failed")
                    self.postQueueChangeNotification()
                    self.processNext()
                }
                return
            }

            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                let elapsed = -transcribeStart.timeIntervalSinceNow
                let charCount = transcriptCues.reduce(0) { $0 + $1.text.count }
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "transcribe",
                                                  message: "Transkription abgeschlossen",
                                                  detailText: String(format: "%.1f s, %d Segmente, %d Zeichen",
                                                                     elapsed, transcriptCues.count, charCount))
            }

            // Step 4: semantic episode analysis. Remote long-context models
            // produce chapters, evidence-bound sponsors, and a summary in one
            // request; local models retain their chapter-only contract.
            var automaticRuntimeAnalysisError: Error?
            if item.automaticallyScheduled {
                guard let runtimeIntent = self.revalidatedAutomaticRuntimeIntent(
                    for: item,
                    stage: "after-transcription-before-analysis"
                ) else {
                    await MainActor.run {
                        self.finishActiveAutomaticPipelineAfterRuntimeRevalidation(
                            item,
                            runID: runID,
                            stage: "after-transcription-before-analysis",
                            reason: NSLocalizedString("Automatische Verarbeitung ist für diesen Podcast nicht mehr aktiviert.", comment: "")
                        )
                    }
                    return
                }

                item.shouldGenerateAnalysis = runtimeIntent.analyze
                if !runtimeIntent.transcribe && !runtimeIntent.analysisRequested {
                    await MainActor.run {
                        self.finishActiveAutomaticPipelineAfterRuntimeRevalidation(
                            item,
                            runID: runID,
                            stage: "after-transcription-before-analysis",
                            reason: NSLocalizedString("Automatische Verarbeitung ist für diesen Podcast nicht mehr aktiviert.", comment: "")
                        )
                    }
                    return
                }
                if let reason = runtimeIntent.analysisUnavailableReason {
                    automaticRuntimeAnalysisError = AutomaticAnalysisRequestRevalidationError.unavailable(reason)
                }
            }

            var persistedTranscriptCues: [ICTranscriptCue] = []
            var persistedTranscriptError: Error?
            if item.shouldGenerateAnalysis {
                do {
                    // The engine has already committed the SRT. Reload that exact
                    // millisecond timeline so the request revision, sponsor
                    // boundaries, and post-request revision check all use the same
                    // durable representation instead of Whisper's Float timings.
                    persistedTranscriptCues = try await self.loadCuesForChapterGeneration(
                        episodeHash: episodeHash
                    )
                } catch {
                    persistedTranscriptError = error
                }
            }
            let shouldGenerateAnalysis: Bool
            var chapterGenerationError: Error? = automaticRuntimeAnalysisError
            if !item.shouldGenerateAnalysis {
                shouldGenerateAnalysis = false
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: "Kapitelerstellung übersprungen",
                                                      detailText: automaticRuntimeAnalysisError?.localizedDescription
                                                        ?? NSLocalizedString("Automatische Analyse ist für diesen Podcast deaktiviert.", comment: ""))
                }
            } else if let persistedTranscriptError {
                shouldGenerateAnalysis = false
                chapterGenerationError = persistedTranscriptError
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    TranscriptionLogger.shared.append(
                        episodeHash: episodeHash,
                        phase: "chapters",
                        message: "Persistiertes Transkript konnte nicht für die Episodenanalyse geladen werden",
                        detailText: TranscriptionQueue.detailedErrorMessage(for: persistedTranscriptError)
                    )
                }
            } else if !ICDownloadableModelStore.selectedChapterModelIsReady() {
                shouldGenerateAnalysis = false
                let error = NSError(
                    domain: "TranscriptionQueue.SemanticAnalysis",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: "")]
                )
                chapterGenerationError = error
                NSLog("[TranscriptionQueue] Chapter model is not downloaded")
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: "Episodenanalyse nicht gestartet",
                                                      detailText: error.localizedDescription)
                }
            } else if ICDownloadableModelStore.selectedChapterModelCanGenerate() {
                shouldGenerateAnalysis = true
            } else {
                shouldGenerateAnalysis = false
                let reason = ICDownloadableModelStore.selectedChapterModelUnavailableReason()
                chapterGenerationError = NSError(
                    domain: "TranscriptionQueue.SemanticAnalysis",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: reason]
                )
                NSLog("[TranscriptionQueue] ChapterGenerator not available: %@", reason)
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: "Episodenanalyse nicht gestartet",
                                                      detailText: reason)
                }
            }

            if shouldGenerateAnalysis {
                let pausedBeforeAnalysis = await MainActor.run { () -> Bool in
                    guard self.processingRunIsCurrent(runID),
                          self.shouldPauseChapterOnlyForBackground else { return false }
                    self.finishBackgroundPause(for: item, reason: "pipeline-background-before-semantic-analysis")
                    self.backgroundPausedEpisodeHashes.remove(episodeHash)
                    return true
                }
                if pausedBeforeAnalysis {
                    return
                }

                await WhisperKitBackend.shared.releaseModel()
                ICDiagnosticLogger.shared.logEvent("model",
                                                   message: "Whisper-Modell vor Kapitelerstellung freigegeben",
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "reason": "before-chapter-generation",
                                                   ] as NSDictionary)
                let musicCount = (musicSegments ?? []).filter { $0.type == "music" }.count
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    self.beginStep(for: item,
                                   status: .generatingChapters,
                                   detail: NSLocalizedString("Transkript wird für die Kapitel-Erstellung vorbereitet.", comment: ""))
                    self.postQueueChangeNotification()
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: "Kapitelerstellung gestartet",
                                                      detailText: "\(persistedTranscriptCues.count) Cues, \(musicCount) Musiksegmente")
                }
                NSLog("[TranscriptionQueue] Generating chapters from %d cues + %d music segments",
                      persistedTranscriptCues.count, musicCount)

                let chapterStart = Date()
                let semanticArtifacts: GeneratedSemanticArtifacts?
                do {
                    semanticArtifacts = try await self.generateSemanticArtifacts(
                        from: persistedTranscriptCues,
                        musicSegments: musicSegments,
                        episodeHash: episodeHash,
                        episodeTitle: item.episodeTitle,
                        feedTitle: item.feedTitle,
                        automaticItem: item,
                        status: detailUpdater,
                        progress: { [weak self] progress, chunkIndex, totalChunks in
                            guard self?.processingRunIsCurrent(runID) == true else { return }
                            self?.recordProgressSample(for: item,
                                                       progress: progress,
                                                       status: .generatingChapters)
                            self?.postProgressNotification(episodeHash: episodeHash, progress: progress, status: .generatingChapters)
                        }
                    )
                    NSLog("[TranscriptionQueue] Generated %d chapters", semanticArtifacts?.chapters.count ?? 0)
                } catch {
                    semanticArtifacts = nil
                    if let runtimeError = error as? AutomaticAnalysisRequestRevalidationError {
                        switch runtimeError {
                        case .processingDisabled:
                            await MainActor.run {
                                self.finishActiveAutomaticPipelineAfterRuntimeRevalidation(
                                    item,
                                    runID: runID,
                                    stage: "immediately-before-semantic-request",
                                    reason: runtimeError.localizedDescription
                                )
                            }
                            return
                        case .analysisDisabled:
                            await MainActor.run {
                                guard self.processingRunIsCurrent(runID) else { return }
                                TranscriptionLogger.shared.append(
                                    episodeHash: episodeHash,
                                    phase: "chapters",
                                    message: "Kapitelerstellung nach Konfigurationsprüfung übersprungen",
                                    detailText: runtimeError.localizedDescription
                                )
                            }
                            chapterGenerationError = nil
                        case .unavailable:
                            chapterGenerationError = runtimeError
                        }
                    } else if error is CancellationError || Task.isCancelled {
                        await MainActor.run {
                            guard self.processingRunIsCurrent(runID) else { return }
                            self.clearProcessingRun(runID)
                            self.clearCrashGuard()
                            self.isProcessing = false
                            self.refreshBackgroundContinuation(reason: "pipeline-cancelled-during-chapter-generation")
                            self.postQueueChangeNotification()
                            self.processNext()
                        }
                        ICDiagnosticLogger.shared.logEvent("queue", message: "Pipeline abgebrochen während Kapitelerstellung", metadata: [
                            "episodeHash": episodeHash,
                        ] as NSDictionary)
                        return
                    } else {
                        chapterGenerationError = error
                        NSLog("[TranscriptionQueue] Chapter generation error: %@", error.localizedDescription)
                        await MainActor.run {
                            guard self.processingRunIsCurrent(runID) else { return }
                            TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                              message: "Kapitelerstellung fehlgeschlagen",
                                                              detailText: TranscriptionQueue.detailedErrorMessage(for: error))
                        }
                    }
                }

                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard self.processingRunIsCurrent(runID) else { return }
                        self.clearProcessingRun(runID)
                        self.clearCrashGuard()
                        self.isProcessing = false
                        self.refreshBackgroundContinuation(reason: "pipeline-cancelled-after-chapter-generation")
                        self.postQueueChangeNotification()
                        self.processNext()
                    }
                    return
                }

                var savedChapters: [ICGeneratedChapter] = []
                var savedSummaryCharacterCount = 0
                if let semanticArtifacts, !semanticArtifacts.chapters.isEmpty {
                    do {
                        try await self.saveSemanticArtifacts(semanticArtifacts, for: episodeHash)
                        savedChapters = semanticArtifacts.chapters
                        savedSummaryCharacterCount = semanticArtifacts.summaryCharacterCount
                        NSLog("[TranscriptionQueue] Saved %d chapters for %@", semanticArtifacts.chapters.count, episodeHash)
                    } catch {
                        chapterGenerationError = error
                        await MainActor.run {
                            guard self.processingRunIsCurrent(runID) else { return }
                            TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "error",
                                                              message: "Kapitel konnten nicht gespeichert werden",
                                                              detailText: TranscriptionQueue.detailedErrorMessage(for: error))
                        }
                    }
                }
                await MainActor.run {
                    guard self.processingRunIsCurrent(runID) else { return }
                    let elapsed = -chapterStart.timeIntervalSinceNow
                    let count = savedChapters.count
                    let sponsors = savedChapters.filter { $0.isSponsor }.count
                    let message: String
                    if count > 0 {
                        message = savedSummaryCharacterCount > 0 ? "Episodenanalyse gespeichert" : "Kapitel gespeichert"
                    } else if let semanticArtifacts, !semanticArtifacts.chapters.isEmpty {
                        message = "Keine Kapitel gespeichert"
                    } else {
                        message = "Keine Kapitel erzeugt"
                    }
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "chapters",
                                                      message: message,
                                                      detailText: String(format: "%.1f s, %d Kapitel, %d Sponsor, %d Summary-Zeichen", elapsed, count, sponsors, savedSummaryCharacterCount))
                }
                ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "chapters-finished", audioURL: audioURL)
            }

            // Done!
            await MainActor.run {
                guard self.processingRunIsCurrent(runID) else { return }
                // Success — pipeline completed cleanly, drop the crash guard.
                self.clearProcessingRun(runID)
                self.clearCrashGuard()
                if let chapterGenerationError {
                    let headline = NSLocalizedString("Transkription abgeschlossen, Kapitel fehlgeschlagen.", comment: "")
                    let detail = TranscriptionQueue.detailedErrorMessage(for: chapterGenerationError)
                    if self.scheduleRetry(for: item, error: chapterGenerationError, stage: "analysis-after-transcription") {
                        self.isProcessing = false
                        self.currentTask = nil
                        self.refreshBackgroundContinuation(reason: "pipeline-analysis-retry-scheduled")
                        self.postQueueChangeNotification()
                        self.postFinishNotification(episodeHash: episodeHash)
                        TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "done",
                                                          message: headline, detailText: detail)
                        NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])
                        self.processNext()
                        return
                    }
                    item.status = .failed
                    item.progress = 1.0
                    item.error = [headline, detail].filter { !$0.isEmpty }.joined(separator: "\n")
                    item.statusDetail = nil
                    item.statusStartedAt = nil
                    item.completedAt = nil
                    self.isProcessing = false
                    self.persistQueue()
                    self.refreshBackgroundContinuation(reason: "pipeline-chapters-failed")
                    self.postQueueChangeNotification()
                    self.postFinishNotification(episodeHash: episodeHash)
                    TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "done",
                                                      message: headline, detailText: detail)
                    NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])
                    if !UserDefaults.standard.bool(forKey: "TranscriptionEverActivated") {
                        UserDefaults.standard.set(true, forKey: "TranscriptionEverActivated")
                    }
                    self.processNext()
                    return
                }
                item.status = .completed
                item.progress = 1.0
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.completedAt = Date()
                item.retryAttempt = 0
                item.remoteAnalysisReplacementAttempts = 0
                item.lastCountedRemoteAnalysisJobKey = nil
                item.lastCountedRemoteAnalysisResponseID = nil
                item.nextRetryAt = nil
                self.isProcessing = false
                self.persistQueue { error in
                    guard error == nil else { return }
                    Task { @MainActor in
                        ChapterGenerator.shared.finalizeOpenAIBackgroundJobAfterPersistedAnalysis(
                            for: episodeHash
                        )
                    }
                }
                self.refreshBackgroundContinuation(reason: "pipeline-finished")
                self.postQueueChangeNotification()
                self.postFinishNotification(episodeHash: episodeHash)
                self.scheduleCompletedItemPrune()
                TranscriptionLogger.shared.append(episodeHash: episodeHash, phase: "done",
                                                  message: "Gesamter Durchlauf abgeschlossen", detailText: nil)
                // Notify player + cells that transcript is available
                NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"), object: nil, userInfo: ["episodeHash": episodeHash])

                // Mark that transcription has been used at least once
                if !UserDefaults.standard.bool(forKey: "TranscriptionEverActivated") {
                    UserDefaults.standard.set(true, forKey: "TranscriptionEverActivated")
                    // Auto-transcription defaults stay OFF — user enables manually
                }

                // Process next item
                self.processNext()
            }
            ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "pipeline-finished", audioURL: audioURL)
        }
    }

    // MARK: - Checkpoint Failures (OOM Protection)

    private func loadCheckpointFailures(for episodeHash: String) -> Int? {
        let url = engine.transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_checkpoint.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let failures = json["consecutiveFailures"] as? Int else {
            return nil
        }
        return failures
    }

    // MARK: - Audio URL Resolution (via ObjC bridged classes)

    private func resolveAudioURL(for episodeHash: String) -> URL? {
        guard let episode = findEpisode(hash: episodeHash) else { return nil }
        return resolveAudioURL(for: episode)
    }

    private func resolveAudioURL(for episode: CDEpisode) -> URL? {
        guard let cman = CacheManager.shared(), cman.episodeIsCached(episode) else { return nil }
        guard let url = cman.url(forCachedEpisode: episode),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func findEpisode(hash: String) -> CDEpisode? {
        findEpisodes(hashes: [hash])[hash]
    }

    private func findEpisodes(hashes: Set<String>) -> [String: CDEpisode] {
        guard !hashes.isEmpty, let dmanager = DatabaseManager.shared() else { return [:] }
        var episodesByHash: [String: CDEpisode] = [:]
        episodesByHash.reserveCapacity(hashes.count)
        let episodes = dmanager.episodes(withObjectHashes: hashes.sorted()) as? [CDEpisode] ?? []
        for episode in episodes {
            guard let hash = episode.objectHash, hashes.contains(hash) else { continue }
            episodesByHash[hash] = episode
        }
        return episodesByHash
    }

    private static func debugStatusName(_ status: ICTranscriptionStatus) -> String {
        switch status {
        case .none: return "none"
        case .queued: return "queued"
        case .downloadingModel: return "downloadingModel"
        case .analyzingMusic: return "analyzingMusic"
        case .transcribing: return "transcribing"
        case .generatingChapters: return "generatingChapters"
        case .completed: return "completed"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }

    private static func debugTimestampString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func debugFileSnapshot(_ url: URL) -> NSDictionary {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = attributes?[.modificationDate] as? Date
        return [
            "path": url.path,
            "exists": FileManager.default.fileExists(atPath: url.path),
            "bytes": size,
            "modifiedAt": modified.map(debugTimestampString) ?? "",
        ] as NSDictionary
    }

    private func autoDownloadEpisode(hash: String) -> (started: Bool, error: NSError?) {
        guard let episode = findEpisode(hash: hash) else {
            return (false, NSError(
                domain: "TranscriptionQueue",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Audiodatei nicht verfügbar.", comment: "")]
            ))
        }
        guard let cman = CacheManager.shared() else {
            return (false, NSError(
                domain: "TranscriptionQueue",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Audiodatei nicht verfügbar.", comment: "")]
            ))
        }

        if cman.episodeIsCached(episode) {
            return (false, NSError(
                domain: "TranscriptionQueue",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Audiodatei nicht verfügbar.", comment: "")]
            ))
        }

        pendingDownloadHashes.insert(hash)
        let started = cman.cacheEpisode(episode, overwriteCellularLock: true, reportsFailureToUser: false)
        if !started {
            pendingDownloadHashes.remove(hash)
            let error = cman.downloadError(for: episode) as NSError?
            cman.clearDownloadError(for: episode)
            return (false, error)
        }
        refreshBackgroundContinuation(reason: "auto-download-started")
        return (true, nil)
    }

    /// Called when ANY download completes — checks if it was a pending auto-download
    private func _handleDownloadCompletion() {
        guard !pendingDownloadHashes.isEmpty else { return }

        var hashesToRemove: [String] = []
        for hash in pendingDownloadHashes {
            // Check if item is still in queue
            guard let item = items.first(where: { $0.episodeHash == hash && $0.status == .queued }) else {
                // Item was removed from queue — clean up pending hash
                hashesToRemove.append(hash)
                continue
            }

            if let url = resolveAudioURL(for: hash) {
                item.audioURL = url
                item.error = nil
                item.statusDetail = nil
                hashesToRemove.append(hash)
                NSLog("[TranscriptionQueue] Episode downloaded, resuming transcription for %@", hash)
                // Remove processed hashes before calling processNext
                for h in hashesToRemove { pendingDownloadHashes.remove(h) }
                if !isProcessing {
                    processNext()
                }
                return
            }
            // resolveAudioURL returned nil — download might still be in progress or failed
            // Don't remove yet, will retry on next notification
        }
        // Clean up orphaned hashes
        for h in hashesToRemove { pendingDownloadHashes.remove(h) }
    }

    private func _handleDownloadFailure(episodeHash: String, message: String, error: NSError?) {
        guard pendingDownloadHashes.remove(episodeHash) != nil else { return }
        if let item = items.first(where: { $0.episodeHash == episodeHash && $0.status == .queued }) {
            let shouldRetry = error.map { scheduleRetry(for: item, error: $0, stage: "episode-download") } ?? false
            if !shouldRetry {
                item.status = .failed
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.nextRetryAt = nil
                item.error = message
            }
            TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                              phase: "download",
                                              message: "Automatischer Download fehlgeschlagen",
                                              detailText: message)
            persistQueue()
            postQueueChangeNotification()
        }
        refreshBackgroundContinuation(reason: "auto-download-failed")
        if !isProcessing {
            processNext()
        }
    }

    // MARK: - Episode Deletion Handling

    @objc private func cacheIndexDidFinishBuilding(_ notification: Notification) {
        resumeIfNeeded()
    }

    /// A pre-delete queue snapshot can survive an app termination without its terminal
    /// notification. The completed launch-time disk index is the authoritative outcome:
    /// files still present mean rollback/incomplete deletion, absent files mean success.
    private func reconcilePendingCacheDeletionsIfReady() -> Bool {
        guard !pendingCacheDeletionHashes.isEmpty else { return true }
        guard let cman = CacheManager.shared() else { return false }
        cman.prepareCacheIndexIfNeeded()
        guard cman.isCacheIndexReady else { return false }

        let cachedHashes = cman.cachedEpisodeObjectHashes ?? []
        let deletedHashes = pendingCacheDeletionHashes.subtracting(cachedHashes)
        pendingCacheDeletionHashes.removeAll()
        pendingDownloadHashes.subtract(deletedHashes)
        items.removeAll { deletedHashes.contains($0.episodeHash) }
        persistQueue()
        postQueueChangeNotification()
        return true
    }

    private func cacheDeletionHashes(from notification: Notification, allUsesPending: Bool) -> Set<String> {
        if (notification.userInfo?["all"] as? NSNumber)?.boolValue == true {
            return allUsesPending ? pendingCacheDeletionHashes : Set(items.map(\.episodeHash))
        }
        var hashes = Set(notification.userInfo?["episodeHashes"] as? [String] ?? [])
        if let episode = notification.userInfo?["episode"] as? NSObject,
           let legacyHash = episode.value(forKey: "objectHash") as? String,
           !legacyHash.isEmpty {
            hashes.insert(legacyHash)
        }
        return hashes
    }

    private func suspendTranscriptionForCacheDeletion(
        item: ICTranscriptionQueueItem,
        episodeHash: String
    ) {
        let activeStatuses: Set<ICTranscriptionStatus> = [.transcribing, .analyzingMusic, .downloadingModel, .generatingChapters]
        if activeStatuses.contains(item.status) {
            invalidateProcessingRun()
            currentTask?.cancel()
            currentTask = nil
            chapterTask?.cancel()
            chapterTask = nil
            engine.cancelTranscription()
            analyzer.cancelAnalysis()
            isProcessing = false
            item.status = .queued
            item.progress = 0
            item.statusDetail = nil
            item.statusStartedAt = nil
            item.error = nil
        }
        pendingDownloadHashes.remove(episodeHash)
    }

    @objc private func cacheFilesWillBeDeleted(_ notification: Notification) {
        if (notification.userInfo?["all"] as? NSNumber)?.boolValue == true {
            cacheClearInProgress = true
        }
        let hashes = cacheDeletionHashes(from: notification, allUsesPending: false)
        guard !hashes.isEmpty else { return }
        pendingCacheDeletionHashes.formUnion(hashes)
        var itemsByHash: [String: ICTranscriptionQueueItem] = [:]
        for item in items {
            itemsByHash[item.episodeHash] = item
        }
        for hash in hashes {
            guard let item = itemsByHash[hash] else { continue }
            suspendTranscriptionForCacheDeletion(item: item, episodeHash: hash)
        }

        let preparation = notification.userInfo?["cacheDeletionPreparation"] as? ICCacheDeletionPreparation
        preparation?.beginPreparation()
        persistQueue(cacheDeletionPreparation: preparation)
        postQueueChangeNotification()
        if !isProcessing {
            processNext()
        }
    }

    @objc private func cacheFilesWereDeleted(_ notification: Notification) {
        let clearsAll = (notification.userInfo?["all"] as? NSNumber)?.boolValue == true
        let hashes = clearsAll
            ? pendingCacheDeletionHashes.union(items.map(\.episodeHash))
            : cacheDeletionHashes(from: notification, allUsesPending: true)
        if clearsAll {
            cacheClearInProgress = false
        }
        guard !hashes.isEmpty else { return }
        pendingCacheDeletionHashes.subtract(hashes)
        pendingDownloadHashes.subtract(hashes)
        if clearsAll {
            items.removeAll()
        } else {
            items.removeAll { hashes.contains($0.episodeHash) }
        }
        persistQueue()
        postQueueChangeNotification()
        if !isProcessing {
            processNext()
        }
    }

    @objc private func cacheDeletionWasRestored(_ notification: Notification) {
        let restoresAll = (notification.userInfo?["all"] as? NSNumber)?.boolValue == true
        let hashes = cacheDeletionHashes(from: notification, allUsesPending: true)
        if restoresAll {
            cacheClearInProgress = false
        }
        guard !hashes.isEmpty else {
            if !isProcessing { processNext() }
            return
        }
        pendingCacheDeletionHashes.subtract(hashes)
        persistQueue()
        postQueueChangeNotification()
        if !isProcessing {
            processNext()
        }
    }

    // MARK: - Persistence

    private var queueFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TranscriptionQueue.json")
    }

    private func persistQueue(cacheDeletionPreparation: ICCacheDeletionPreparation? = nil,
                              completion: (@Sendable (NSError?) -> Void)? = nil) {
        let now = Date()
        let persistable = PersistedQueue(
            items: items.compactMap { item -> PersistedQueue.PersistedItem? in
                let shouldResumeAsChapterOnly = item.chapterOnly || (item.status == .generatingChapters && engine.hasSRT(for: item.episodeHash))
                if item.status == .failed {
                    return .init(episodeHash: item.episodeHash,
                                 episodeTitle: item.episodeTitle,
                                 feedTitle: item.feedTitle,
                                 language: item.language,
                                 statusRawValue: item.status.rawValue,
                                 completedAt: item.completedAt ?? now,
                                 chapterOnly: shouldResumeAsChapterOnly,
                                 error: item.error,
                                 automaticallyScheduled: item.automaticallyScheduled,
                                 shouldGenerateAnalysis: item.shouldGenerateAnalysis,
                                 retryAttempt: item.retryAttempt,
                                 remoteAnalysisReplacementAttempts: item.remoteAnalysisReplacementAttempts,
                                 lastCountedRemoteAnalysisJobKey: item.lastCountedRemoteAnalysisJobKey,
                                 lastCountedRemoteAnalysisResponseID: item.lastCountedRemoteAnalysisResponseID,
                                 nextRetryAt: item.nextRetryAt,
                                 requiresExplicitRetryAfterCrash: item.requiresExplicitRetryAfterCrash)
                }
                if item.status == .completed {
                    guard let completedAt = item.completedAt,
                          now.timeIntervalSince(completedAt) < Self.completedItemRetentionInterval else { return nil }
                    return .init(episodeHash: item.episodeHash,
                                 episodeTitle: item.episodeTitle,
                                 feedTitle: item.feedTitle,
                                 language: item.language,
                                 statusRawValue: item.status.rawValue,
                                 completedAt: completedAt,
                                 chapterOnly: item.chapterOnly,
                                 error: nil,
                                 automaticallyScheduled: item.automaticallyScheduled,
                                 shouldGenerateAnalysis: item.shouldGenerateAnalysis,
                                 retryAttempt: item.retryAttempt,
                                 remoteAnalysisReplacementAttempts: item.remoteAnalysisReplacementAttempts,
                                 lastCountedRemoteAnalysisJobKey: item.lastCountedRemoteAnalysisJobKey,
                                 lastCountedRemoteAnalysisResponseID: item.lastCountedRemoteAnalysisResponseID,
                                 nextRetryAt: nil,
                                 requiresExplicitRetryAfterCrash: false)
                }
                return .init(episodeHash: item.episodeHash,
                             episodeTitle: item.episodeTitle,
                             feedTitle: item.feedTitle,
                             language: item.language,
                             statusRawValue: item.status.rawValue,
                             completedAt: nil,
                             chapterOnly: shouldResumeAsChapterOnly,
                             error: item.error,
                             automaticallyScheduled: item.automaticallyScheduled,
                             shouldGenerateAnalysis: item.shouldGenerateAnalysis,
                             retryAttempt: item.retryAttempt,
                             remoteAnalysisReplacementAttempts: item.remoteAnalysisReplacementAttempts,
                             lastCountedRemoteAnalysisJobKey: item.lastCountedRemoteAnalysisJobKey,
                             lastCountedRemoteAnalysisResponseID: item.lastCountedRemoteAnalysisResponseID,
                             nextRetryAt: item.nextRetryAt,
                             requiresExplicitRetryAfterCrash: item.requiresExplicitRetryAfterCrash)
            },
            pendingCacheDeletionHashes: pendingCacheDeletionHashes.sorted()
        )
        do {
            let data = try JSONEncoder().encode(persistable)
            pendingQueuePersistenceCount += 1
            ICWritePersistedTranscriptionQueueData(data, to: queueFileURL) { error in
                cacheDeletionPreparation?.finishPreparation(withError: error)
                completion?(error)
                Task { @MainActor in
                    self.lastQueuePersistenceError = error
                    self.pendingQueuePersistenceCount -= 1
                    if self.pendingQueuePersistenceCount == 0 {
                        self.postQueueChangeNotification()
                    }
                }
            }
        } catch {
            NSLog("[TranscriptionQueue] Queue encoding failed: %@", (error as NSError).localizedDescription)
            lastQueuePersistenceError = error as NSError
            cacheDeletionPreparation?.finishPreparation(withError: error as NSError)
            completion?(error as NSError)
            postQueueChangeNotification()
        }
    }

    private func loadPersistedQueue() {
        guard let data = try? Data(contentsOf: queueFileURL),
              let persisted = try? JSONDecoder().decode(PersistedQueue.self, from: data) else {
            return
        }
        pendingCacheDeletionHashes = Set(persisted.pendingCacheDeletionHashes ?? [])
        var committedAnalysisHashesToFinalize: [String] = []

        // Reconstruct items - audio URLs need to be resolved from CacheManager
        for pItem in persisted.items {
            if pItem.statusRawValue == ICTranscriptionStatus.failed.rawValue {
                guard let failedAt = pItem.completedAt,
                      Date().timeIntervalSince(failedAt) < Self.completedItemRetentionInterval else { continue }
                let item = ICTranscriptionQueueItem(
                    episodeHash: pItem.episodeHash,
                    episodeTitle: pItem.episodeTitle,
                    feedTitle: pItem.feedTitle,
                    audioURL: nil,
                    language: pItem.language
                )
                item.status = .failed
                item.progress = 0
                item.completedAt = failedAt
                item.chapterOnly = pItem.chapterOnly == true
                item.error = pItem.error
                restorePersistedIntent(pItem, to: item)
                items.append(item)
                continue
            }

            if pItem.statusRawValue == ICTranscriptionStatus.completed.rawValue {
                guard let completedAt = pItem.completedAt,
                      Date().timeIntervalSince(completedAt) < Self.completedItemRetentionInterval else { continue }
                let item = ICTranscriptionQueueItem(
                    episodeHash: pItem.episodeHash,
                    episodeTitle: pItem.episodeTitle,
                    feedTitle: pItem.feedTitle,
                    audioURL: nil,
                    language: pItem.language
                )
                item.status = .completed
                item.progress = 1.0
                item.completedAt = completedAt
                item.chapterOnly = pItem.chapterOnly == true
                restorePersistedIntent(pItem, to: item)
                items.append(item)
                if ChapterGenerator.shared.hasValidAnalysis(for: pItem.episodeHash) {
                    committedAnalysisHashesToFinalize.append(pItem.episodeHash)
                }
                continue
            }

            if pItem.chapterOnly == true {
                if pItem.shouldGenerateAnalysis,
                   ChapterGenerator.shared.hasValidAnalysis(for: pItem.episodeHash) {
                    committedAnalysisHashesToFinalize.append(pItem.episodeHash)
                    ICDiagnosticLogger.shared.logEvent(
                        "queue",
                        message: "Persistierter Analysejob durch atomaren Analyse-Commit abgeschlossen",
                        metadata: ["episodeHash": pItem.episodeHash] as NSDictionary
                    )
                    continue
                }
                guard hasChapterGenerationTranscript(episodeHash: pItem.episodeHash) else {
                    ICDiagnosticLogger.shared.logEvent("queue", message: "Persistierter Kapitel-Job ohne Transkript übersprungen", metadata: [
                        "episodeHash": pItem.episodeHash,
                    ] as NSDictionary)
                    continue
                }
                let item = ICTranscriptionQueueItem(
                    episodeHash: pItem.episodeHash,
                    episodeTitle: pItem.episodeTitle,
                    feedTitle: pItem.feedTitle,
                    audioURL: nil,
                    language: pItem.language
                )
                item.chapterOnly = true
                item.status = .queued
                restorePersistedIntent(pItem, to: item)
                items.append(item)
                continue
            }

            if engine.hasSRT(for: pItem.episodeHash) {
                guard pItem.shouldGenerateAnalysis else { continue }
                let selectedChapterModel = ICDownloadableModelStore.selectedModel(for: .textToChapters)
                let semanticResultExists = selectedChapterModel.usesRemoteChapterService
                    ? ChapterGenerator.shared.hasValidAnalysis(for: pItem.episodeHash)
                    : ChapterGenerator.shared.hasChapters(for: pItem.episodeHash)
                guard !semanticResultExists else {
                    if ChapterGenerator.shared.hasValidAnalysis(for: pItem.episodeHash) {
                        committedAnalysisHashesToFinalize.append(pItem.episodeHash)
                    }
                    continue
                }

                let item = ICTranscriptionQueueItem(
                    episodeHash: pItem.episodeHash,
                    episodeTitle: pItem.episodeTitle,
                    feedTitle: pItem.feedTitle,
                    audioURL: nil,
                    language: pItem.language
                )
                item.chapterOnly = true
                item.status = .queued
                restorePersistedIntent(pItem, to: item)
                items.append(item)
                ICDiagnosticLogger.shared.logEvent("queue", message: "Persistierten Job nach fertigem SRT in Analysephase wiederhergestellt", metadata: [
                    "episodeHash": pItem.episodeHash,
                    "automaticallyScheduled": pItem.automaticallyScheduled,
                    "retryAttempt": pItem.retryAttempt ?? 0,
                ] as NSDictionary)
                continue
            }

            let item = ICTranscriptionQueueItem(
                episodeHash: pItem.episodeHash,
                episodeTitle: pItem.episodeTitle,
                feedTitle: pItem.feedTitle,
                audioURL: nil, // Will be resolved when processing starts
                language: pItem.language
            )
            item.status = .queued
            restorePersistedIntent(pItem, to: item)
            items.append(item)
        }
        if items.contains(where: { $0.status == .completed }) {
            scheduleCompletedItemPrune()
        }
        if !committedAnalysisHashesToFinalize.isEmpty {
            let finalizedHashes = committedAnalysisHashesToFinalize
            persistQueue { error in
                guard error == nil else { return }
                Task { @MainActor in
                    for episodeHash in finalizedHashes {
                        ChapterGenerator.shared.finalizeOpenAIBackgroundJobAfterPersistedAnalysis(
                            for: episodeHash
                        )
                    }
                }
            }
        }
    }

    private func restorePersistedIntent(_ persisted: PersistedQueue.PersistedItem,
                                        to item: ICTranscriptionQueueItem) {
        item.automaticallyScheduled = persisted.automaticallyScheduled
        item.shouldGenerateAnalysis = persisted.shouldGenerateAnalysis
        item.retryAttempt = persisted.retryAttempt ?? 0
        item.remoteAnalysisReplacementAttempts = persisted.remoteAnalysisReplacementAttempts ?? 0
        item.lastCountedRemoteAnalysisJobKey = persisted.lastCountedRemoteAnalysisJobKey
        item.lastCountedRemoteAnalysisResponseID = persisted.lastCountedRemoteAnalysisResponseID
        item.nextRetryAt = persisted.nextRetryAt
        item.requiresExplicitRetryAfterCrash = persisted.requiresExplicitRetryAfterCrash
        if item.status == .queued {
            item.error = persisted.error
        }
    }

    // MARK: - Notifications (throttled to avoid UI spam)

    private var lastProgressNotificationDate: Date?

    private func beginStep(for item: ICTranscriptionQueueItem,
                           status: ICTranscriptionStatus,
                           detail: String?) {
        let didChangeStatus = item.status != status
        item.status = status
        item.progress = 0
        item.progressBaseline = 0
        item.progressBaselineStartedAt = nil
        item.statusDetail = detail
        item.error = nil
        item.completedAt = nil
        if didChangeStatus || item.statusStartedAt == nil {
            item.statusStartedAt = Date()
        }
        ICDiagnosticLogger.shared.logEvent("queue-step", message: "Queue-Schritt gewechselt", metadata: [
            "episodeHash": item.episodeHash,
            "status": "\(status.rawValue)",
            "detail": detail ?? "",
        ] as NSDictionary)
        persistQueue()
    }

    private func recordProgressSample(for item: ICTranscriptionQueueItem,
                                      progress: Float,
                                      status: ICTranscriptionStatus) {
        if item.status != status || item.progressBaselineStartedAt == nil {
            item.progressBaseline = progress
            item.progressBaselineStartedAt = Date()
        }
        item.status = status
        item.progress = progress
    }

    private func updateStatusDetail(for episodeHash: String, detail: String) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash }) else { return }
        guard item.statusDetail != detail else { return }
        item.statusDetail = detail
        ICDiagnosticLogger.shared.logEvent("queue-detail", message: detail, metadata: [
            "episodeHash": episodeHash,
            "status": "\(item.status.rawValue)",
        ] as NSDictionary)
        postProgressNotification(episodeHash: episodeHash, progress: item.progress, status: item.status, force: true)
    }

    private nonisolated static func detailedErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        var parts: [String] = []

        func appendIfNeeded(_ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  !parts.contains(text) else { return }
            parts.append(text)
        }

        appendIfNeeded(nsError.localizedDescription)
        appendIfNeeded(nsError.localizedFailureReason)
        appendIfNeeded(nsError.localizedRecoverySuggestion)

        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        while let current = underlying {
            appendIfNeeded(current.localizedDescription)
            appendIfNeeded(current.localizedFailureReason)
            appendIfNeeded(current.localizedRecoverySuggestion)
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }

        return parts.isEmpty ? NSLocalizedString("Unbekannter Fehler.", comment: "") : parts.joined(separator: "\n")
    }

    private func postQueueChangeNotification() {
        NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionQueueDidChangeNotification"), object: nil)
    }

    private func postProgressNotification(episodeHash: String, progress: Float, status: ICTranscriptionStatus, force: Bool = false) {
        // Throttle: max once per 0.5 seconds
        let now = Date()
        if !force, let last = lastProgressNotificationDate, now.timeIntervalSince(last) < 0.5 {
            return
        }
        lastProgressNotificationDate = now
        NotificationCenter.default.post(
            name: NSNotification.Name("ICTranscriptionDidProgressNotification"),
            object: nil,
            userInfo: ["episodeHash": episodeHash, "progress": progress, "status": status.rawValue]
        )
    }

    private func postFinishNotification(episodeHash: String) {
        NotificationCenter.default.post(
            name: NSNotification.Name("ICTranscriptionDidFinishNotification"),
            object: nil,
            userInfo: ["episodeHash": episodeHash]
        )
    }
}
