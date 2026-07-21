//
//  ServerTranscriptionManager.swift
//  Instacast
//
//  Durable client for the shared Instacast transcription service.
//

import CryptoKit
import Foundation

private struct ICServerEpisodeEnvelope: Decodable {
    let episode: ICServerEpisode
    let retryAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case episode
        case retryAfterSeconds = "retry_after_seconds"
    }
}

private struct ICServerEpisode: Decodable {
    let id: Int
    let status: String
    let phase: String
    let progress: Double?
    let error: ICServerError?
    let artifacts: [ICServerArtifact]
}

private struct ICServerArtifact: Decodable {
    let id: Int
    let kind: String
    let url: URL
    let sha256: String?
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
    let summary: String
}

private struct ICServerChaptersArtifact: Decodable {
    struct Chapter: Decodable {
        let start: Double
        let end: Double
        let title: String
        let isSponsor: Bool?

        enum CodingKeys: String, CodingKey {
            case start
            case end
            case title
            case isSponsor = "is_sponsor"
        }
    }

    let chapters: [Chapter]
}

private struct ICServerAdsArtifact: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let title: String
    }

    let segments: [Segment]
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
    }

    let items: [Item]
}

@MainActor
@objc class ServerTranscriptionManager: NSObject {
    @objc static let shared = ServerTranscriptionManager()
    @objc private(set) var items: [ICTranscriptionQueueItem] = []

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
    private var retryWakeTask: Task<Void, Never>?

    private override init() {
        super.init()
        loadPersistedQueue()
        resumeIfNeeded()
    }

    @objc var isProcessing: Bool { currentTask != nil }

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
        currentTask?.cancel()
        items.removeAll { $0 === item }
        removeMetadata(for: item)
        persistQueue()
        postQueueChange()
        TranscriptionQueue.shared.scheduleAutomaticBackgroundProcessingIfNeeded()
        processNext()
    }

    @objc func retryEpisodeHash(_ episodeHash: String) {
        guard let item = items.first(where: { $0.episodeHash == episodeHash && $0.usesServerTranscription }) else { return }
        item.status = .queued
        item.error = nil
        item.statusDetail = nil
        item.progress = 0
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
        guard currentTask == nil,
              let item = items.first(where: {
                  $0.status == .queued && ($0.nextRetryAt == nil || $0.nextRetryAt! <= Date())
              }) else {
            scheduleRetryWake()
            return
        }
        guard let episodeURL = endpointByItem[ObjectIdentifier(item)] else {
            fail(item, message: NSLocalizedString("Die URL der Server-Transkription fehlt.", comment: ""))
            return
        }

        item.status = .transcribing
        item.statusStartedAt = Date()
        item.statusDetail = NSLocalizedString("Server verarbeitet die Episode.", comment: "")
        postQueueChange()

        currentTask = Task { [weak self] in
            guard let self else { return }
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
                await self.handle(error: error, for: item)
            }
        }
    }

    private func apply(_ envelope: ICServerEpisodeEnvelope, to item: ICTranscriptionQueueItem) async {
        guard items.contains(where: { $0 === item }) else { return }
        let episode = envelope.episode
        item.progress = Float(episode.progress ?? 0)
        item.statusDetail = localizedPhase(episode.phase)
        switch episode.status {
        case "ready":
            item.status = .generatingChapters
            item.statusDetail = NSLocalizedString("Server-Ergebnis wird geprüft und übernommen.", comment: "")
            postQueueChange()
            do {
                try await importArtifacts(episode.artifacts, for: item)
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
            } catch {
                fail(item, message: error.localizedDescription)
            }
        case "failed", "canceled":
            if episode.error?.retryable == true {
                requeue(item, after: envelope.retryAfterSeconds)
            } else {
                fail(item, message: episode.error?.message ?? NSLocalizedString("Die Server-Verarbeitung ist fehlgeschlagen.", comment: ""))
            }
        case "queued", "running":
            requeue(item, after: envelope.retryAfterSeconds)
        default:
            fail(item, message: NSLocalizedString("Der Server lieferte einen unbekannten Verarbeitungsstatus.", comment: ""))
        }
        currentTask = nil
        persistQueue()
        postQueueChange()
        processNext()
    }

    private func requeue(_ item: ICTranscriptionQueueItem, after seconds: Int?) {
        item.status = .queued
        item.statusStartedAt = nil
        item.nextRetryAt = Date().addingTimeInterval(TimeInterval(max(1, seconds ?? Int(Self.retryDelay))))
        item.statusDetail = NSLocalizedString("Server-Verarbeitung läuft weiter.", comment: "")
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
        currentTask = nil
        persistQueue()
        postQueueChange()
        processNext()
    }

    private func handle(error: Error, for item: ICTranscriptionQueueItem) async {
        let nsError = error as NSError
        if nsError.domain == "ICServerTranscription" && nsError.code >= 400 && nsError.code < 500 && nsError.code != 429 {
            fail(item, message: nsError.localizedDescription)
            return
        }
        requeue(item, after: retryAfter(from: nsError) ?? Int(Self.retryDelay))
        item.statusDetail = NSLocalizedString("Server vorübergehend nicht erreichbar. Neuer Versuch ist geplant.", comment: "")
        currentTask = nil
        persistQueue()
        postQueueChange()
        processNext()
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
        var request = URLRequest(url: artifact.url)
        request.setValue("Bearer \(Self.bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientIdentifier(), forHTTPHeaderField: "X-Instacast-Client-ID")
        request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0", forHTTPHeaderField: "X-Instacast-App-Version")
        request.setValue("iOS", forHTTPHeaderField: "X-Instacast-Platform")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "ICServerTranscription", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Ein Server-Artefakt konnte nicht geladen werden.", comment: "")])
        }
        if let expected = artifact.sha256?.lowercased(), !expected.isEmpty {
            let received = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard received == expected else {
                throw NSError(domain: "ICServerTranscription", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Ein Server-Artefakt ist beschädigt.", comment: "")])
            }
        }
        return data
    }

    private func importArtifacts(_ artifacts: [ICServerArtifact], for item: ICTranscriptionQueueItem) async throws {
        func artifact(_ kind: String) throws -> ICServerArtifact {
            guard let result = artifacts.first(where: { $0.kind == kind }) else {
                throw NSError(domain: "ICServerTranscription", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Das Server-Ergebnis ist unvollständig.", comment: "")])
            }
            return result
        }
        let srtData = try await download(artifact("transcript_srt"))
        let chaptersData = try await download(artifact("chapters_json"))
        let adsData = try await download(artifact("ads_json"))
        let summaryData = try await download(artifact("summary_json"))
        let cues = try TranscriptionEngine.shared.importServerSRTData(srtData, for: item.episodeHash)
        let chapters = try JSONDecoder().decode(ICServerChaptersArtifact.self, from: chaptersData).chapters
        let ads = try JSONDecoder().decode(ICServerAdsArtifact.self, from: adsData).segments
        let summary = try JSONDecoder().decode(ICServerSummaryArtifact.self, from: summaryData).summary
        guard let episode = findEpisode(hash: item.episodeHash) else {
            throw NSError(domain: "ICServerTranscription", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Die Episode wurde während der Server-Verarbeitung entfernt.", comment: "")])
        }
        let baseChapters = publisherChapters(for: episode, fallback: chapters)
        let sponsors = ads.map { ICSponsorSegment(start: $0.start, end: $0.end, title: $0.title, evidenceCueIDs: []) }
        try ChapterGenerator.shared.saveServerAnalysis(baseChapters,
                                                       sponsorSegments: sponsors,
                                                       summary: summary,
                                                       transcriptCues: cues,
                                                       for: item.episodeHash)
    }

    private func publisherChapters(for episode: CDEpisode,
                                   fallback: [ICServerChaptersArtifact.Chapter]) -> [ICGeneratedChapter] {
        let stored = (episode.sortedChapters() as? [CDChapter]) ?? []
        if !stored.isEmpty {
            let timelineEnd = max(Double(episode.duration), fallback.map(\.end).max() ?? 0)
            return stored.enumerated().compactMap { index, chapter in
                let nextStart = index + 1 < stored.count ? stored[index + 1].timecode : timelineEnd
                let end = chapter.duration > 0 ? chapter.timecode + chapter.duration : nextStart
                guard chapter.timecode >= 0, end > chapter.timecode else { return nil }
                return ICGeneratedChapter(start: chapter.timecode, end: end, title: chapter.title ?? "", isSponsor: false)
            }
        }
        return fallback.filter { !($0.isSponsor ?? false) }.compactMap {
            guard $0.end > $0.start else { return nil }
            return ICGeneratedChapter(start: $0.start, end: $0.end, title: $0.title, isSponsor: false)
        }
    }

    private func localizedPhase(_ phase: String) -> String {
        switch phase {
        case "queued": return NSLocalizedString("Server: Warteschlange", comment: "")
        case "downloading_audio": return NSLocalizedString("Server lädt Audio.", comment: "")
        case "transcribing": return NSLocalizedString("Server transkribiert.", comment: "")
        case "analyzing": return NSLocalizedString("Server erstellt Kapitel, Sponsoren und Zusammenfassung.", comment: "")
        case "finalizing": return NSLocalizedString("Server bereitet das Ergebnis vor.", comment: "")
        default: return NSLocalizedString("Server verarbeitet die Episode.", comment: "")
        }
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
                         completedAt: item.completedAt)
        })
        do {
            let data = try JSONEncoder().encode(persisted)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
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
            if item.status == .transcribing || item.status == .generatingChapters { item.status = .queued }
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
