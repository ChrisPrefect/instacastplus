import Foundation

enum WatchSelectionSource: String, Codable, Sendable {
    case manual
    case latestRule
}

enum WatchEpisodeStatus: String, Codable, Sendable {
    case queued
    case downloading
    case downloaded
    case failed
    case evicted
    case removing
}

struct WatchChapter: Codable, Identifiable, Equatable, Sendable {
    var id: Int { startSeconds }

    let title: String
    let startSeconds: Int
    let endSeconds: Int?
    let imageFileName: String?

    func contains(position: TimeInterval, episodeDuration: Int) -> Bool {
        let start = TimeInterval(startSeconds)
        let end = TimeInterval(endSeconds ?? episodeDuration)
        return position >= start && position < max(start, end)
    }
}

struct WatchManifestEntry: Sendable {
    let episodeHash: String
    let selectionIdentifier: String
    let feedIdentifier: String
    let title: String
    let podcastTitle: String
    let imageURL: URL?
    let pubDate: Date
    let durationHint: Int
    let position: Int
    let consumed: Bool
    let mediaURL: URL
    let selectionSource: WatchSelectionSource
    let watchAddedDate: Date
    let playbackOrder: Int?
    let skipForwardSeconds: Int
    let skipBackwardSeconds: Int
    let expectedFileSize: Int64
    let skipChapterNames: [String]
    let autoSkipSponsors: Bool
}

struct WatchEpisode: Codable, Identifiable, Equatable, Sendable {
    var id: String { episodeHash }

    var episodeHash: String
    var selectionIdentifier: String
    var feedIdentifier: String
    var title: String
    var podcastTitle: String
    var imageURL: URL?
    var pubDate: Date
    var durationHint: Int
    var mediaURL: URL
    var selectionSource: WatchSelectionSource
    var watchAddedDate: Date
    var playbackOrder: Int?
    var status: WatchEpisodeStatus
    var localFileURL: URL?
    var actualFileSize: Int64
    var actualDuration: Int
    var lastPlaybackPosition: Int
    var lastPlaybackDate: Date?
    var consumed: Bool
    var lastError: String?
    var pendingRemovalRetryRequired: Bool
    var downloadedBytes: Int64
    var expectedBytes: Int64
    var skipForwardSeconds: Int
    var skipBackwardSeconds: Int
    var skipChapterNames: [String]
    var autoSkipSponsors: Bool
    var chapters: [WatchChapter]
    var chapterArtworkBaseURL: URL?

    var sortDate: Date {
        selectionSource == .manual ? watchAddedDate : pubDate
    }

    var displayDuration: Int {
        actualDuration > 0 ? actualDuration : durationHint
    }

    var hasPlaybackFileRemovalError: Bool {
        guard status == .downloaded, localFileURL != nil else { return false }
        return !(lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var hasPendingRemovalError: Bool {
        guard status == .removing, pendingRemovalRetryRequired else { return false }
        return !(lastError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var remainingSeconds: Int {
        max(0, displayDuration - lastPlaybackPosition)
    }

    var progressFraction: Double? {
        guard status == .downloading, expectedBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(expectedBytes)))
    }

    private enum CodingKeys: String, CodingKey {
        case episodeHash
        case selectionIdentifier
        case feedIdentifier
        case title
        case podcastTitle
        case imageURL
        case pubDate
        case durationHint
        case mediaURL
        case selectionSource
        case watchAddedDate
        case playbackOrder
        case status
        case localFileURL
        case actualFileSize
        case actualDuration
        case lastPlaybackPosition
        case lastPlaybackDate
        case consumed
        case lastError
        case pendingRemovalRetryRequired
        case downloadedBytes
        case expectedBytes
        case skipForwardSeconds
        case skipBackwardSeconds
        case skipChapterNames
        case autoSkipSponsors
        case chapters
        case chapterArtworkBaseURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        episodeHash = try container.decode(String.self, forKey: .episodeHash)
        selectionIdentifier = try container.decodeIfPresent(String.self, forKey: .selectionIdentifier) ?? ""
        feedIdentifier = try container.decode(String.self, forKey: .feedIdentifier)
        title = try container.decode(String.self, forKey: .title)
        podcastTitle = try container.decode(String.self, forKey: .podcastTitle)
        imageURL = try container.decodeIfPresent(URL.self, forKey: .imageURL)
        pubDate = try container.decode(Date.self, forKey: .pubDate)
        durationHint = try container.decode(Int.self, forKey: .durationHint)
        mediaURL = try container.decode(URL.self, forKey: .mediaURL)
        selectionSource = try container.decode(WatchSelectionSource.self, forKey: .selectionSource)
        watchAddedDate = try container.decode(Date.self, forKey: .watchAddedDate)
        playbackOrder = try container.decodeIfPresent(Int.self, forKey: .playbackOrder)
        status = try container.decode(WatchEpisodeStatus.self, forKey: .status)
        localFileURL = try container.decodeIfPresent(URL.self, forKey: .localFileURL)
        actualFileSize = try container.decode(Int64.self, forKey: .actualFileSize)
        actualDuration = try container.decode(Int.self, forKey: .actualDuration)
        lastPlaybackPosition = try container.decode(Int.self, forKey: .lastPlaybackPosition)
        lastPlaybackDate = try container.decodeIfPresent(Date.self, forKey: .lastPlaybackDate)
        consumed = try container.decode(Bool.self, forKey: .consumed)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        pendingRemovalRetryRequired = try container.decodeIfPresent(
            Bool.self,
            forKey: .pendingRemovalRetryRequired
        ) ?? false
        downloadedBytes = try container.decode(Int64.self, forKey: .downloadedBytes)
        expectedBytes = try container.decode(Int64.self, forKey: .expectedBytes)
        skipForwardSeconds = max(1, try container.decodeIfPresent(Int.self, forKey: .skipForwardSeconds) ?? 30)
        skipBackwardSeconds = max(1, try container.decodeIfPresent(Int.self, forKey: .skipBackwardSeconds) ?? 30)
        skipChapterNames = try container.decodeIfPresent([String].self, forKey: .skipChapterNames) ?? []
        autoSkipSponsors = try container.decodeIfPresent(Bool.self, forKey: .autoSkipSponsors) ?? false
        chapters = try container.decodeIfPresent([WatchChapter].self, forKey: .chapters) ?? []
        chapterArtworkBaseURL = try container.decodeIfPresent(URL.self, forKey: .chapterArtworkBaseURL)
    }
}

extension WatchManifestEntry {
    init?(dictionary: [String: Any], dateFormatter: ISO8601DateFormatter) {
        guard
            let episodeHash = dictionary["episodeHash"] as? String, !episodeHash.isEmpty,
            let feedIdentifier = dictionary["feedIdentifier"] as? String,
            let title = dictionary["title"] as? String,
            let podcastTitle = dictionary["podcastTitle"] as? String,
            let pubDateString = dictionary["pubDate"] as? String,
            let pubDate = dateFormatter.date(from: pubDateString),
            let mediaURLString = dictionary["mediaURL"] as? String,
            let mediaURL = URL(string: mediaURLString),
            let selectionSourceRaw = dictionary["selectionSource"] as? String,
            let selectionSource = WatchSelectionSource(rawValue: selectionSourceRaw),
            let addedDateString = dictionary["watchAddedDate"] as? String,
            let watchAddedDate = dateFormatter.date(from: addedDateString)
        else {
            return nil
        }

        self.episodeHash = episodeHash
        self.selectionIdentifier = (dictionary["selectionIdentifier"] as? String) ?? ""
        self.feedIdentifier = feedIdentifier
        self.title = title
        self.podcastTitle = podcastTitle
        if let imageURLString = dictionary["imageURL"] as? String, !imageURLString.isEmpty {
            self.imageURL = URL(string: imageURLString)
        } else {
            self.imageURL = nil
        }
        self.pubDate = pubDate
        self.durationHint = (dictionary["durationHint"] as? NSNumber)?.intValue ?? 0
        self.position = (dictionary["position"] as? NSNumber)?.intValue ?? 0
        self.consumed = (dictionary["consumed"] as? NSNumber)?.boolValue ?? false
        self.mediaURL = mediaURL
        self.selectionSource = selectionSource
        self.watchAddedDate = watchAddedDate
        self.playbackOrder = (dictionary["playbackOrder"] as? NSNumber)?.intValue
        self.skipForwardSeconds = max(1, (dictionary["skipForwardSeconds"] as? NSNumber)?.intValue ?? 30)
        self.skipBackwardSeconds = max(1, (dictionary["skipBackwardSeconds"] as? NSNumber)?.intValue ?? 30)
        self.expectedFileSize = max(0, (dictionary["expectedFileSize"] as? NSNumber)?.int64Value ?? 0)
        self.skipChapterNames = (dictionary["skipChapterNames"] as? [String]) ?? []
        self.autoSkipSponsors = (dictionary["autoSkipSponsors"] as? NSNumber)?.boolValue ?? false
    }
}

extension WatchEpisode {
    init(entry: WatchManifestEntry, existing: WatchEpisode?, existingLocalFileWasValidated: Bool) {
        let canReuseManifestProgress = existing?.mediaURL == entry.mediaURL &&
            existing?.status != .downloaded && existing?.status != .removing
        let canReuseDownload = Self.canReuseDownloadedFile(
            from: existing,
            entry: entry,
            localFileWasValidated: existingLocalFileWasValidated
        )
        let canReuseLocalMetadata = canReuseDownload
        self.episodeHash = entry.episodeHash
        self.selectionIdentifier = entry.selectionIdentifier
        self.feedIdentifier = entry.feedIdentifier
        self.title = entry.title
        self.podcastTitle = entry.podcastTitle
        self.imageURL = entry.imageURL
        self.pubDate = entry.pubDate
        self.durationHint = entry.durationHint
        self.mediaURL = entry.mediaURL
        self.selectionSource = entry.selectionSource
        self.watchAddedDate = entry.watchAddedDate
        self.playbackOrder = entry.playbackOrder
        self.status = canReuseDownload ? .downloaded : (canReuseManifestProgress ? (existing?.status ?? .queued) : .queued)
        self.localFileURL = canReuseDownload ? existing?.localFileURL : nil
        self.actualFileSize = canReuseDownload ? (existing?.actualFileSize ?? 0) : 0
        self.actualDuration = canReuseDownload ? (existing?.actualDuration ?? 0) : 0
        self.lastPlaybackPosition = max(existing?.lastPlaybackPosition ?? 0, entry.position)
        self.lastPlaybackDate = existing?.lastPlaybackDate
        self.consumed = existing?.consumed ?? entry.consumed
        self.lastError = canReuseDownload || canReuseManifestProgress ? existing?.lastError : nil
        self.pendingRemovalRetryRequired = false
        self.downloadedBytes = canReuseDownload ? (existing?.actualFileSize ?? 0) : (canReuseManifestProgress ? (existing?.downloadedBytes ?? 0) : 0)
        self.expectedBytes = canReuseDownload ? (existing?.actualFileSize ?? 0) : max(entry.expectedFileSize, canReuseManifestProgress ? (existing?.expectedBytes ?? 0) : 0)
        self.skipForwardSeconds = entry.skipForwardSeconds
        self.skipBackwardSeconds = entry.skipBackwardSeconds
        self.skipChapterNames = entry.skipChapterNames
        self.autoSkipSponsors = entry.autoSkipSponsors
        self.chapters = canReuseLocalMetadata ? (existing?.chapters ?? []) : []
        self.chapterArtworkBaseURL = canReuseLocalMetadata ? existing?.chapterArtworkBaseURL : nil
    }

    func currentChapter(at position: TimeInterval) -> WatchChapter? {
        chapters.last { chapter in
            chapter.contains(position: position, episodeDuration: displayDuration)
        }
    }

    // Same first-order semantics as PlaybackManager's matchingSkipNameForChapter on the phone:
    // case-insensitive containsString against the feed's skip chapter names. Generated sponsor
    // chapters exist only on the phone; file-embedded sponsor chapters carry a "Sponsor:" title
    // (ChapterGenerator convention), which the sponsor toggle covers here.
    func chapterWillBeSkipped(_ chapter: WatchChapter) -> Bool {
        let lowerTitle = chapter.title.lowercased()
        if autoSkipSponsors, lowerTitle.hasPrefix("sponsor:") {
            return true
        }
        return skipChapterNames.contains { name in
            !name.isEmpty && lowerTitle.contains(name.lowercased())
        }
    }

    private static func canReuseDownloadedFile(
        from existing: WatchEpisode?,
        entry: WatchManifestEntry,
        localFileWasValidated: Bool
    ) -> Bool {
        guard
            localFileWasValidated,
            let existing,
            (existing.status == .downloaded || existing.status == .removing),
            existing.localFileURL != nil,
            existing.mediaURL == entry.mediaURL,
            existing.actualFileSize > 0
        else {
            return false
        }

        return true
    }
}
