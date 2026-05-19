import Foundation

enum WatchSelectionSource: String, Codable {
    case manual
    case latestRule
}

enum WatchEpisodeStatus: String, Codable {
    case queued
    case downloading
    case downloaded
    case failed
    case removing
}

struct WatchManifestEntry {
    let episodeHash: String
    let feedIdentifier: String
    let title: String
    let podcastTitle: String
    let pubDate: Date
    let durationHint: Int
    let position: Int
    let consumed: Bool
    let mediaURL: URL
    let selectionSource: WatchSelectionSource
    let watchAddedDate: Date
}

struct WatchEpisode: Codable, Identifiable, Equatable {
    var id: String { episodeHash }

    var episodeHash: String
    var feedIdentifier: String
    var title: String
    var podcastTitle: String
    var pubDate: Date
    var durationHint: Int
    var mediaURL: URL
    var selectionSource: WatchSelectionSource
    var watchAddedDate: Date
    var status: WatchEpisodeStatus
    var localFileURL: URL?
    var actualFileSize: Int64
    var actualDuration: Int
    var lastPlaybackPosition: Int
    var lastPlaybackDate: Date?
    var consumed: Bool
    var lastError: String?
    var downloadedBytes: Int64
    var expectedBytes: Int64

    var sortDate: Date {
        selectionSource == .manual ? watchAddedDate : pubDate
    }

    var displayDuration: Int {
        actualDuration > 0 ? actualDuration : durationHint
    }

    var remainingSeconds: Int {
        max(0, displayDuration - lastPlaybackPosition)
    }

    var progressFraction: Double? {
        guard status == .downloading, expectedBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(expectedBytes)))
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
        self.feedIdentifier = feedIdentifier
        self.title = title
        self.podcastTitle = podcastTitle
        self.pubDate = pubDate
        self.durationHint = (dictionary["durationHint"] as? NSNumber)?.intValue ?? 0
        self.position = (dictionary["position"] as? NSNumber)?.intValue ?? 0
        self.consumed = (dictionary["consumed"] as? NSNumber)?.boolValue ?? false
        self.mediaURL = mediaURL
        self.selectionSource = selectionSource
        self.watchAddedDate = watchAddedDate
    }
}

extension WatchEpisode {
    init(entry: WatchManifestEntry, existing: WatchEpisode?) {
        let canReuseDownload = existing?.mediaURL == entry.mediaURL
        self.episodeHash = entry.episodeHash
        self.feedIdentifier = entry.feedIdentifier
        self.title = entry.title
        self.podcastTitle = entry.podcastTitle
        self.pubDate = entry.pubDate
        self.durationHint = entry.durationHint
        self.mediaURL = entry.mediaURL
        self.selectionSource = entry.selectionSource
        self.watchAddedDate = entry.watchAddedDate
        self.status = canReuseDownload ? (existing?.status ?? .queued) : .queued
        self.localFileURL = canReuseDownload ? existing?.localFileURL : nil
        self.actualFileSize = canReuseDownload ? (existing?.actualFileSize ?? 0) : 0
        self.actualDuration = canReuseDownload ? (existing?.actualDuration ?? 0) : 0
        self.lastPlaybackPosition = max(existing?.lastPlaybackPosition ?? 0, entry.position)
        self.lastPlaybackDate = existing?.lastPlaybackDate
        self.consumed = existing?.consumed ?? entry.consumed
        self.lastError = canReuseDownload ? existing?.lastError : nil
        self.downloadedBytes = canReuseDownload ? (existing?.downloadedBytes ?? 0) : 0
        self.expectedBytes = canReuseDownload ? (existing?.expectedBytes ?? 0) : 0
    }
}
