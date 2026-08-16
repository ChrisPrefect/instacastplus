//
//  ServerTranscriptionManager.swift
//  Instacast
//
//  Durable client for the shared Instacast transcription service.
//

import CryptoKit
import Foundation

private struct ICServerEpisodeEnvelope: Decodable {
    let apiVersion: String
    let episode: ICServerEpisode
    let retryAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case episode
        case retryAfterSeconds = "retry_after_seconds"
    }
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

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case phase
        case progress
        case serverDurationSeconds = "server_duration_seconds"
        case warnings
        case error
        case artifacts
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
}

private struct ICServerAPIErrorEnvelope: Decodable {
    let error: ICServerError
}

private struct ICServerSummaryArtifact: Decodable {
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

private struct ICServerChaptersArtifact: Decodable {
    struct Chapter: Decodable {
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

private struct ICServerAdsArtifact: Decodable {
    struct Segment: Decodable {
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

private struct ICPersistedServerTranscriptionQueue: Codable {
    struct Item: Codable {
        let episodeHash: String
        let episodeTitle: String
        let feedTitle: String
        let episodeURL: URL
        let podcastURL: URL?
        let duration: Double
        let serverEpisodeID: Int?
        let automaticallyScheduled: Bool
        let statusRawValue: Int
        let error: String?
        let nextRetryAt: Date?
        let completedAt: Date?
        let progress: Float?
        let statusDetail: String?
        let statusStartedAt: Date?
    }

    let items: [Item]
}

@MainActor
@objc class ServerTranscriptionManager: NSObject {
    @objc static let shared = ServerTranscriptionManager()
    @objc private(set) var items: [ICTranscriptionQueueItem] = []
    @objc private(set) var queuePersistenceError: NSError?

    private static let queueFileName = "ServerTranscriptionQueue.json"
    private static let clientIdentifierKey = "ICServerTranscriptionClientIdentifier"
    private static let retryDelay: TimeInterval = 30
    /// Same retention rule as the local queue (TranscriptionQueue.completedItemRetentionInterval).
    private static let completedItemRetentionInterval: TimeInterval = 30 * 60

    // This is a shared application token, intentionally not a per-user credential.
    // Do not log it or include it in diagnostics.
    private static let bearerToken = "ictr_Bp0J1cdWUxrLxGcCI8M0INcCkntohS_yAPysQJUp5mQ"
    private let baseURL = URL(string: "https://transcript.instacast.ch/api/v1/")!
    private var endpointByItem: [ObjectIdentifier: URL] = [:]
    private var metadataByItem: [ObjectIdentifier: (podcastURL: URL?, duration: Double)] = [:]
    private var serverIDByItem: [ObjectIdentifier: Int] = [:]
    private var currentTask: Task<Void, Never>?
    private var currentItem: ICTranscriptionQueueItem?
    private var retryWakeTask: Task<Void, Never>?

    /// The initializer must not publish state. `shared` is a `static let`, so init runs
    /// inside `swift_once`: `resumeIfNeeded()` → `processNext()` → `postQueueChange()`
    /// posted a notification while `shared` was still being created, the observer read
    /// `TranscriptionQueue.displayItems`, that re-entered `ServerTranscriptionManager.shared`
    /// and the re-entrant once-token trapped (EXC_BREAKPOINT at launch).
    /// Resuming is owned by the launch/foreground path (`TranscriptionQueue.resumeIfNeeded`).
    private override init() {
        super.init()
        loadPersistedQueue()
    }

    @objc var isProcessing: Bool { currentItem != nil }

    var hasPendingAutomaticItems: Bool {
        items.contains {
            $0.automaticallyScheduled && $0.status != .completed && $0.status != .failed
        }
    }

    var earliestAutomaticWorkDate: Date? {
        let pending = items.filter {
            $0.automaticallyScheduled && $0.status != .completed && $0.status != .failed
        }
        guard !pending.isEmpty else { return nil }
        if pending.contains(where: { $0.nextRetryAt == nil }) { return Date() }
        return pending.compactMap(\.nextRetryAt).min()
    }

    @objc func enqueueEpisode(_ episode: CDEpisode) -> Bool {
        guard UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled),
              let episodeHash = episode.objectHash, !episodeHash.isEmpty,
              let episodeURL = episode.preferedMedium()?.fileURL,
              let scheme = episodeURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        if let existing = items.first(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription }) {
            // Only a run that is still going owns the episode. A finished or failed entry
            // stays in the list until the user removes it — treating it as "already queued"
            // made the episode permanently unsubmittable.
            guard existing.status == .completed || existing.status == .failed else { return false }
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
        items.append(item)
        persistQueue()
        TranscriptionLogger.shared.resetLog(episodeHash: episodeHash)
        TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                          phase: "server",
                                          message: NSLocalizedString("Server-Transkription eingereicht", comment: ""),
                                          detailText: nil)
        postQueueChange()
        processNext()
        return true
    }

    /// Existing per-podcast automatic settings decide *whether* a feed is processed.
    /// The selected backend decides that this one server queue is used.
    @objc func enqueueAutomaticEpisodes(_ episodes: [CDEpisode]) {
        guard UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled) else { return }
        for episode in episodes {
            guard let episodeHash = episode.objectHash, !episodeHash.isEmpty,
                  let episodeURL = episode.preferedMedium()?.fileURL,
                  let scheme = episodeURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  !items.contains(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription }) else {
                continue
            }
            let item = makeItem(episodeHash: episodeHash,
                                episodeTitle: episode.title ?? "",
                                feedTitle: episode.feed?.title ?? "",
                                episodeURL: episodeURL,
                                podcastURL: episode.feed?.sourceURL,
                                duration: Double(max(0, episode.duration)),
                                automaticallyScheduled: true)
            items.append(item)
            TranscriptionLogger.shared.append(episodeHash: episodeHash,
                                              phase: "server",
                                              message: NSLocalizedString("Automatische Server-Transkription eingereicht", comment: ""),
                                              detailText: nil)
        }
        persistQueue()
        postQueueChange()
        TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
        processNext()
    }

    @objc func dequeueEpisodeHash(_ episodeHash: String) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription }) else { return }
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
        serverIDByItem.removeValue(forKey: ObjectIdentifier(item))
        item.status = .queued
        item.error = nil
        item.statusDetail = nil
        item.progress = 0
        item.statusStartedAt = nil
        item.nextRetryAt = nil
        persistQueue()
        postQueueChange()
        processNext()
    }

    @objc func cancelAll() {
        currentTask?.cancel()
        for item in items { removeMetadata(for: item) }
        items.removeAll()
        persistQueue()
        postQueueChange()
    }

    /// True while a submitted run still owns the episode. Completed and failed entries
    /// are history, not ownership.
    @objc func hasActiveItem(forEpisodeHash episodeHash: String) -> Bool {
        items.contains {
            $0.episodeHash == episodeHash && $0.usesServerTranscription
                && $0.status != .completed && $0.status != .failed
        }
    }

    /// Drops finished entries past the retention window, mirroring the local queue.
    /// Read path only — deliberately no file write and no notification here.
    @objc func pruneExpiredCompletedItems(now: Date = Date()) {
        items.removeAll { item in
            guard item.status == .completed else { return false }
            guard let completedAt = item.completedAt else { return true }
            return now.timeIntervalSince(completedAt) >= Self.completedItemRetentionInterval
        }
    }

    @objc func resumeIfNeeded() {
        guard UserDefaults.standard.bool(forKey: kServerTranscriptionEnabled) else { return }
        processNext()
    }

    @objc func retryQueuePersistenceAfterFailure() {
        guard queuePersistenceError != nil else { return }
        persistQueue()
        if queuePersistenceError == nil {
            processNext()
        }
        postQueueChange()
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
        endpointByItem[ObjectIdentifier(item)] = episodeURL
        metadataByItem[ObjectIdentifier(item)] = (podcastURL, duration)
        item.statusDetail = NSLocalizedString("Wartet auf die Server-Verarbeitung.", comment: "")
        return item
    }

    private func processNext() {
        guard queuePersistenceError == nil,
              currentTask == nil,
              let item = items.first(where: {
                  ($0.status == .queued || $0.status == .transcribing || $0.status == .generatingChapters) &&
                      ($0.nextRetryAt == nil || $0.nextRetryAt! <= Date())
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
        if item.status != .transcribing {
            item.status = .transcribing
            item.statusDetail = NSLocalizedString("Server verarbeitet die Episode.", comment: "")
        }
        if item.statusStartedAt == nil { item.statusStartedAt = Date() }
        currentItem = item
        postQueueChange()

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
                if let serverID = self.serverIDByItem[ObjectIdentifier(item)] {
                    envelope = try await self.fetchEpisode(id: serverID)
                } else {
                    envelope = try await self.submitEpisode(url: episodeURL,
                                                            podcastURL: self.podcastURL(for: item),
                                                            title: item.episodeTitle,
                                                            duration: self.duration(for: item))
                    self.serverIDByItem[ObjectIdentifier(item)] = envelope.episode.id
                }
                await self.apply(envelope, to: item)
            } catch is CancellationError {
                // The durable queue entry remains untouched and can resume.
            } catch {
                guard !Task.isCancelled else { return }
                await self.handle(error: error, for: item)
            }
        }
    }

    private func apply(_ envelope: ICServerEpisodeEnvelope, to item: ICTranscriptionQueueItem) async {
        guard items.contains(where: { $0 === item }) else { return }
        guard envelope.apiVersion == "v1" else {
            fail(item, message: NSLocalizedString("Der Transkriptionsserver lieferte eine unbekannte API-Version.", comment: ""))
            return
        }
        let episode = envelope.episode
        guard let phase = localizedPhase(episode.phase) else {
            fail(item, message: NSLocalizedString("Der Transkriptionsserver lieferte eine unbekannte Verarbeitungsphase.", comment: ""))
            return
        }
        if let progress = episode.progress {
            guard progress.isFinite, (0...1).contains(progress), progress + 0.000_001 >= Double(item.progress) else {
                fail(item, message: NSLocalizedString("Der Transkriptionsserver lieferte einen ungültigen oder rückläufigen Fortschritt.", comment: ""))
                return
            }
            item.progress = Float(progress)
        } else if episode.status == "queued" || episode.status == "running" {
            fail(item, message: NSLocalizedString("Der Transkriptionsserver lieferte keinen Fortschritt für den laufenden Auftrag.", comment: ""))
            return
        }
        item.statusDetail = phase
        switch episode.status {
        case "ready":
            if let warning = episode.warnings.first(where: { $0.timingMayBeShifted == true }) {
                fail(item, message: String(format: NSLocalizedString("Server-Zeitmarken sind nicht zuverlässig: %@", comment: ""), warning.message))
                return
            }
            item.status = .generatingChapters
            item.statusDetail = NSLocalizedString("Server-Ergebnis wird geprüft und übernommen.", comment: "")
            postQueueChange()
            do {
                try await importArtifacts(episode.artifacts,
                                          serverDuration: episode.serverDurationSeconds,
                                          for: item)
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
                if isTransient(error) {
                    schedulePoll(item, after: retryAfter(from: error as NSError) ?? Int(Self.retryDelay))
                    item.statusDetail = NSLocalizedString("Server-Ergebnis konnte vorübergehend nicht geladen werden. Neuer Versuch ist geplant.", comment: "")
                } else {
                    fail(item, message: error.localizedDescription)
                }
            }
        case "failed", "canceled":
            fail(item, message: episode.error?.message ?? NSLocalizedString("Die Server-Verarbeitung ist fehlgeschlagen.", comment: ""))
        case "queued", "running":
            guard let retryAfter = envelope.retryAfterSeconds, retryAfter > 0 else {
                fail(item, message: NSLocalizedString("Der Transkriptionsserver lieferte keinen gültigen Zeitpunkt für die nächste Statusabfrage.", comment: ""))
                return
            }
            schedulePoll(item, after: retryAfter)
        default:
            fail(item, message: NSLocalizedString("Der Server lieferte einen unbekannten Verarbeitungsstatus.", comment: ""))
        }
    }

    private func schedulePoll(_ item: ICTranscriptionQueueItem, after seconds: Int?) {
        item.nextRetryAt = Date().addingTimeInterval(TimeInterval(max(1, seconds ?? Int(Self.retryDelay))))
        if item.automaticallyScheduled {
            TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
        }
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
        guard isTransient(error) else {
            fail(item, message: nsError.localizedDescription)
            return
        }
        schedulePoll(item, after: retryAfter(from: nsError) ?? Int(Self.retryDelay))
        item.statusDetail = NSLocalizedString("Server vorübergehend nicht erreichbar. Neuer Versuch ist geplant.", comment: "")
    }

    private func submitEpisode(url: URL, podcastURL: URL?, title: String, duration: Double) async throws -> ICServerEpisodeEnvelope {
        var body: [String: Any] = [
            "episode_url": url.absoluteString,
            "title": title,
            "client_duration_seconds": duration,
            "wait_seconds": 0,
            "force": false,
        ]
        if let podcastURL { body["podcast_url"] = podcastURL.absoluteString }
        return try await request(path: "episodes", method: "POST", body: body)
    }

    private func fetchEpisode(id: Int) async throws -> ICServerEpisodeEnvelope {
        try await request(path: "episodes/\(id)", method: "GET", body: nil)
    }

    private func request<T: Decodable>(path: String, method: String, body: [String: Any]?) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(Self.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientIdentifier(), forHTTPHeaderField: "X-Instacast-Client-ID")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0", forHTTPHeaderField: "X-Instacast-App-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Instacast-Platform")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "ICServerTranscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Der Transkriptionsserver lieferte keine HTTP-Antwort.", comment: "")])
        }
        guard (200...299).contains(http.statusCode) else {
            let apiError = try? JSONDecoder().decode(ICServerAPIErrorEnvelope.self, from: data).error
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: apiError?.message ?? NSLocalizedString("Die Anfrage an den Transkriptionsserver ist fehlgeschlagen.", comment: "")]
            if let retry = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(retry) { userInfo["retryAfter"] = seconds }
            throw NSError(domain: "ICServerTranscription", code: http.statusCode, userInfo: userInfo)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func download(_ artifact: ICServerArtifact) async throws -> Data {
        let expectedURL = baseURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(String(artifact.id), isDirectory: false)
        guard artifact.url == expectedURL,
              artifact.byteSize >= 0,
              artifact.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              !artifact.contentType.isEmpty,
              !artifact.etag.isEmpty else {
            throw serverContractError(code: 5,
                                      message: NSLocalizedString("Ein Server-Artefakt hat einen ungültigen Deskriptor.", comment: ""))
        }
        var request = URLRequest(url: expectedURL)
        request.setValue("Bearer \(Self.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientIdentifier(), forHTTPHeaderField: "X-Instacast-Client-ID")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0", forHTTPHeaderField: "X-Instacast-App-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Instacast-Platform")
        request.setValue(artifact.contentType, forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw serverContractError(code: -1,
                                      message: NSLocalizedString("Ein Server-Artefakt lieferte keine HTTP-Antwort.", comment: ""))
        }
        guard (200...299).contains(http.statusCode) else {
            let apiError = try? JSONDecoder().decode(ICServerAPIErrorEnvelope.self, from: data).error
            var userInfo: [String: Any] = [
                NSLocalizedDescriptionKey: apiError?.message ?? NSLocalizedString("Ein Server-Artefakt konnte nicht geladen werden.", comment: "")
            ]
            if let retry = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(retry) {
                userInfo["retryAfter"] = seconds
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
                                 for item: ICTranscriptionQueueItem) async throws {
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
        let cues = try TranscriptionEngine.shared.validateServerSRTData(srtData, for: item.episodeHash)
        let chaptersArtifact = try JSONDecoder().decode(ICServerChaptersArtifact.self, from: chaptersData)
        let adsArtifact = try JSONDecoder().decode(ICServerAdsArtifact.self, from: adsData)
        let summaryArtifact = try JSONDecoder().decode(ICServerSummaryArtifact.self, from: summaryData)
        try validateServerArtifacts(chaptersArtifact,
                                    ads: adsArtifact,
                                    summary: summaryArtifact,
                                    transcriptRevision: transcriptRevision,
                                    serverDuration: serverDuration)
        guard let episode = findEpisode(hash: item.episodeHash) else {
            throw serverContractError(code: 11,
                                      message: NSLocalizedString("Die Episode wurde während der Server-Verarbeitung entfernt.", comment: ""))
        }
        let baseChapters = publisherChapters(for: episode, fallback: chaptersArtifact.chapters)
        let sponsors = adsArtifact.segments.map {
            ICSponsorSegment(start: $0.start, end: $0.end, title: $0.title, evidenceCueIDs: [])
        }
        let analysis = try ChapterGenerator.shared.makeServerAnalysis(baseChapters,
                                                                      sponsorSegments: sponsors,
                                                                      summary: summaryArtifact.summary,
                                                                      transcriptCues: cues)
        try TranscriptionEngine.shared.saveValidatedServerSRTData(srtData,
                                                                  cues: cues,
                                                                  for: item.episodeHash)
        try ChapterGenerator.shared.saveAnalysisResult(analysis, for: item.episodeHash)
    }

    private func validateServerArtifacts(_ chapters: ICServerChaptersArtifact,
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

    private func sameMillisecond(_ lhs: Double, _ rhs: Double) -> Bool {
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
        case "queued": return NSLocalizedString("Server: Warteschlange", comment: "")
        case "downloading_audio": return NSLocalizedString("Server lädt Audio.", comment: "")
        case "transcribing": return NSLocalizedString("Server transkribiert.", comment: "")
        case "analyzing": return NSLocalizedString("Server erstellt Kapitel, Sponsoren und Zusammenfassung.", comment: "")
        case "finalizing": return NSLocalizedString("Server bereitet das Ergebnis vor.", comment: "")
        case "ready": return NSLocalizedString("Server-Ergebnis ist bereit.", comment: "")
        case "failed": return NSLocalizedString("Server-Verarbeitung ist fehlgeschlagen.", comment: "")
        case "canceled": return NSLocalizedString("Server-Verarbeitung wurde abgebrochen.", comment: "")
        default: return nil
        }
    }

    private func serverContractError(code: Int, message: String) -> NSError {
        NSError(domain: "ICServerTranscription.Contract",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func isTransient(_ error: Error) -> Bool {
        let nsError = error as NSError
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

    private func clientIdentifier() -> String {
        if let identifier = UserDefaults.standard.string(forKey: Self.clientIdentifierKey), UUID(uuidString: identifier) != nil { return identifier }
        let identifier = UUID().uuidString
        UserDefaults.standard.set(identifier, forKey: Self.clientIdentifierKey)
        return identifier
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

    private func retryAfter(from error: NSError) -> Int? { error.userInfo["retryAfter"] as? Int }

    private func scheduleRetryWake() {
        retryWakeTask?.cancel()
        guard let date = items.compactMap(\.nextRetryAt).min() else { return }
        let delay = max(0, date.timeIntervalSinceNow)
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
        let persisted = ICPersistedServerTranscriptionQueue(items: items.compactMap { item in
            guard let episodeURL = endpointByItem[ObjectIdentifier(item)] else { return nil }
            return .init(episodeHash: item.episodeHash,
                         episodeTitle: item.episodeTitle,
                         feedTitle: item.feedTitle,
                         episodeURL: episodeURL,
                         podcastURL: podcastURL(for: item),
                         duration: duration(for: item),
                         serverEpisodeID: serverIDByItem[ObjectIdentifier(item)],
                         automaticallyScheduled: item.automaticallyScheduled,
                         statusRawValue: item.status.rawValue,
                         error: item.error,
                         nextRetryAt: item.nextRetryAt,
                         completedAt: item.completedAt,
                         progress: item.progress,
                         statusDetail: item.statusDetail,
                         statusStartedAt: item.statusStartedAt)
        })
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: queueFileURL, options: .atomic)
            queuePersistenceError = nil
        } catch {
            queuePersistenceError = error as NSError
            NSLog("[ServerTranscription] Queue persistence failed: %@", error.localizedDescription)
        }
    }

    private func loadPersistedQueue() {
        guard let data = try? Data(contentsOf: queueFileURL),
              let persisted = try? JSONDecoder().decode(ICPersistedServerTranscriptionQueue.self, from: data) else { return }
        for stored in persisted.items {
            if stored.statusRawValue == ICTranscriptionStatus.completed.rawValue,
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
            item.progress = stored.progress ?? 0
            item.statusDetail = stored.statusDetail
            item.statusStartedAt = stored.statusStartedAt
            if let serverEpisodeID = stored.serverEpisodeID { serverIDByItem[ObjectIdentifier(item)] = serverEpisodeID }
            items.append(item)
        }
    }

    private func removeMetadata(for item: ICTranscriptionQueueItem) {
        endpointByItem.removeValue(forKey: ObjectIdentifier(item))
        metadataByItem.removeValue(forKey: ObjectIdentifier(item))
        serverIDByItem.removeValue(forKey: ObjectIdentifier(item))
    }

    private func postQueueChange() {
        NotificationCenter.default.post(name: NSNotification.Name("ICTranscriptionQueueDidChangeNotification"), object: nil)
    }
}
