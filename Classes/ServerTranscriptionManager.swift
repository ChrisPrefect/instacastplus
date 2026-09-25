//
//  ServerTranscriptionManager.swift
//  Instacast
//
//  Durable client for the shared Instacast transcription service.
//

import CryptoKit
import Foundation
import Network

/// Shared transport bounds each decoded response before buffering it in full.
/// Delegate work runs off the UI actor; cancellation completes each waiter once.
private final class ICServerHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ICServerHTTPClient()
    static let maximumEnvelopeBytes = 1024 * 1024
    static let maximumArtifactBytes = 25 * 1024 * 1024
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private let resourceTimeout: TimeInterval
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    init(resourceTimeout: TimeInterval = 120) {
        self.resourceTimeout = resourceTimeout
        super.init()
        _ = session
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let transfer = Transfer(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                transfers[task.taskIdentifier] = transfer
                lock.unlock()
                transfer.start(task: task, continuation: continuation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    private func transfer(for task: URLSessionTask, remove: Bool = false) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return remove ? transfers.removeValue(forKey: task.taskIdentifier) : transfers[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        completionHandler(transfer(for: dataTask)?.accept(response) == true ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        transfer(for: dataTask)?.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        transfer(for: task, remove: true)?.finish(error: error)
    }

    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private var data = Data()
        private var response: URLResponse?
        private var task: URLSessionDataTask?
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        private var terminalError: Error?
        private var completed = false

        init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

        func start(task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            lock.lock()
            self.task = task
            self.continuation = continuation
            let error = terminalError
            lock.unlock()
            if let error { finish(error: error) }
            task.resume()
        }

        func cancel() { finish(error: CancellationError()) }

        func accept(_ response: URLResponse) -> Bool {
            lock.lock()
            let exceedsLimit = response.expectedContentLength > Int64(maximumBytes) || maximumBytes <= 0
            let allowed = !completed && terminalError == nil && !exceedsLimit
            if allowed { self.response = response }
            lock.unlock()
            if exceedsLimit { finish(error: Self.sizeError()) }
            return allowed
        }

        func append(_ chunk: Data) {
            lock.lock()
            let exceedsLimit = chunk.count > maximumBytes - data.count
            if !completed && !exceedsLimit { data.append(chunk) }
            lock.unlock()
            if exceedsLimit { finish(error: Self.sizeError()) }
        }

        func finish(error: Error?) {
            lock.lock()
            if completed { lock.unlock(); return }
            if let error { terminalError = error }
            guard let continuation else { lock.unlock(); return }
            self.continuation = nil
            completed = true
            let result: Result<(Data, URLResponse), Error>
            if let error = terminalError { result = .failure(error) }
            else if let response { result = .success((data, response)) }
            else { result = .failure(URLError(.badServerResponse)) }
            let taskToCancel = terminalError != nil ? task : nil
            data = Data()
            lock.unlock()
            taskToCancel?.cancel()
            continuation.resume(with: result)
        }

        private static func sizeError() -> NSError {
            NSError(domain: "ICServerTranscription", code: 24,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("The transcription server response exceeds the permitted size.", comment: "")])
        }
    }
}

/// A missing snapshot is an empty queue; any other read/decode failure still owns its contents.
enum ICQueueSnapshotStorage {
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) { return nil }
            throw error
        }
        return try JSONDecoder().decode(type, from: data)
    }

    static func loadError(_ error: Error) -> NSError {
        let nsError = error as NSError
        if nsError.domain == "ICServerTranscription" && nsError.code == 23 { return nsError }
        let message = error is DecodingError
            ? NSLocalizedString("The saved transcription queue is damaged or incompatible. Existing data has not been replaced.", comment: "")
            : NSLocalizedString("The saved transcription queue could not be read. Existing jobs and cancellations remain protected. Unlock the device or resolve the storage problem, then retry.", comment: "")
        return NSError(domain: "TranscriptionQueue.Storage", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: error])
    }
}

private struct ICServerEpisodeEnvelope: Decodable {
    let apiVersion: String
    let episode: ICServerEpisode
    let retryAfterSeconds: Int?
    let serviceStatus: ICServerServiceStatus?
    let clientRequest: ICServerClientRequest?

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case episode
        case retryAfterSeconds = "retry_after_seconds"
        case serviceStatus = "service_status"
        case clientRequest = "client_request"
    }
}

private struct ICServerClientRequest: Decodable {
    let id: String?
    let state: String
    let episodeID: Int?

    enum CodingKeys: String, CodingKey {
        case id, state
        case episodeID = "episode_id"
    }
}

private struct ICServerCancellationReceipt: Decodable {
    let apiVersion: String
    let clientRequest: ICServerClientRequest

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case clientRequest = "client_request"
    }
}

private struct ICServerServiceStatus: Decodable {
    let available: Bool
    let code: String
}

private struct ICServerMedia: Decodable {
    let audioSHA256: String?
    enum CodingKeys: String, CodingKey { case audioSHA256 = "audio_sha256" }
}

private struct ICServerEpisode: Decodable {
    let id: Int
    let status: String
    let phase: String
    let progress: Double?
    let serverDurationSeconds: Double?
    let warnings: [ICServerWarning]
    let error: ICServerError?
    let artifacts: [ICServerArtifact]
    let media: ICServerMedia?

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case phase
        case progress
        case serverDurationSeconds = "server_duration_seconds"
        case warnings
        case error
        case artifacts, media
    }
}

private struct ICServerArtifact: Decodable {
    let id: Int
    let kind: String
    let url: URL
    let contentType: String
    let byteSize: Int
    let sha256: String
    let transcriptRevision: String
    let etag: String

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case url
        case contentType = "content_type"
        case byteSize = "byte_size"
        case sha256
        case transcriptRevision = "transcript_revision"
        case etag
    }
}

private struct ICServerWarning: Decodable {
    let code: String
    let message: String
    let timingMayBeShifted: Bool?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case timingMayBeShifted = "timing_may_be_shifted"
    }
}

private struct ICServerError: Decodable {
    let code: String
    let message: String
    let retryable: Bool
    let admitted: Bool?
    let maxAudioBytes: Int64?
    let maxDurationSeconds: Double?
    let sourceStatus: Int?

    enum CodingKeys: String, CodingKey {
        case code, message, retryable, admitted
        case maxAudioBytes = "max_audio_bytes"
        case maxDurationSeconds = "max_duration_seconds"
        case sourceStatus = "source_status"
    }

    var localizedMessage: String {
        switch code {
        case "audio_too_large":
            if let maxAudioBytes, maxAudioBytes > 0 {
                return String(format: NSLocalizedString("The audio file exceeds the server limit of %@.", comment: ""), ByteCountFormatter.string(fromByteCount: maxAudioBytes, countStyle: .file))
            }
            return NSLocalizedString("The audio file is too large for server transcription.", comment: "")
        case "audio_duration_exceeded":
            if let maxDurationSeconds, maxDurationSeconds.isFinite, maxDurationSeconds > 0 {
                let hours = NumberFormatter.localizedString(from: NSNumber(value: maxDurationSeconds / 3600), number: .decimal)
                return String(format: NSLocalizedString("The audio exceeds the server limit of %@ hours.", comment: ""), hours)
            }
            return NSLocalizedString("The audio is too long for server transcription.", comment: "")
        case "audio_source_mismatch":
            return NSLocalizedString("This episode was delivered in a different audio version. Server transcription is unavailable for this download.", comment: "")
        case "audio_identity_required":
            return NSLocalizedString("Start transcription again so the audio file can be verified.", comment: "")
        case "audio_duration_invalid":
            return NSLocalizedString("The audio duration could not be read. No transcript was created.", comment: "")
        case "source_audio_unavailable":
            if let sourceStatus, sourceStatus == 404 || sourceStatus == 410 {
                return String(format: NSLocalizedString("The episode's audio file is unavailable from the publisher (HTTP %ld).", comment: ""), sourceStatus)
            }
            return NSLocalizedString("The episode's audio file is unavailable from the publisher.", comment: "")
        case "no_speech":
            return NSLocalizedString("Speech recognition returned no text. No transcript was created for this episode.", comment: "")
        case "unsupported_language":
            return NSLocalizedString("The configured speech-recognition language is not supported. No transcript was created.", comment: "")
        case "processing_timeout":
            return NSLocalizedString("Processing exceeded the server time limit. Try again later.", comment: "")
        case "transcription_failed":
            return NSLocalizedString("Server transcription could not be completed. Try again later.", comment: "")
        default:
            return message
        }
    }
}

private struct ICServerAPIErrorEnvelope: Decodable {
    let apiVersion: String?
    let error: ICServerError
    enum CodingKeys: String, CodingKey { case apiVersion = "api_version", error }
}

private struct ICServerSummaryArtifact: Decodable, Sendable {
    let schemaVersion: Int
    let transcriptRevision: String
    let audioDurationSeconds: Double
    let summary: String
    let topicTitles: [String]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transcriptRevision = "transcript_revision"
        case audioDurationSeconds = "audio_duration_seconds"
        case summary
        case topicTitles = "topic_titles"
    }
}

private struct ICServerChaptersArtifact: Decodable, Sendable {
    struct Chapter: Decodable, Sendable {
        let start: Double
        let end: Double
        let title: String
        let isSponsor: Bool

        enum CodingKeys: String, CodingKey {
            case start
            case end
            case title
            case isSponsor = "is_sponsor"
        }
    }

    let schemaVersion: Int
    let transcriptRevision: String
    let audioDurationSeconds: Double
    let chapters: [Chapter]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transcriptRevision = "transcript_revision"
        case audioDurationSeconds = "audio_duration_seconds"
        case chapters
    }
}

private struct ICServerAdsArtifact: Decodable, Sendable {
    struct Segment: Decodable, Sendable {
        let start: Double
        let end: Double
        let title: String
    }

    let schemaVersion: Int
    let transcriptRevision: String
    let audioDurationSeconds: Double
    let segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case transcriptRevision = "transcript_revision"
        case audioDurationSeconds = "audio_duration_seconds"
        case segments
    }
}

private enum ICServerAdmissionState: String, Codable, Sendable {
    case pending, prepared, unconfirmed, accepted, rejected
}

private struct ICPersistedServerTranscriptionQueue: Codable, Sendable {
    struct Item: Codable, Sendable {
        let episodeHash: String
        let episodeTitle: String
        let feedTitle: String
        let episodeURL: URL
        let podcastURL: URL?
        let duration: Double
        let serverEpisodeID: Int?
        let clientRequestID: String?
        let explicitRestart: Bool?
        let admissionState: ICServerAdmissionState?
        let automaticallyScheduled: Bool
        let statusRawValue: Int
        let error: String?
        let nextRetryAt: Date?
        let completedAt: Date?
        let progress: Float?
        let statusDetail: String?
        let statusStartedAt: Date?
        var requiresExplicitRetry: Bool? = nil
        var retryImportOnly: Bool? = nil
        var sourceAudioSHA256: String? = nil
        var waitingForNetwork: Bool? = nil
        var serverPhase: String? = nil
        var lastResponseAt: Date? = nil
        var connectionIssue: Bool? = nil
    }

    let items: [Item]
    let cancellations: [ICServerCancellation]?
    var ownerClientID: String? = nil
}

private struct ICServerCancellation: Codable, Sendable {
    let id: String
    let episodeHash: String
    let clientRequestID: String?
    let serverEpisodeID: Int?
    var nextRetryAt: Date?
    var error: String?
    var retryable: Bool
}

@MainActor
@objc class ServerTranscriptionManager: NSObject {
    @objc static let shared = ServerTranscriptionManager()
    @objc private(set) var items: [ICTranscriptionQueueItem] = []
    @objc private(set) var queuePersistenceError: NSError?
    private var queueLoadError: NSError?
    private var ownerClientID: String?
    @objc var queueStorageError: NSError? { queueLoadError ?? queuePersistenceError }

    private static let queueFileName = "ServerTranscriptionQueue.json"
    private static let clientIdentifierKey = "ICServerTranscriptionClientIdentifier"
    private static let retryDelay: TimeInterval = 30
    private static let maximumRetryInterval = 86400
    /// Same retention rule as the local queue (TranscriptionQueue.completedItemRetentionInterval).
    private static let completedItemRetentionInterval: TimeInterval = 30 * 60

    // This is a shared application token, intentionally not a per-user credential.
    // Do not log it or include it in diagnostics.
    private static let bearerToken = "ictr_Bp0J1cdWUxrLxGcCI8M0INcCkntohS_yAPysQJUp5mQ"
    #if DEBUG && targetEnvironment(simulator)
    // Dedicated simulator integration tests use a loopback peer; no production token leaves the app.
    static var debugServerURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--server-flow-test-url") else { return nil }
        precondition(index + 1 < arguments.count)
        let url = URL(string: arguments[index + 1])!
        precondition(url.scheme == "http" && url.host == "127.0.0.1" && url.port != nil &&
                     url.path == "/api/v1" && url.user == nil && url.password == nil)
        return url
    }
    private let baseURL = ServerTranscriptionManager.debugServerURL ?? URL(string: "https://transcript.instacast.ch/api/v1/")!
    #else
    private let baseURL = URL(string: "https://transcript.instacast.ch/api/v1/")!
    #endif
    private var authorizationToken: String {
        #if DEBUG && targetEnvironment(simulator)
        if Self.debugServerURL != nil { return "simulator-fixture" }
        #endif
        return Self.bearerToken
    }
    private var endpointByItem: [ObjectIdentifier: URL] = [:]
    private var metadataByItem: [ObjectIdentifier: (podcastURL: URL?, duration: Double)] = [:]
    private var serverIDByItem: [ObjectIdentifier: Int] = [:]
    private var clientRequestIDByItem: [ObjectIdentifier: String] = [:]
    private var explicitRestartByItem: [ObjectIdentifier: Bool] = [:]
    private var sourceAudioSHA256ByItem: [ObjectIdentifier: String] = [:]
    private var retryImportOnlyByItem: [ObjectIdentifier: Bool] = [:]
    private var cancellations: [ICServerCancellation] = []
    private var admissionByItem: [ObjectIdentifier: ICServerAdmissionState] = [:]
    private var admissionCompletions: [ObjectIdentifier: (Bool, String) -> Void] = [:]
    private let networkMonitor = NWPathMonitor()
    private var networkUnavailable = false
    private var cancellationTask: Task<Void, Never>?
    private var needsIdentityPersistence = false
    private var currentTask: Task<Void, Never>?
    private var currentItem: ICTranscriptionQueueItem?
    private var retryWakeTask: Task<Void, Never>?
    private let persistenceQueue = DispatchQueue(label: "com.instacast.server-transcription.persistence", qos: .utility)
    private var pendingPersistenceCount = 0
    private var persistenceCompletions: [(NSError?) -> Void] = []
    private var publishedQueueState: NSDictionary?
    private var publishedProcessingState: Bool?

    /// The initializer must not publish state. `shared` is a `static let`, so init runs
    /// inside `swift_once`: `resumeIfNeeded()` → `processNext()` → `postQueueChange()`
    /// posted a notification while `shared` was still being created, the observer read
    /// `TranscriptionQueue.displayItems`, that re-entered `ServerTranscriptionManager.shared`
    /// and the re-entrant once-token trapped (EXC_BREAKPOINT at launch).
    /// Resuming is owned by the launch/foreground path (`TranscriptionQueue.resumeIfNeeded`).
    private override init() {
        super.init()
        loadPersistedQueue()
        NotificationCenter.default.addObserver(self, selector: #selector(retryQueueStorage),
                                               name: NSNotification.Name("UIApplicationProtectedDataDidBecomeAvailable"), object: nil)
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let unavailable = path.status == .unsatisfied
            Task { @MainActor [weak self] in
                self?.networkUnavailable = unavailable
                if !unavailable { self?.resumeIfNeeded() }
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "com.instacast.server-transcription.network", qos: .utility))
    }

    @objc var isProcessing: Bool { currentItem != nil || cancellationTask != nil || pendingPersistenceCount > 0 }
    @objc var hasPendingCancellations: Bool { !cancellations.isEmpty }
    var hasRetryableCancellations: Bool { cancellations.contains(where: { $0.retryable }) }
    @objc var pendingCancellationCount: Int { cancellations.count }
    @objc var cancellationError: String? { cancellations.first(where: { $0.error != nil })?.error }

    var hasPendingAutomaticItems: Bool {
        hasRetryableCancellations || items.contains {
            !$0.requiresExplicitRetryAfterCrash && $0.status != .completed && $0.status != .failed && $0.status != .canceled
        }
    }

    var earliestAutomaticWorkDate: Date? {
        let pending = items.filter {
            !$0.requiresExplicitRetryAfterCrash && $0.status != .completed && $0.status != .failed && $0.status != .canceled
        }
        let retryableCancellations = cancellations.filter(\.retryable)
        guard !pending.isEmpty || !retryableCancellations.isEmpty else { return nil }
        if pending.contains(where: { $0.nextRetryAt == nil }) || retryableCancellations.contains(where: { $0.nextRetryAt == nil }) { return Date() }
        return (pending.compactMap(\.nextRetryAt) + retryableCancellations.compactMap(\.nextRetryAt)).min()
    }

    @objc func enqueueEpisode(_ episode: CDEpisode, completion: @escaping (Bool, String) -> Void) -> Bool {
        if let error = queueStorageError ?? TranscriptionQueue.shared.queueStorageError {
            completion(false, error.localizedDescription)
            postQueueChange()
            return false
        }
        guard ICAITranscriptionFeaturesAvailable(),
              UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled),
              let episodeHash = episode.objectHash, !episodeHash.isEmpty,
              let episodeURL = episode.preferedMedium()?.fileURL,
              let scheme = episodeURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        let existing = items.first(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription })
        if let existing {
            // Only a run that is still going owns the episode. A finished or failed entry
            // stays in the list until the user removes it — treating it as "already queued"
            // made the episode permanently unsubmittable.
            guard existing.status == .completed || existing.status == .failed || existing.status == .canceled else { return false }
        }
        guard TranscriptionQueue.shared.admitQueueItem(episodeHash: episodeHash, automatic: false) else { return false }
        let restartsServerEpisode = existing.map {
            serverIDByItem[ObjectIdentifier($0)] != nil && ($0.serverPhase == "failed" || $0.status == .canceled)
        } ?? false
        if let existing {
            queueCancellation(for: existing)
            items.removeAll { $0 === existing }
            removeMetadata(for: existing)
        }

        let item = makeItem(episodeHash: episodeHash,
                            episodeTitle: episode.title ?? "",
                            feedTitle: episode.feed?.title ?? "",
                            episodeURL: episodeURL,
                            podcastURL: episode.feed?.sourceURL,
                            duration: Double(max(0, episode.duration)),
                            automaticallyScheduled: false)
        explicitRestartByItem[ObjectIdentifier(item)] = restartsServerEpisode
        items.append(item)
        admissionCompletions[ObjectIdentifier(item)] = completion
        persistQueue()
        TranscriptionLogger.shared.resetLog(episodeHash: episodeHash)
        TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                          phase: "server",
                                          message: NSLocalizedString("Preparing server transcription on this device.", comment: ""),
                                          detailText: nil)
        postQueueChange()
        processNext()
        return true
    }

    /// Existing per-podcast automatic settings decide *whether* a feed is processed.
    /// The selected backend decides that this one server queue is used.
    @objc func enqueueAutomaticEpisodes(_ episodes: [CDEpisode]) -> Bool {
        guard ICAITranscriptionFeaturesAvailable(),
              UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled) else { return false }
        var admittedAny = false
        for episode in episodes {
            guard let episodeHash = episode.objectHash, !episodeHash.isEmpty,
                  let episodeURL = episode.preferedMedium()?.fileURL,
                  let scheme = episodeURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  !items.contains(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription }) else {
                continue
            }
            guard TranscriptionQueue.shared.admitQueueItem(episodeHash: episodeHash, automatic: true) else { break }
            let item = makeItem(episodeHash: episodeHash,
                                episodeTitle: episode.title ?? "",
                                feedTitle: episode.feed?.title ?? "",
                                episodeURL: episodeURL,
                                podcastURL: episode.feed?.sourceURL,
                                duration: Double(max(0, episode.duration)),
                                automaticallyScheduled: true)
            items.append(item)
            admittedAny = true
            TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                              phase: "server",
                                              message: NSLocalizedString("Preparing automatic server transcription on this device.", comment: ""),
                                              detailText: nil)
        }
        guard admittedAny else { return false }
        persistQueue()
        postQueueChange()
        TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
        processNext()
        return true
    }

    @objc func dequeueEpisodeHash(_ episodeHash: String) {
        guard queueLoadError == nil else { postQueueChange(); return }
        guard let item = items.first(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription }) else { return }
        queueCancellation(for: item)
        if currentItem === item {
            currentTask?.cancel()
        }
        items.removeAll { $0 === item }
        removeMetadata(for: item)
        persistQueue()
        postQueueChange()
        TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
        processNext()
    }

    @objc func retryEpisodeHash(_ episodeHash: String) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription }) else { return }
        if item.requiresExplicitRetryAfterCrash {
            item.requiresExplicitRetryAfterCrash = false
            item.status = .queued
            item.error = nil
            item.statusDetail = nil
            item.serverConnectionIssue = false
            item.nextRetryAt = nil
            persistQueue()
            postQueueChange()
            processNext()
            return
        }
        if item.status == .completed || item.status == .failed || item.status == .canceled {
            guard TranscriptionQueue.shared.admitQueueItem(episodeHash: item.episodeHash, automatic: false) else { return }
        }
        if item.status != .failed || retryImportOnlyByItem[ObjectIdentifier(item)] != true {
            queueCancellation(for: item)
            if currentItem === item { currentTask?.cancel() }
            sourceAudioSHA256ByItem.removeValue(forKey: ObjectIdentifier(item))
            clientRequestIDByItem[ObjectIdentifier(item)] = UUID().uuidString.lowercased()
            explicitRestartByItem[ObjectIdentifier(item)] = serverIDByItem[ObjectIdentifier(item)] != nil &&
                (item.serverPhase == "failed" || item.status == .canceled)
            serverIDByItem.removeValue(forKey: ObjectIdentifier(item))
            admissionByItem[ObjectIdentifier(item)] = .pending
        }
        item.status = .queued
        item.serverWaitingForNetwork = false
        item.serverConnectionIssue = false
        item.serverPhase = retryImportOnlyByItem[ObjectIdentifier(item)] == true ? "importing" : nil
        item.serverLastResponseAt = nil
        item.error = nil
        item.statusDetail = nil
        item.progress = 0
        item.requiresExplicitRetryAfterCrash = false
        item.statusStartedAt = nil
        item.nextRetryAt = nil
        item.completedAt = nil
        persistQueue()
        postQueueChange()
        processNext()
    }

    @objc func cancelAll() {
        guard queueLoadError == nil else { postQueueChange(); return }
        currentTask?.cancel()
        for item in items {
            queueCancellation(for: item)
            removeMetadata(for: item)
        }
        items.removeAll()
        persistQueue()
        postQueueChange()
        TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
        processNext()
    }

    /// True while a submitted run still owns the episode. Completed and failed entries
    /// are history, not ownership.
    @objc func hasActiveItem(forEpisodeHash episodeHash: String) -> Bool {
        items.contains {
            $0.episodeHash == episodeHash && $0.usesServerTranscription
                && $0.status != .completed && $0.status != .failed && $0.status != .canceled
        }
    }

    /// Drops finished entries past the retention window, mirroring the local queue.
    /// Read path only — deliberately no file write and no notification here.
    @objc func pruneExpiredCompletedItems(now: Date = Date()) {
        let expired = items.filter { item in
            guard item.status == .completed || item.status == .canceled else { return false }
            guard let completedAt = item.completedAt else { return true }
            return now.timeIntervalSince(completedAt) >= Self.completedItemRetentionInterval
        }
        for item in expired { removeMetadata(for: item) }
        items.removeAll { item in expired.contains(where: { $0 === item }) }
    }

    @objc func resumeIfNeeded() {
        if queueLoadError != nil { loadPersistedQueue() }
        guard queueLoadError == nil else { postQueueChange(); return }
        if needsIdentityPersistence {
            needsIdentityPersistence = false
            persistQueue()
        }
        if !networkUnavailable {
            for item in items where item.serverWaitingForNetwork && !item.requiresExplicitRetryAfterCrash {
                item.serverWaitingForNetwork = false
                item.nextRetryAt = nil
            }
        }
        processPendingCancellation()
        guard ICAITranscriptionFeaturesAvailable(),
              UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled) else { return }
        processNext()
    }

    @objc func retryPendingCancellations() {
        guard queueLoadError == nil else { postQueueChange(); return }
        for index in cancellations.indices {
            cancellations[index].retryable = true
            cancellations[index].nextRetryAt = nil
            cancellations[index].error = nil
        }
        persistQueue()
        postQueueChange()
    }

    @objc func retryQueueStorage() {
        guard pendingPersistenceCount == 0 else { return }
        if queueLoadError != nil { loadPersistedQueue() }
        guard queueLoadError == nil else { postQueueChange(); return }
        if queuePersistenceError != nil { persistQueue() }
        resumeIfNeeded()
        postQueueChange()
    }

    @objc func retryQueuePersistenceAfterFailure() {
        if queueLoadError != nil { retryQueueStorage(); return }
        guard queuePersistenceError != nil else { return }
        persistQueue()
        if queuePersistenceError == nil {
            processNext()
        }
        postQueueChange()
    }

    /// Discovery must retain its outbox until the accepted server entries are durable.
    func whenQueuePersisted(completion: @escaping (NSError?) -> Void) {
        if pendingPersistenceCount == 0 {
            completion(queueStorageError)
        } else {
            persistenceCompletions.append(completion)
        }
    }

    private func makeItem(episodeHash: String,
                          episodeTitle: String,
                          feedTitle: String,
                          episodeURL: URL,
                          podcastURL: URL?,
                          duration: Double,
                          automaticallyScheduled: Bool) -> ICTranscriptionQueueItem {
        let item = ICTranscriptionQueueItem(episodeHash: episodeHash,
                                            episodeTitle: episodeTitle,
                                            feedTitle: feedTitle,
                                            audioURL: nil,
                                            language: nil)
        item.usesServerTranscription = true
        item.automaticallyScheduled = automaticallyScheduled
        item.shouldGenerateAnalysis = true
        clientRequestIDByItem[ObjectIdentifier(item)] = UUID().uuidString.lowercased()
        endpointByItem[ObjectIdentifier(item)] = episodeURL
        metadataByItem[ObjectIdentifier(item)] = (podcastURL, duration)
        admissionByItem[ObjectIdentifier(item)] = .pending
        item.statusDetail = NSLocalizedString("Preparing server transcription on this device.", comment: "")
        return item
    }

    private func updateStatusDetail(_ detail: String, for item: ICTranscriptionQueueItem) {
        guard item.statusDetail != detail else { return }
        item.statusDetail = detail
        TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                          phase: "status",
                                          message: detail)
    }

    private func queueCancellation(for item: ICTranscriptionQueueItem) {
        guard item.status != .canceled,
              admissionByItem[ObjectIdentifier(item)] != .pending,
              admissionByItem[ObjectIdentifier(item)] != .prepared,
              admissionByItem[ObjectIdentifier(item)] != .rejected else { return }
        let requestID = clientRequestIDByItem[ObjectIdentifier(item)]
        let episodeID = serverIDByItem[ObjectIdentifier(item)]
        let id: String
        if let requestID {
            id = requestID
        } else if let episodeID {
            id = "legacy:\(episodeID)"
        } else {
            return
        }
        guard !cancellations.contains(where: { $0.id == id }) else { return }
        cancellations.append(ICServerCancellation(id: id,
                                                   episodeHash: item.episodeHash,
                                                   clientRequestID: requestID,
                                                   serverEpisodeID: episodeID,
                                                   nextRetryAt: nil,
                                                   error: nil,
                                                   retryable: true))
    }

    private func processPendingCancellation() {
        guard queueLoadError == nil, pendingPersistenceCount == 0, queuePersistenceError == nil,
              currentTask == nil, cancellationTask == nil,
              let cancellation = cancellations.first(where: {
                  $0.retryable && ($0.nextRetryAt == nil || $0.nextRetryAt! <= Date())
              }) else { return }
        cancellationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.cancellationTask = nil
                self.persistQueue()
                self.processNext()
                self.postQueueChange()
                TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
            }
            do {
                let path: String
                if let requestID = cancellation.clientRequestID {
                    path = "client-requests/\(requestID)"
                } else if let episodeID = cancellation.serverEpisodeID {
                    path = "episodes/\(episodeID)/client-request"
                } else {
                    throw self.serverContractError(code: 18, message: NSLocalizedString("The server cancellation has no request identity.", comment: ""))
                }
                let receipt: ICServerCancellationReceipt = try await self.request(path: path, method: "DELETE", body: nil)
                guard receipt.apiVersion == "v1",
                      receipt.clientRequest.state == "canceled" || receipt.clientRequest.state == "deleted",
                      receipt.clientRequest.id == cancellation.clientRequestID,
                      cancellation.serverEpisodeID == nil || receipt.clientRequest.episodeID == cancellation.serverEpisodeID else {
                    throw self.serverContractError(code: 19, message: NSLocalizedString("The server did not confirm cancellation of this request.", comment: ""))
                }
                self.cancellations.removeAll { $0.id == cancellation.id }
            } catch {
                guard let index = self.cancellations.firstIndex(where: { $0.id == cancellation.id }) else { return }
                self.cancellations[index].error = error.localizedDescription
                let seconds = self.retryAfter(from: error as NSError) ?? Int(Self.retryDelay)
                let validInterval = (1...Self.maximumRetryInterval).contains(seconds)
                self.cancellations[index].retryable = self.isTransient(error) && validInterval
                self.cancellations[index].nextRetryAt = self.cancellations[index].retryable
                    ? Date().addingTimeInterval(TimeInterval(seconds)) : nil
                if !validInterval {
                    self.cancellations[index].error = NSLocalizedString("The server returned an invalid retry interval. The cancellation remains saved. Retry it explicitly.", comment: "")
                }
            }
        }
        postQueueChange()
    }

    private func checkCurrentAttempt(_ item: ICTranscriptionQueueItem, requestID: String?) throws {
        try Task.checkCancellation()
        guard currentItem === item, items.contains(where: { $0 === item }),
              clientRequestIDByItem[ObjectIdentifier(item)] == requestID,
              item.status != .canceled else { throw CancellationError() }
    }

    private func cancelLocally(_ item: ICTranscriptionQueueItem, message: String) {
        finishAdmissionFeedback(item, accepted: false, message: message)
        item.status = .canceled
        item.statusStartedAt = nil
        item.statusDetail = message
        item.error = nil
        item.completedAt = Date()
        item.nextRetryAt = nil
        TranscriptionLogger.shared.append(episodeHash: item.episodeHash, phase: "server", message: message)
    }

    private func processNext() {
        guard queueLoadError == nil else { return }
        guard pendingPersistenceCount == 0, queuePersistenceError == nil else { return }
        processPendingCancellation()
        guard cancellationTask == nil else { return }
        guard ICAITranscriptionFeaturesAvailable(),
              UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled),
              currentTask == nil,
              let item = items.first(where: { candidate in
                  !candidate.requiresExplicitRetryAfterCrash && !(networkUnavailable && candidate.serverWaitingForNetwork) && (candidate.status == .queued || candidate.status == .transcribing || candidate.status == .generatingChapters) &&
                      !cancellations.contains(where: { $0.episodeHash == candidate.episodeHash }) &&
                      (candidate.nextRetryAt == nil || candidate.nextRetryAt! <= Date())
              }) else {
            scheduleRetryWake()
            return
        }
        guard let episodeURL = endpointByItem[ObjectIdentifier(item)] else {
            fail(item, message: NSLocalizedString("Die URL der Server-Transkription fehlt.", comment: ""))
            persistQueue()
            postQueueChange()
            processNext()
            return
        }

        item.nextRetryAt = nil
        item.serverWaitingForNetwork = false
        currentItem = item
        postQueueChange()
        let requestID = clientRequestIDByItem[ObjectIdentifier(item)]

        currentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.currentItem = nil
                self.currentTask = nil
                self.persistQueue()
                self.processNext()
                self.postQueueChange()
            }
            do {
                let envelope: ICServerEpisodeEnvelope
                if let requestID, self.admissionByItem[ObjectIdentifier(item)] == .unconfirmed || self.admissionByItem[ObjectIdentifier(item)] == .accepted {
                    do {
                        if self.admissionByItem[ObjectIdentifier(item)] == .unconfirmed {
                            item.serverPhase = "checking_request"
                            self.updateStatusDetail(NSLocalizedString("Checking whether the server received the saved request.", comment: ""), for: item)
                            self.postQueueChange()
                        }
                        envelope = try await self.request(path: "client-requests/\(requestID)", method: "GET", body: nil)
                    } catch {
                        guard (error as NSError).userInfo["serverErrorCode"] as? String == "request_not_found" else { throw error }
                        try self.checkCurrentAttempt(item, requestID: requestID)
                        // An acknowledgement may be lost. Replay only the durable attempt,
                        // whose server tombstone still prevents canceled work from restarting.
                        envelope = try await self.submitEpisode(for: item, url: episodeURL,
                                                                podcastURL: self.podcastURL(for: item),
                                                                title: item.episodeTitle,
                                                                duration: self.duration(for: item),
                                                                requestID: requestID,
                                                                explicitRestart: self.explicitRestartByItem[ObjectIdentifier(item)] == true)
                    }
                } else if let serverID = self.serverIDByItem[ObjectIdentifier(item)] {
                    envelope = try await self.fetchEpisode(id: serverID)
                } else if let requestID {
                    envelope = try await self.submitEpisode(for: item, url: episodeURL,
                                                            podcastURL: self.podcastURL(for: item),
                                                            title: item.episodeTitle,
                                                            duration: self.duration(for: item),
                                                            requestID: requestID,
                                                            explicitRestart: self.explicitRestartByItem[ObjectIdentifier(item)] == true)
                } else {
                    throw self.serverContractError(code: 20, message: NSLocalizedString("The server request identity is missing.", comment: ""))
                }
                try self.checkCurrentAttempt(item, requestID: requestID)
                guard envelope.apiVersion == "v1" else {
                    throw self.serverContractError(code: 22, message: NSLocalizedString("The server response could not confirm this request.", comment: ""))
                }
                if let requestID {
                    guard envelope.clientRequest?.id == requestID,
                          envelope.clientRequest?.episodeID == envelope.episode.id,
                          ["active", "canceled", "deleted"].contains(envelope.clientRequest?.state ?? "") else {
                        throw self.serverContractError(code: 21, message: NSLocalizedString("The server returned a different request identity.", comment: ""))
                    }
                }
                if let expectedID = self.serverIDByItem[ObjectIdentifier(item)], expectedID != envelope.episode.id {
                    throw self.serverContractError(code: 21, message: NSLocalizedString("The server returned a different request identity.", comment: ""))
                }
                self.serverIDByItem[ObjectIdentifier(item)] = envelope.episode.id
                let wasAccepted = self.admissionByItem[ObjectIdentifier(item)] == .accepted
                self.admissionByItem[ObjectIdentifier(item)] = .accepted
                if !wasAccepted && envelope.clientRequest?.state != "canceled" && envelope.clientRequest?.state != "deleted" && envelope.episode.status != "canceled" {
                    self.finishAdmissionFeedback(item, accepted: true, message: NSLocalizedString("The server accepted the transcription request.", comment: ""))
                }
                await self.apply(envelope, to: item, requestID: requestID)
            } catch is CancellationError {
                // The durable queue entry remains untouched and can resume.
            } catch {
                guard (try? self.checkCurrentAttempt(item, requestID: requestID)) != nil else { return }
                await self.handle(error: error, for: item)
            }
        }
    }

    private func apply(_ envelope: ICServerEpisodeEnvelope, to item: ICTranscriptionQueueItem, requestID: String?) async {
        guard items.contains(where: { $0 === item }) else { return }
        guard envelope.apiVersion == "v1" else {
            fail(item, message: NSLocalizedString("Der Transkriptionsserver lieferte eine unbekannte API-Version.", comment: ""))
            return
        }
        let episode = envelope.episode
        item.serverLastResponseAt = Date()
        item.serverPhase = episode.phase
        item.serverConnectionIssue = false
        if episode.status == "canceled" || envelope.clientRequest?.state == "canceled" || envelope.clientRequest?.state == "deleted" {
            cancelLocally(item, message: NSLocalizedString("This job was canceled on the server.", comment: ""))
            return
        }
        guard let phase = localizedPhase(episode.phase) else {
            item.requiresExplicitRetryAfterCrash = true
            fail(item, message: NSLocalizedString("Der Transkriptionsserver lieferte eine unbekannte Verarbeitungsphase.", comment: ""))
            return
        }
        // The server reports processing phases, not a measured overall fraction.
        // Discard weighted values restored from older server responses as well.
        item.progress = episode.status == "ready" ? 1 : 0
        if let serviceStatus = envelope.serviceStatus, !serviceStatus.available,
           episode.status == "queued" || episode.status == "running" {
            guard let detail = localizedServiceUnavailableDetail(serviceStatus.code) else {
                item.requiresExplicitRetryAfterCrash = true
                fail(item, message: NSLocalizedString("Der Server lieferte einen unbekannten Verarbeitungsstatus.", comment: ""))
                return
            }
            item.serverPhase = "paused"
            updateStatusDetail(detail, for: item)
        } else {
            updateStatusDetail(phase, for: item)
        }
        switch episode.status {
        case "ready":
            retryImportOnlyByItem[ObjectIdentifier(item)] = true
            item.status = .generatingChapters
            item.serverPhase = "importing"
            updateStatusDetail(NSLocalizedString("Server-Ergebnis wird geprüft und übernommen.", comment: ""), for: item)
            postQueueChange()
            do {
                try await importArtifacts(episode.artifacts,
                                          serverDuration: episode.serverDurationSeconds,
                                          sourceAudioSHA256: episode.media?.audioSHA256,
                                          for: item,
                                          requestID: requestID)
                try checkCurrentAttempt(item, requestID: requestID)
                item.status = .completed
                item.progress = 1
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.completedAt = Date()
                item.error = nil
                TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                                  phase: "server",
                                                  message: NSLocalizedString("Server-Transkription übernommen", comment: ""),
                                                  detailText: nil)
                NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionDidChangeNotification"),
                                                object: nil,
                                                userInfo: ["episodeHash": item.episodeHash])
            } catch is CancellationError {
                return
            } catch {
                if isRemoteCancellation(error) {
                    cancelLocally(item, message: NSLocalizedString("This job was canceled or removed on the server.", comment: ""))
                } else if isTransient(error) {
                    item.serverConnectionIssue = true
                    item.serverWaitingForNetwork = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorNotConnectedToInternet
                    guard schedulePoll(item, after: retryAfter(from: error as NSError) ?? Int(Self.retryDelay)) else { return }
                    updateStatusDetail(NSLocalizedString("Server-Ergebnis konnte vorübergehend nicht geladen werden. Neuer Versuch ist geplant.", comment: ""), for: item)
                } else {
                    fail(item, message: error.localizedDescription)
                }
            }
        case "failed":
            retryImportOnlyByItem.removeValue(forKey: ObjectIdentifier(item))
            fail(item, message: episode.error?.localizedMessage ?? NSLocalizedString("Die Server-Verarbeitung ist fehlgeschlagen.", comment: ""))
        case "queued", "running":
            item.status = episode.status == "running" ? .transcribing : .queued
            if episode.status == "running" && item.statusStartedAt == nil { item.statusStartedAt = Date() }
            if episode.status == "queued" { item.statusStartedAt = nil }
            schedulePoll(item, after: envelope.retryAfterSeconds)
        default:
            item.requiresExplicitRetryAfterCrash = true
            fail(item, message: NSLocalizedString("Der Server lieferte einen unbekannten Verarbeitungsstatus.", comment: ""))
        }
    }

    @discardableResult
    private func schedulePoll(_ item: ICTranscriptionQueueItem, after seconds: Int?) -> Bool {
        guard let seconds, (1...Self.maximumRetryInterval).contains(seconds) else {
            item.requiresExplicitRetryAfterCrash = true
            item.status = .queued
            item.statusStartedAt = nil
            item.nextRetryAt = nil
            let message = NSLocalizedString("The server returned an invalid retry interval. This request remains saved. Check its status again explicitly.", comment: "")
            updateStatusDetail(message, for: item)
            finishAdmissionFeedback(item, accepted: false, message: message)
            return false
        }
        item.nextRetryAt = Date().addingTimeInterval(TimeInterval(seconds))
        TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
        return true
    }

    private func fail(_ item: ICTranscriptionQueueItem, message: String) {
        item.status = .failed
        item.statusStartedAt = nil
        item.statusDetail = nil
        item.error = message
        item.completedAt = Date()
        item.nextRetryAt = nil
        TranscriptionLogger.shared.append(episodeHash: item.episodeHash,
                                          phase: "error",
                                          message: NSLocalizedString("Server-Transkription fehlgeschlagen", comment: ""),
                                          detailText: message)
    }

    private func handle(error: Error, for item: ICTranscriptionQueueItem) async {
        let nsError = error as NSError
        item.serverConnectionIssue = isTransient(error)
        if isRemoteCancellation(error) {
            cancelLocally(item, message: NSLocalizedString("This job was canceled or removed on the server.", comment: ""))
            return
        }
        if nsError.userInfo["invalidRetryInterval"] as? Bool == true,
           nsError.userInfo["serverAdmitted"] as? Bool != false {
            schedulePoll(item, after: nil)
            return
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet {
            item.serverWaitingForNetwork = true
            item.status = .queued
            item.statusStartedAt = nil
            let message = admissionByItem[ObjectIdentifier(item)] == .accepted
                ? NSLocalizedString("Offline. The server may continue processing. Its status will update when the connection returns.", comment: "")
                : (admissionByItem[ObjectIdentifier(item)] == .unconfirmed
                    ? NSLocalizedString("Offline. Whether the server received the request is unknown. The saved request will be checked automatically when the connection returns.", comment: "")
                    : NSLocalizedString("Saved on this device. Waiting for internet; the request will be sent automatically when the connection returns.", comment: ""))
            updateStatusDetail(message, for: item)
            schedulePoll(item, after: Int(Self.retryDelay))
            finishAdmissionFeedback(item, accepted: false, message: message)
            return
        }
        if admissionByItem[ObjectIdentifier(item)] != .accepted {
            if nsError.userInfo["serverAdmitted"] as? Bool == false {
                rejectAdmission(item, message: admissionRejectionMessage(nsError))
            } else if !isTransient(error) {
                // A permanent response is not a delayed acknowledgement. Unreadable
                // responses retain the UUID for an explicit status check.
                let message: String
                if nsError.domain == "ICServerTranscription" {
                    message = String(format: NSLocalizedString("The server rejected the request (HTTP %ld). %@", comment: ""), nsError.code, nsError.localizedDescription)
                } else {
                    message = NSLocalizedString("The server response could not be read. Automatic retries have stopped. Check the saved request again.", comment: "")
                }
                item.requiresExplicitRetryAfterCrash = nsError.userInfo["serverRetryable"] as? Bool != false
                fail(item, message: message)
                finishAdmissionFeedback(item, accepted: false, message: message)
            } else {
                item.status = .queued
                item.statusStartedAt = nil
                let message = String(format: NSLocalizedString("The connection to the server was interrupted. The saved request will be checked again. %@", comment: ""), nsError.localizedDescription)
                updateStatusDetail(message, for: item)
                guard schedulePoll(item, after: retryAfter(from: nsError) ?? Int(Self.retryDelay)) else { return }
                finishAdmissionFeedback(item, accepted: false, message: message)
            }
            return
        }
        guard isTransient(error) else {
            // A broken status response says nothing about the remote processing result.
            // Reconcile the existing request; never turn this into a forced new job.
            item.requiresExplicitRetryAfterCrash = true
            fail(item, message: nsError.localizedDescription)
            return
        }
        guard schedulePoll(item, after: retryAfter(from: nsError) ?? Int(Self.retryDelay)) else { return }
        if let detail = localizedServiceUnavailableDetail(nsError.userInfo["serverErrorCode"] as? String) {
            item.serverConnectionIssue = false
            item.serverPhase = "paused"
            updateStatusDetail(detail, for: item)
        } else {
            updateStatusDetail(NSLocalizedString("Server vorübergehend nicht erreichbar. Neuer Versuch ist geplant.", comment: ""), for: item)
        }
    }

    @objc func hasConfirmedAdmission(forEpisodeHash hash: String) -> Bool {
        guard let item = items.first(where: { $0.episodeHash == hash }) else { return false }
        return admissionByItem[ObjectIdentifier(item)] == .accepted
    }

    @objc func wasAdmissionRejected(forEpisodeHash hash: String) -> Bool {
        guard let item = items.first(where: { $0.episodeHash == hash }) else { return false }
        return admissionByItem[ObjectIdentifier(item)] == .rejected
    }

    @objc var unconfirmedAdmissionCount: Int {
        items.filter { item in
            item.status != .failed && item.status != .completed && item.status != .canceled &&
                admissionByItem[ObjectIdentifier(item)] != .accepted
        }.count
    }

    private func awaitQueuePersistence() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            whenQueuePersisted { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func finishAdmissionFeedback(_ item: ICTranscriptionQueueItem, accepted: Bool, message: String) {
        admissionCompletions.removeValue(forKey: ObjectIdentifier(item))?(accepted, message)
    }

    private func rejectAdmission(_ item: ICTranscriptionQueueItem, message: String) {
        admissionByItem[ObjectIdentifier(item)] = .rejected
        fail(item, message: message)
        finishAdmissionFeedback(item, accepted: false, message: message)
    }

    private func admissionRejectionMessage(_ error: NSError) -> String {
        let reason: String
        switch error.userInfo["serverErrorCode"] as? String {
        case "queue_full", "client_queue_full":
            reason = NSLocalizedString("The server queue is full. Try again later.", comment: "")
        case "provider_unavailable":
            reason = NSLocalizedString("Server processing is unavailable. The operator must restore service. Try again later.", comment: "")
        case "worker_unavailable", "resources_unavailable":
            reason = NSLocalizedString("The server currently has no processing capacity. Try again later.", comment: "")
        default:
            reason = error.localizedDescription
        }
        return String(format: NSLocalizedString("Not added: %@", comment: ""), reason)
    }

    private func isRemoteCancellation(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "ICServerTranscription" &&
            ["request_canceled", "request_deleted", "episode_deleted", "episode_not_found"].contains(error.userInfo["serverErrorCode"] as? String ?? "")
    }

    private func localizedServiceUnavailableDetail(_ code: String?) -> String? {
        switch code {
        case "provider_unavailable":
            return NSLocalizedString("Server processing is paused. The operator must restore service; your job will retry automatically.", comment: "")
        case "worker_unavailable":
            return NSLocalizedString("The transcription server has no available worker. It will retry automatically.", comment: "")
        case "resources_unavailable":
            return NSLocalizedString("Server processing is paused because server resources are unavailable. Your accepted job will retry automatically.", comment: "")
        case "queue_full", "client_queue_full":
            return NSLocalizedString("The server transcription queue is full. Your job will retry automatically when capacity is available.", comment: "")
        default:
            return nil
        }
    }

    private func submitEpisode(for item: ICTranscriptionQueueItem, url: URL, podcastURL: URL?, title: String, duration: Double,
                               requestID: String, explicitRestart: Bool) async throws -> ICServerEpisodeEnvelope {
        let audioSHA256 = try await submissionAudioSHA256(for: item, requestID: requestID)
        if networkUnavailable { throw URLError(.notConnectedToInternet) }
        // The audio and UUID are durable before sending. Only an actual send can
        // have an unknown remote outcome and require reconciliation after restart.
        if admissionByItem[ObjectIdentifier(item)] != .accepted {
            admissionByItem[ObjectIdentifier(item)] = .unconfirmed
        }
        persistQueue()
        do { try await awaitQueuePersistence() }
        catch {
            throw NSError(domain: "ICServerTranscription", code: 58,
                          userInfo: [NSLocalizedDescriptionKey: error.localizedDescription, "serverAdmitted": false])
        }
        try checkCurrentAttempt(item, requestID: requestID)
        item.serverPhase = "sending"
        updateStatusDetail(NSLocalizedString("Sending the saved request to the server.", comment: ""), for: item)
        postQueueChange()
        var body: [String: Any] = [
            "episode_url": url.absoluteString,
            "client_audio_sha256": audioSHA256,
            "title": title,
            "client_duration_seconds": duration,
            "wait_seconds": 0,
            "force": explicitRestart,
            "client_request_id": requestID,
        ]
        if let podcastURL { body["podcast_url"] = podcastURL.absoluteString }
        return try await request(path: "episodes", method: "POST", body: body)
    }

    private func submissionAudioSHA256(for item: ICTranscriptionQueueItem, requestID: String) async throws -> String {
        func rejected(_ message: String) -> NSError {
            NSError(domain: "ICServerTranscription", code: 58,
                    userInfo: [NSLocalizedDescriptionKey: message, "serverAdmitted": false])
        }
        guard let episode = findEpisode(hash: item.episodeHash),
              let cache = CacheManager.shared(), cache.episodeIsCached(episode),
              let url = cache.url(forCachedEpisode: episode), url.isFileURL,
              let snapshot = TranscriptionEngine.artifactSnapshotIdentifier(at: url) else {
            throw rejected(NSLocalizedString("Download the complete episode before starting transcription.", comment: ""))
        }
        item.serverPhase = "checking_audio"
        updateStatusDetail(NSLocalizedString("Checking the downloaded audio on this device.", comment: ""), for: item)
        postQueueChange()
        let actual: String
        do { actual = try await ICAudioIdentity.sha256(of: url) }
        catch is CancellationError { throw CancellationError() }
        catch { throw rejected(NSLocalizedString("The audio file could not be verified. Download the episode again.", comment: "")) }
        try checkCurrentAttempt(item, requestID: requestID)
        if let existing = sourceAudioSHA256ByItem[ObjectIdentifier(item)], existing != actual {
            throw rejected(NSLocalizedString("The audio file has changed. Start a new transcription request.", comment: ""))
        }
        sourceAudioSHA256ByItem[ObjectIdentifier(item)] = actual
        if admissionByItem[ObjectIdentifier(item)] == .pending {
            admissionByItem[ObjectIdentifier(item)] = .prepared
        }
        persistQueue()
        do { try await awaitQueuePersistence() }
        catch { throw rejected(error.localizedDescription) }
        try checkCurrentAttempt(item, requestID: requestID)
        guard importAudioIsCurrent((url: url, snapshot: snapshot), for: item) else {
            throw rejected(NSLocalizedString("The audio file has changed. Start a new transcription request.", comment: ""))
        }
        return actual
    }

    private func fetchEpisode(id: Int) async throws -> ICServerEpisodeEnvelope {
        try await request(path: "episodes/\(id)", method: "GET", body: nil)
    }

    private func request<T: Decodable>(path: String, method: String, body: [String: Any]?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(try clientIdentifier(), forHTTPHeaderField: "X-Instacast-Client-ID")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0", forHTTPHeaderField: "X-Instacast-App-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Instacast-Platform")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await ICServerHTTPClient.shared.data(for: request, maximumBytes: ICServerHTTPClient.maximumEnvelopeBytes)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ICServerTranscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Der Transkriptionsserver lieferte keine HTTP-Antwort.", comment: "")])
        }
        guard (200...299).contains(http.statusCode) else {
            let errorEnvelope = try? JSONDecoder().decode(ICServerAPIErrorEnvelope.self, from: data)
            let apiError = errorEnvelope?.error
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: apiError?.localizedMessage ?? NSLocalizedString("Die Anfrage an den Transkriptionsserver ist fehlgeschlagen.", comment: "")]
            if let apiError {
                userInfo["serverErrorCode"] = apiError.code
                userInfo["serverRetryable"] = apiError.retryable
                if errorEnvelope?.apiVersion == "v1", let admitted = apiError.admitted { userInfo["serverAdmitted"] = admitted }
                if let detail = localizedServiceUnavailableDetail(apiError.code) {
                    userInfo[NSLocalizedDescriptionKey] = detail
                }
            }
            if let retry = http.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = Int(retry), (1...Self.maximumRetryInterval).contains(seconds) { userInfo["retryAfter"] = seconds }
                else { userInfo["invalidRetryInterval"] = true }
            }
            throw NSError(domain: "ICServerTranscription", code: http.statusCode, userInfo: userInfo)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func download(_ artifact: ICServerArtifact) async throws -> Data {
        let expectedURL = baseURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(String(artifact.id), isDirectory: false)
        guard artifact.url == expectedURL,
              artifact.byteSize > 0,
              artifact.byteSize <= ICServerHTTPClient.maximumArtifactBytes,
              artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !artifact.contentType.isEmpty,
              !artifact.etag.isEmpty else {
            throw serverContractError(code: 5,
                                      message: NSLocalizedString("Ein Server-Artefakt hat einen ungültigen Deskriptor.", comment: ""))
        }
        var request = URLRequest(url: expectedURL)
        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
        request.setValue(try clientIdentifier(), forHTTPHeaderField: "X-Instacast-Client-ID")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0", forHTTPHeaderField: "X-Instacast-App-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Instacast-Platform")
        request.setValue(artifact.contentType, forHTTPHeaderField: "Accept")
        let (data, response) = try await ICServerHTTPClient.shared.data(for: request, maximumBytes: max(artifact.byteSize, ICServerHTTPClient.maximumEnvelopeBytes))
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw serverContractError(code: -1,
                                      message: NSLocalizedString("Ein Server-Artefakt lieferte keine HTTP-Antwort.", comment: ""))
        }
        guard (200...299).contains(http.statusCode) else {
            let errorEnvelope = try? JSONDecoder().decode(ICServerAPIErrorEnvelope.self, from: data)
            let apiError = errorEnvelope?.error
            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: apiError?.localizedMessage ?? NSLocalizedString("Ein Server-Artefakt konnte nicht geladen werden.", comment: "")
            ]
            if let apiError {
                userInfo["serverErrorCode"] = apiError.code
                userInfo["serverRetryable"] = apiError.retryable
                if errorEnvelope?.apiVersion == "v1", let admitted = apiError.admitted { userInfo["serverAdmitted"] = admitted }
            }
            if let retry = http.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = Int(retry), (1...Self.maximumRetryInterval).contains(seconds) { userInfo["retryAfter"] = seconds }
                else { userInfo["invalidRetryInterval"] = true }
            }
            throw NSError(domain: "ICServerTranscription", code: http.statusCode, userInfo: userInfo)
        }
        guard let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
              Int(contentLength) == artifact.byteSize,
              data.count == artifact.byteSize else {
            throw serverContractError(code: 6,
                                      message: NSLocalizedString("Die Größe eines Server-Artefakts stimmt nicht.", comment: ""))
        }
        guard let responseContentType = http.value(forHTTPHeaderField: "Content-Type"),
              responseContentType.caseInsensitiveCompare(artifact.contentType) == .orderedSame else {
            throw serverContractError(code: 7,
                                      message: NSLocalizedString("Der Inhaltstyp eines Server-Artefakts stimmt nicht.", comment: ""))
        }
        guard http.value(forHTTPHeaderField: "ETag") == artifact.etag else {
            throw serverContractError(code: 8,
                                      message: NSLocalizedString("Die Versionskennung eines Server-Artefakts stimmt nicht.", comment: ""))
        }
        let received = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard received == artifact.sha256 else {
            throw serverContractError(code: 9,
                                      message: NSLocalizedString("Ein Server-Artefakt ist beschädigt.", comment: ""))
        }
        return data
    }

    private func importArtifacts(_ artifacts: [ICServerArtifact],
                                 serverDuration: Double?,
                                 sourceAudioSHA256: String?,
                                 for item: ICTranscriptionQueueItem,
                                 requestID: String?) async throws {
        guard artifacts.count == 4 else {
            throw serverContractError(code: 10,
                                      message: NSLocalizedString("Das Server-Ergebnis ist unvollständig oder enthält doppelte Artefakte.", comment: ""))
        }
        func artifact(_ kind: String) throws -> ICServerArtifact {
            let matches = artifacts.filter { $0.kind == kind }
            guard matches.count == 1, let result = matches.first else {
                throw serverContractError(code: 10,
                                          message: NSLocalizedString("Das Server-Ergebnis ist unvollständig oder enthält doppelte Artefakte.", comment: ""))
            }
            return result
        }
        let srtArtifact = try artifact("transcript_srt")
        let chaptersDescriptor = try artifact("chapters_json")
        let adsDescriptor = try artifact("ads_json")
        let summaryDescriptor = try artifact("summary_json")
        let transcriptRevision = "sha256:\(srtArtifact.sha256)"
        guard artifacts.allSatisfy({ artifact in
            artifact.transcriptRevision == transcriptRevision
        }) else {
            throw serverContractError(code: 13,
                                      message: NSLocalizedString("Die Server-Artefakte gehören nicht zum selben Transkript.", comment: ""))
        }
        let audioProof = try await verifiedImportAudio(for: item, sourceAudioSHA256: sourceAudioSHA256)
        try checkCurrentAttempt(item, requestID: requestID)
        async let pendingSRTData = download(srtArtifact)
        async let pendingChaptersData = download(chaptersDescriptor)
        async let pendingAdsData = download(adsDescriptor)
        async let pendingSummaryData = download(summaryDescriptor)
        let (srtData, chaptersData, adsData, summaryData) = try await (
            pendingSRTData,
            pendingChaptersData,
            pendingAdsData,
            pendingSummaryData
        )
        try checkCurrentAttempt(item, requestID: requestID)
        let (cues, chaptersArtifact, adsArtifact, summaryArtifact) = try await validateDownloadedArtifacts(
            srtData: srtData, chaptersData: chaptersData, adsData: adsData, summaryData: summaryData,
            episodeHash: item.episodeHash, transcriptRevision: transcriptRevision, serverDuration: serverDuration)
        try checkCurrentAttempt(item, requestID: requestID)
        guard let episode = findEpisode(hash: item.episodeHash) else {
            throw serverContractError(code: 11,
                                      message: NSLocalizedString("Die Episode wurde während der Server-Verarbeitung entfernt.", comment: ""))
        }
        let baseChapters = publisherChapters(for: episode, fallback: chaptersArtifact.chapters)
        let sponsors = adsArtifact.segments.map {
            ICSponsorSegment(start: $0.start, end: $0.end, title: $0.title, evidenceCueIDs: [])
        }
        let analysis = try await buildServerAnalysis(baseChapters,
                                                     sponsorSegments: sponsors,
                                                     summary: summaryArtifact.summary,
                                                     transcriptCues: cues)
        try checkCurrentAttempt(item, requestID: requestID)
        guard !episode.isDeleted else {
            throw serverContractError(code: 11,
                                      message: NSLocalizedString("Die Episode wurde während der Server-Verarbeitung entfernt.", comment: ""))
        }
        guard importAudioIsCurrent(audioProof, for: item) else {
            throw serverContractError(code: 57, message: NSLocalizedString("The transcript could not be loaded. Please try again.", comment: ""))
        }
        try TranscriptionEngine.shared.saveValidatedServerSRTData(srtData,
                                                                  cues: cues,
                                                                  for: item.episodeHash,
                                                                  sourceAudioSHA256: sourceAudioSHA256)
        try ChapterGenerator.shared.saveAnalysisResult(analysis, for: item.episodeHash)
    }

    private func verifiedImportAudio(for item: ICTranscriptionQueueItem,
                                     sourceAudioSHA256: String?) async throws -> (url: URL, snapshot: String) {
        guard let expected = sourceAudioSHA256, expected.utf8.count == 64,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw serverContractError(code: 54, message: NSLocalizedString("The server result could not be verified.", comment: ""))
        }
        guard let episode = findEpisode(hash: item.episodeHash),
              let cache = CacheManager.shared(), cache.episodeIsCached(episode),
              let url = cache.url(forCachedEpisode: episode), url.isFileURL,
              let snapshot = TranscriptionEngine.artifactSnapshotIdentifier(at: url) else {
            throw serverContractError(code: 55, message: NSLocalizedString("Download the complete episode before retrieving its transcript.", comment: ""))
        }
        let actual = try await ICAudioIdentity.sha256(of: url)
        let proof = (url: url, snapshot: snapshot)
        guard importAudioIsCurrent(proof, for: item) else {
            throw serverContractError(code: 57, message: NSLocalizedString("The transcript could not be loaded. Please try again.", comment: ""))
        }
        guard actual == expected else {
            throw serverContractError(code: 56, message: NSLocalizedString("The server transcript does not match the downloaded episode.", comment: ""))
        }
        return proof
    }

    private func importAudioIsCurrent(_ proof: (url: URL, snapshot: String), for item: ICTranscriptionQueueItem) -> Bool {
        guard let episode = findEpisode(hash: item.episodeHash),
              let cache = CacheManager.shared(), cache.episodeIsCached(episode),
              cache.url(forCachedEpisode: episode) == proof.url else { return false }
        return TranscriptionEngine.artifactSnapshotIdentifier(at: proof.url) == proof.snapshot
    }

    private func buildServerAnalysis(_ chapters: [ICGeneratedChapter],
                                     sponsorSegments: [ICSponsorSegment],
                                     summary: String,
                                     transcriptCues: [ICTranscriptCue]) async throws -> EpisodeAnalysisResult {
        let generator = ChapterGenerator.shared
        let preparation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let result = try generator.makeServerAnalysis(chapters,
                                                          sponsorSegments: sponsorSegments,
                                                          summary: summary,
                                                          transcriptCues: transcriptCues)
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: {
            preparation.cancel()
        }
    }

    private func validateDownloadedArtifacts(srtData: Data,
                                             chaptersData: Data,
                                             adsData: Data,
                                             summaryData: Data,
                                             episodeHash: String,
                                             transcriptRevision: String,
                                             serverDuration: Double?) async throws -> ([ICTranscriptCue], ICServerChaptersArtifact, ICServerAdsArtifact, ICServerSummaryArtifact) {
        let engine = TranscriptionEngine.shared
        let validation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let cues = try engine.validateServerSRTData(srtData, for: episodeHash)
            try self.validateServerTranscriptBounds(cues, serverDuration: serverDuration)
            let chaptersArtifact = try JSONDecoder().decode(ICServerChaptersArtifact.self, from: chaptersData)
            let adsArtifact = try JSONDecoder().decode(ICServerAdsArtifact.self, from: adsData)
            let summaryArtifact = try JSONDecoder().decode(ICServerSummaryArtifact.self, from: summaryData)
            try self.validateServerArtifacts(chaptersArtifact,
                                        ads: adsArtifact,
                                        summary: summaryArtifact,
                                        transcriptRevision: transcriptRevision,
                                        serverDuration: serverDuration)
            try Task.checkCancellation()
            return (cues, chaptersArtifact, adsArtifact, summaryArtifact)
        }
        return try await withTaskCancellationHandler {
            try await validation.value
        } onCancel: {
            validation.cancel()
        }
    }

    nonisolated private func validateServerTranscriptBounds(_ cues: [ICTranscriptCue], serverDuration: Double?) throws {
        guard let serverDuration, serverDuration.isFinite, serverDuration > 0 else {
            throw serverContractError(code: 25, message: NSLocalizedString("The server transcript has no valid measured audio duration.", comment: ""))
        }
        let durationMilliseconds = (serverDuration * 1000).rounded()
        guard durationMilliseconds.isFinite,
              cues.allSatisfy({ cue in
                  cue.start.isFinite && cue.end.isFinite && cue.start >= 0 && cue.end > cue.start &&
                      (cue.end * 1000).rounded() <= durationMilliseconds
              }) else {
            throw serverContractError(code: 26, message: NSLocalizedString("The server transcript contains timestamps beyond the audio duration.", comment: ""))
        }
    }

    nonisolated private func validateServerArtifacts(_ chapters: ICServerChaptersArtifact,
                                         ads: ICServerAdsArtifact,
                                         summary: ICServerSummaryArtifact,
                                         transcriptRevision: String,
                                         serverDuration: Double?) throws {
        guard chapters.schemaVersion == 1,
              ads.schemaVersion == 1,
              summary.schemaVersion == 1 else {
            throw serverContractError(code: 12,
                                      message: NSLocalizedString("Das Server-Ergebnis verwendet eine unbekannte Schema-Version.", comment: ""))
        }
        let revisions = [chapters.transcriptRevision, ads.transcriptRevision, summary.transcriptRevision]
        guard revisions.allSatisfy({ $0 == transcriptRevision }) else {
            throw serverContractError(code: 13,
                                      message: NSLocalizedString("Die Server-Artefakte gehören nicht zum selben Transkript.", comment: ""))
        }
        let duration = chapters.audioDurationSeconds
        guard duration.isFinite,
              duration > 0,
              sameMillisecond(duration, ads.audioDurationSeconds),
              sameMillisecond(duration, summary.audioDurationSeconds),
              serverDuration.map({ sameMillisecond(duration, $0) }) ?? true else {
            throw serverContractError(code: 14,
                                      message: NSLocalizedString("Die Server-Artefakte verwenden unterschiedliche Audiodauern.", comment: ""))
        }
        guard !chapters.chapters.isEmpty,
              sameMillisecond(chapters.chapters[0].start, 0) else {
            throw serverContractError(code: 15,
                                      message: NSLocalizedString("Die Server-Kapitel bilden keine vollständige Basistimeline.", comment: ""))
        }
        var previousChapterEnd = 0.0
        for chapter in chapters.chapters {
            guard chapter.start.isFinite,
                  chapter.end.isFinite,
                  chapter.start >= 0,
                  chapter.end > chapter.start,
                  !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !chapter.isSponsor,
                  sameMillisecond(chapter.start, previousChapterEnd) else {
                throw serverContractError(code: 15,
                                          message: NSLocalizedString("Die Server-Kapitel bilden keine lückenlose sponsorfreie Basistimeline.", comment: ""))
            }
            previousChapterEnd = chapter.end
        }
        guard sameMillisecond(previousChapterEnd, duration) else {
            throw serverContractError(code: 15,
                                      message: NSLocalizedString("Die Server-Kapitel enden nicht an der Audiodauer.", comment: ""))
        }
        var previousAdEnd = 0.0
        for segment in ads.segments {
            let sponsorName = String(segment.title.dropFirst("Sponsor: ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard segment.start.isFinite,
                  segment.end.isFinite,
                  segment.start >= previousAdEnd,
                  segment.start >= 0,
                  segment.end > segment.start,
                  segment.end <= duration,
                  segment.title.hasPrefix("Sponsor: "),
                  !sponsorName.isEmpty else {
                throw serverContractError(code: 16,
                                          message: NSLocalizedString("Die Server-Sponsorsegmente sind ungültig oder überlappen.", comment: ""))
            }
            previousAdEnd = segment.end
        }
        guard !summary.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw serverContractError(code: 17,
                                      message: NSLocalizedString("Die Server-Zusammenfassung ist leer.", comment: ""))
        }
    }

    nonisolated private func sameMillisecond(_ lhs: Double, _ rhs: Double) -> Bool {
        guard lhs.isFinite, rhs.isFinite else { return false }
        let lhsMicroseconds = (lhs * 1_000_000).rounded()
        let rhsMicroseconds = (rhs * 1_000_000).rounded()
        return abs(lhsMicroseconds - rhsMicroseconds) < 1_000
    }

    private func publisherChapters(for episode: CDEpisode,
                                   fallback: [ICServerChaptersArtifact.Chapter]) -> [ICGeneratedChapter] {
        let stored = (episode.sortedChapters() as? [CDChapter]) ?? []
        if !stored.isEmpty {
            let timelineEnd = fallback.map(\.end).max() ?? Double(episode.duration)
            let publisherChapters = stored.enumerated().compactMap { index, chapter -> ICGeneratedChapter? in
                let nextStart = index + 1 < stored.count ? stored[index + 1].timecode : timelineEnd
                // Chapter start times define the publisher timeline. Individual
                // duration fields are often absent or shorter than the next start;
                // using them clipped sponsor overlays out of those uncovered gaps.
                let end = nextStart
                guard chapter.timecode >= 0, end > chapter.timecode else { return nil }
                let title = chapter.title ?? ""
                return ICGeneratedChapter(start: chapter.timecode,
                                          end: end,
                                          title: title,
                                          isSponsor: title.hasPrefix("Sponsor: "))
            }
            let firstPublisherStart = publisherChapters.first?.start ?? timelineEnd
            let leadingFallback = fallback.compactMap { chapter -> ICGeneratedChapter? in
                let end = min(chapter.end, firstPublisherStart)
                guard chapter.start < firstPublisherStart, end > chapter.start else { return nil }
                return ICGeneratedChapter(start: chapter.start,
                                          end: end,
                                          title: chapter.title,
                                          isSponsor: false)
            }
            return leadingFallback + publisherChapters
        }
        return fallback.compactMap {
            guard $0.end > $0.start else { return nil }
            return ICGeneratedChapter(start: $0.start, end: $0.end, title: $0.title, isSponsor: false)
        }
    }

    private func localizedPhase(_ phase: String) -> String? {
        switch phase {
        case "queued": return NSLocalizedString("Waiting for processing", comment: "")
        case "downloading_audio": return NSLocalizedString("Step 1 of 4 · Downloading audio", comment: "")
        case "transcribing": return NSLocalizedString("Step 2 of 4 · Transcribing audio", comment: "")
        case "analyzing": return NSLocalizedString("Step 3 of 4 · Analyzing transcript", comment: "")
        case "finalizing": return NSLocalizedString("Step 4 of 4 · Preparing results", comment: "")
        case "ready": return NSLocalizedString("Server-Ergebnis ist bereit.", comment: "")
        case "failed": return NSLocalizedString("Server-Verarbeitung ist fehlgeschlagen.", comment: "")
        case "canceled": return NSLocalizedString("Server-Verarbeitung wurde abgebrochen.", comment: "")
        default: return nil
        }
    }

    nonisolated private func serverContractError(code: Int, message: String) -> NSError {
        NSError(domain: "ICServerTranscription.Contract",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func isTransient(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "ICServerTranscription", let retryable = nsError.userInfo["serverRetryable"] as? Bool {
            return retryable
        }
        if nsError.domain == NSURLErrorDomain {
            return [
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
            ].contains(nsError.code)
        }
        return nsError.domain == "ICServerTranscription" &&
            (nsError.code == 408 || nsError.code == 425 || nsError.code == 429 || (500...599).contains(nsError.code))
    }

    private func clientIdentifier() throws -> String {
        guard queueLoadError == nil, let ownerClientID else {
            throw queueLoadError ?? serverContractError(code: 23, message: NSLocalizedString("The saved server request owner is unavailable. Existing requests cannot be reassigned.", comment: ""))
        }
        return ownerClientID
    }

    private func podcastURL(for item: ICTranscriptionQueueItem) -> URL? {
        metadataByItem[ObjectIdentifier(item)]?.podcastURL
    }

    private func duration(for item: ICTranscriptionQueueItem) -> Double {
        metadataByItem[ObjectIdentifier(item)]?.duration ?? 0
    }

    private func findEpisode(hash: String) -> CDEpisode? {
        (DatabaseManager.shared()?.episodes(withObjectHashes: [hash]) as? [CDEpisode])?.first
    }

    private func retryAfter(from error: NSError) -> Int? {
        if error.userInfo["invalidRetryInterval"] as? Bool == true { return 0 }
        return error.userInfo["retryAfter"] as? Int
    }

    private func scheduleRetryWake() {
        retryWakeTask?.cancel()
        guard !networkUnavailable else { return }
        let episodeDates = items.filter { item in
            !item.requiresExplicitRetryAfterCrash && ICAITranscriptionFeaturesAvailable() && UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled) &&
                !cancellations.contains(where: { $0.episodeHash == item.episodeHash })
        }.compactMap(\.nextRetryAt)
        let cancellationDates = cancellations.filter(\.retryable).compactMap(\.nextRetryAt)
        guard let date = (episodeDates + cancellationDates).min() else { return }
        let delay = max(0, date.timeIntervalSinceNow)
        guard delay.isFinite, delay <= Double(Self.maximumRetryInterval) else {
            for item in items where item.nextRetryAt == date { schedulePoll(item, after: nil) }
            for index in cancellations.indices where cancellations[index].nextRetryAt == date {
                cancellations[index].retryable = false
                cancellations[index].nextRetryAt = nil
                cancellations[index].error = NSLocalizedString("The server returned an invalid retry interval. The cancellation remains saved. Retry it explicitly.", comment: "")
            }
            persistQueue()
            postQueueChange()
            return
        }
        retryWakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.processNext()
        }
    }

    private var queueFileURL: URL {
        let directory = ICTranscriptionPaths.transcriptCacheDirectory()
        return directory.appendingPathComponent(Self.queueFileName)
    }

    private func persistQueue() {
        guard queueLoadError == nil else { return }
        let persisted = ICPersistedServerTranscriptionQueue(items: items.compactMap { item in
            guard let episodeURL = endpointByItem[ObjectIdentifier(item)] else { return nil }
            return .init(episodeHash: item.episodeHash,
                         episodeTitle: item.episodeTitle,
                         feedTitle: item.feedTitle,
                         episodeURL: episodeURL,
                         podcastURL: podcastURL(for: item),
                         duration: duration(for: item),
                         serverEpisodeID: serverIDByItem[ObjectIdentifier(item)],
                         clientRequestID: clientRequestIDByItem[ObjectIdentifier(item)],
                         explicitRestart: explicitRestartByItem[ObjectIdentifier(item)],
                         admissionState: admissionByItem[ObjectIdentifier(item)],
                         automaticallyScheduled: item.automaticallyScheduled,
                         statusRawValue: item.status.rawValue,
                         error: item.error,
                         nextRetryAt: item.nextRetryAt,
                         completedAt: item.completedAt,
                         progress: item.progress,
                         statusDetail: item.statusDetail,
                         statusStartedAt: item.statusStartedAt,
                         requiresExplicitRetry: item.requiresExplicitRetryAfterCrash,
                         retryImportOnly: retryImportOnlyByItem[ObjectIdentifier(item)],
                         sourceAudioSHA256: sourceAudioSHA256ByItem[ObjectIdentifier(item)],
                         waitingForNetwork: item.serverWaitingForNetwork,
                         serverPhase: item.serverPhase,
                         lastResponseAt: item.serverLastResponseAt,
                         connectionIssue: item.serverConnectionIssue)
        }, cancellations: cancellations, ownerClientID: ownerClientID)
        let fileURL = queueFileURL
        pendingPersistenceCount += 1
        // Snapshot actor-owned items above; encoding and atomic replacement must not
        // block touches. Keep processing ownership until every queued snapshot is durable.
        persistenceQueue.async { [weak self] in
            let writeError: NSError?
            do {
                let data = try JSONEncoder().encode(persisted)
                try data.write(to: fileURL, options: .atomic)
                writeError = nil
            } catch {
                writeError = error as NSError
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingPersistenceCount -= 1
                self.queuePersistenceError = writeError
                if let writeError {
                    NSLog("[ServerTranscription] Queue persistence failed: %@", writeError.localizedDescription)
                }
                if self.pendingPersistenceCount == 0 {
                    let completions = self.persistenceCompletions
                    self.persistenceCompletions.removeAll()
                    for completion in completions { completion(writeError) }
                }
                self.processNext()
                self.postQueueChange()
            }
        }
    }

    private func loadPersistedQueue() {
        let persisted: ICPersistedServerTranscriptionQueue
        do {
            let saved = try ICQueueSnapshotStorage.read(ICPersistedServerTranscriptionQueue.self, from: queueFileURL)
            let previousOwner = UserDefaults.standard.string(forKey: Self.clientIdentifierKey)
            let hasOwnedRequests = saved.map { !$0.items.isEmpty || !($0.cancellations ?? []).isEmpty } ?? false
            let savedOwner = saved?.ownerClientID ?? previousOwner
            if let savedOwner, UUID(uuidString: savedOwner) != nil {
                ownerClientID = savedOwner
            } else if !hasOwnedRequests && saved?.ownerClientID == nil {
                ownerClientID = UUID().uuidString
            } else {
                throw serverContractError(code: 23, message: NSLocalizedString("The saved server request owner is unavailable. Existing requests cannot be reassigned.", comment: ""))
            }
            if queueLoadError != nil { queuePersistenceError = nil }
            queueLoadError = nil
            // The snapshot is authoritative. Defaults are only a migration source for old installs.
            UserDefaults.standard.set(ownerClientID, forKey: Self.clientIdentifierKey)
            needsIdentityPersistence = saved?.ownerClientID == nil
            guard let saved else { return }
            persisted = saved
        } catch {
            queueLoadError = ICQueueSnapshotStorage.loadError(error)
            queuePersistenceError = queueLoadError
            return
        }
        cancellations = persisted.cancellations ?? []
        for index in cancellations.indices {
            if let retryAt = cancellations[index].nextRetryAt,
               !retryAt.timeIntervalSinceNow.isFinite || retryAt.timeIntervalSinceNow > Double(Self.maximumRetryInterval) {
                cancellations[index].retryable = false
                cancellations[index].nextRetryAt = nil
                cancellations[index].error = NSLocalizedString("The server returned an invalid retry interval. The cancellation remains saved. Retry it explicitly.", comment: "")
                needsIdentityPersistence = true
            }
        }
        for stored in persisted.items {
            if (stored.statusRawValue == ICTranscriptionStatus.completed.rawValue || stored.statusRawValue == ICTranscriptionStatus.canceled.rawValue),
               let completedAt = stored.completedAt,
               Date().timeIntervalSince(completedAt) > 30 * 60 {
                continue
            }
            let item = makeItem(episodeHash: stored.episodeHash,
                                episodeTitle: stored.episodeTitle,
                                feedTitle: stored.feedTitle,
                                episodeURL: stored.episodeURL,
                                podcastURL: stored.podcastURL,
                                duration: stored.duration,
                                automaticallyScheduled: stored.automaticallyScheduled)
            item.status = ICTranscriptionStatus(rawValue: stored.statusRawValue) ?? .queued
            item.error = stored.error
            item.nextRetryAt = stored.nextRetryAt
            item.completedAt = stored.completedAt
            item.progress = item.status == .completed ? 1 : 0
            item.statusDetail = stored.statusDetail
            item.serverWaitingForNetwork = stored.waitingForNetwork == true
            item.serverPhase = stored.serverPhase
            item.serverLastResponseAt = stored.lastResponseAt
            item.serverConnectionIssue = stored.connectionIssue == true
            item.statusStartedAt = stored.statusStartedAt
            item.requiresExplicitRetryAfterCrash = stored.requiresExplicitRetry == true
            if let retryAt = item.nextRetryAt,
               !retryAt.timeIntervalSinceNow.isFinite || retryAt.timeIntervalSinceNow > Double(Self.maximumRetryInterval) {
                schedulePoll(item, after: nil)
                needsIdentityPersistence = true
            }
            if let serverEpisodeID = stored.serverEpisodeID { serverIDByItem[ObjectIdentifier(item)] = serverEpisodeID }
            if let clientRequestID = stored.clientRequestID {
                clientRequestIDByItem[ObjectIdentifier(item)] = clientRequestID
            } else if stored.serverEpisodeID != nil {
                // Legacy accepted jobs keep their numeric identity until an explicit retry.
                clientRequestIDByItem.removeValue(forKey: ObjectIdentifier(item))
            } else {
                needsIdentityPersistence = true
            }
            explicitRestartByItem[ObjectIdentifier(item)] = stored.explicitRestart == true
            sourceAudioSHA256ByItem[ObjectIdentifier(item)] = stored.sourceAudioSHA256
            retryImportOnlyByItem[ObjectIdentifier(item)] = stored.retryImportOnly == true
            // Old snapshots without a numeric receipt may already have sent POST.
            admissionByItem[ObjectIdentifier(item)] = stored.admissionState ?? (stored.serverEpisodeID == nil ? .unconfirmed : .accepted)
            if admissionByItem[ObjectIdentifier(item)] == .unconfirmed,
               item.status == .queued, !item.requiresExplicitRetryAfterCrash, !item.serverWaitingForNetwork {
                item.statusDetail = NSLocalizedString("Checking whether the server received the saved request.", comment: "")
            }
            if stored.admissionState == .pending {
                // A durable unconfirmed marker is mandatory before POST. A remaining
                // pending snapshot therefore proves that this attempt was never sent.
                // Normalize silently during singleton initialization; publish on resume.
                admissionByItem[ObjectIdentifier(item)] = .rejected
                item.status = .failed
                item.error = NSLocalizedString("Not added: the app stopped before this request was submitted. Try again explicitly.", comment: "")
                item.statusDetail = nil
                item.statusStartedAt = nil
                item.nextRetryAt = nil
                item.completedAt = Date()
                needsIdentityPersistence = true
            }
            items.append(item)
        }
    }

    private func removeMetadata(for item: ICTranscriptionQueueItem) {
        admissionByItem.removeValue(forKey: ObjectIdentifier(item))
        admissionCompletions.removeValue(forKey: ObjectIdentifier(item))
        endpointByItem.removeValue(forKey: ObjectIdentifier(item))
        metadataByItem.removeValue(forKey: ObjectIdentifier(item))
        serverIDByItem.removeValue(forKey: ObjectIdentifier(item))
        clientRequestIDByItem.removeValue(forKey: ObjectIdentifier(item))
        explicitRestartByItem.removeValue(forKey: ObjectIdentifier(item))
        retryImportOnlyByItem.removeValue(forKey: ObjectIdentifier(item))
        sourceAudioSHA256ByItem.removeValue(forKey: ObjectIdentifier(item))
    }

    private func publishProcessingChange() {
        let processing = isProcessing
        guard publishedProcessingState != processing else { return }
        publishedProcessingState = processing
        NotificationCenter.default.post(name: NSNotification.Name("ICServerTranscriptionProcessingDidChangeNotification"), object: nil)
    }

    private func postQueueChange() {
        // Publish visible status, including the scheduled check shown in the UI.
        // Network/persistence ownership alone must not redraw the queue.
        publishProcessingChange()
        let state: NSDictionary = [
            "items": items.map { item -> NSDictionary in
                [
                    "identity": String(describing: ObjectIdentifier(item)),
                    "episodeHash": item.episodeHash,
                    "status": item.status.rawValue,
                    "progress": item.progress,
                    "statusDetail": item.statusDetail as Any? ?? NSNull(),
                    "requiresExplicitRetry": item.requiresExplicitRetryAfterCrash,
                    "waitingForNetwork": item.serverWaitingForNetwork,
                    "serverPhase": item.serverPhase as Any? ?? NSNull(),
                    "lastResponseAt": item.serverLastResponseAt as Any? ?? NSNull(),
                    "connectionIssue": item.serverConnectionIssue,
                    "nextRetryAt": item.nextRetryAt as Any? ?? NSNull(),
                    "admission": admissionByItem[ObjectIdentifier(item)]?.rawValue as Any? ?? NSNull(),
                    "statusStartedAt": item.statusStartedAt as Any? ?? NSNull(),
                    "completedAt": item.completedAt as Any? ?? NSNull(),
                    "error": item.error as Any? ?? NSNull(),
                ]
            },
            "persistenceError": queueStorageError as Any? ?? NSNull(),
            "cancellations": cancellations.map { cancellation -> NSDictionary in
                ["id": cancellation.id, "error": cancellation.error as Any? ?? NSNull(), "retryable": cancellation.retryable]
            },
        ]
        guard publishedQueueState?.isEqual(state) != true else { return }
        publishedQueueState = state
        NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionQueueDidChangeNotification"), object: nil)
    }
}
