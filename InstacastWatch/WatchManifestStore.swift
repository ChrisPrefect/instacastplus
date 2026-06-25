import Foundation

private struct WatchManifestNormalizationSummary {
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

@MainActor
final class WatchManifestStore: ObservableObject {
    static let shared = WatchManifestStore()

    @Published private(set) var episodes: [WatchEpisode] = []
    @Published private(set) var accentColorHex = UserDefaults.standard.string(forKey: "InstacastWatchAccentColorHex") ?? "#FF5300"

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    var sortedEpisodes: [WatchEpisode] {
        episodes.sorted { first, second in
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
    }

    func load() {
        guard let data = try? Data(contentsOf: manifestURL) else { return }
        episodes = (try? decoder.decode([WatchEpisode].self, from: data)) ?? []
        normalizeStoredLocalFileURLs(reason: "load")
        WatchDiagnostics.log("manifest-load", message: "Watch-Manifest geladen", metadata: statusCountsMetadata(prefix: "loaded"))
    }

    func applyManifest(entries: [WatchManifestEntry]) -> [WatchEpisode] {
        let normalization = normalizeStoredLocalFileURLs(reason: "manifest.replace-before")
        let beforeCounts = statusCountsMetadata(prefix: "before")
        let existingByHash = Dictionary(uniqueKeysWithValues: episodes.map { ($0.episodeHash, $0) })
        let desiredHashes = Set(entries.map(\.episodeHash))
        let removed = episodes.filter { !desiredHashes.contains($0.episodeHash) }

        episodes = entries.map { entry in
            let existing = existingByHash[entry.episodeHash]
            let item = WatchEpisode(entry: entry, existing: existing)
            logMergeDecision(entry: entry, existing: existing, result: item, reason: "manifest.replace")
            return item
        }
        persist()
        var metadata = beforeCounts
        metadata.merge(statusCountsMetadata(prefix: "after")) { _, new in new }
        metadata.merge(normalization.metadata.mapKeys { "normalization.\($0)" }) { _, new in new }
        metadata["entryCount"] = "\(entries.count)"
        metadata["removedCount"] = "\(removed.count)"
        WatchDiagnostics.log("manifest-replace", message: "Watch-Manifest ersetzt", metadata: metadata)
        return removed
    }

    func upsert(entries: [WatchManifestEntry]) {
        let normalization = normalizeStoredLocalFileURLs(reason: "manifest.upsert-before")
        let beforeCounts = statusCountsMetadata(prefix: "before")
        var byHash = Dictionary(uniqueKeysWithValues: episodes.map { ($0.episodeHash, $0) })
        for entry in entries {
            let existing = byHash[entry.episodeHash]
            let item = WatchEpisode(entry: entry, existing: existing)
            logMergeDecision(entry: entry, existing: existing, result: item, reason: "manifest.upsert")
            byHash[entry.episodeHash] = item
        }
        episodes = Array(byHash.values)
        persist()
        var metadata = beforeCounts
        metadata.merge(statusCountsMetadata(prefix: "after")) { _, new in new }
        metadata.merge(normalization.metadata.mapKeys { "normalization.\($0)" }) { _, new in new }
        metadata["entryCount"] = "\(entries.count)"
        WatchDiagnostics.log("manifest-upsert", message: "Watch-Manifest aktualisiert", metadata: metadata)
    }

    func removeEpisode(hash: String) -> WatchEpisode? {
        guard let index = episodes.firstIndex(where: { $0.episodeHash == hash }) else { return nil }
        let removed = episodes.remove(at: index)
        persist()
        return removed
    }

    func episode(hash: String) -> WatchEpisode? {
        episodes.first { $0.episodeHash == hash }
    }

    func updateEpisode(hash: String, mutate: (inout WatchEpisode) -> Void) {
        guard let index = episodes.firstIndex(where: { $0.episodeHash == hash }) else { return }
        mutate(&episodes[index])
        persist()
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

    func persist() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(episodes) else { return }
        try? data.write(to: manifestURL, options: [.atomic])
    }

    @discardableResult
    private func normalizeStoredLocalFileURLs(reason: String) -> WatchManifestNormalizationSummary {
        var summary = WatchManifestNormalizationSummary()
        var didChange = false

        for index in episodes.indices {
            guard let storedURL = episodes[index].localFileURL else { continue }
            summary.checked += 1
            if let resolvedURL = WatchStorageManager.shared.resolvedLocalFileURL(for: episodes[index]) {
                if resolvedURL != storedURL {
                    var metadata = WatchDiagnostics.metadata(for: episodes[index])
                    metadata["reason"] = reason
                    metadata["storedPathHash"] = WatchDiagnostics.stableHash(storedURL.path)
                    metadata["resolvedPathHash"] = WatchDiagnostics.stableHash(resolvedURL.path)
                    metadata["resolvedFileName"] = resolvedURL.lastPathComponent
                    metadata["pathRerooted"] = "true"
                    WatchDiagnostics.log("watch-local-file-rerooted", message: "Watch-Dateipfad auf aktuellen Container normalisiert", metadata: metadata)
                    episodes[index].localFileURL = resolvedURL
                    summary.rerooted += 1
                    didChange = true
                } else {
                    summary.unchanged += 1
                }
            } else {
                var metadata = WatchDiagnostics.metadata(for: episodes[index])
                metadata["reason"] = reason
                metadata["storedPathHash"] = WatchDiagnostics.stableHash(storedURL.path)
                metadata["localFileMissing"] = "true"
                WatchDiagnostics.log("watch-local-file-missing", message: "Watch-Datei fehlt im alten und aktuellen Container", metadata: metadata)
                clearLocalFileState(for: &episodes[index])
                summary.missing += 1
                didChange = true
            }
        }

        if didChange {
            persist()
        }
        return summary
    }

    private func clearLocalFileState(for episode: inout WatchEpisode) {
        episode.status = .queued
        episode.localFileURL = nil
        episode.actualFileSize = 0
        episode.actualDuration = 0
        episode.downloadedBytes = 0
        episode.expectedBytes = 0
        episode.chapters = []
        episode.chapterArtworkBaseURL = nil
    }

    private func logMergeDecision(entry: WatchManifestEntry, existing: WatchEpisode?, result: WatchEpisode, reason: String) {
        guard let existing else { return }
        let wasDownloaded = existing.status == .downloaded && existing.localFileURL != nil
        let keptDownloaded = wasDownloaded && result.status == .downloaded && result.localFileURL != nil
        let resetDownloaded = wasDownloaded && !keptDownloaded
        let mediaURLChanged = existing.mediaURL != entry.mediaURL
        guard resetDownloaded || mediaURLChanged || existing.localFileURL != result.localFileURL else { return }

        var metadata = WatchDiagnostics.metadata(for: result)
        metadata["reason"] = reason
        metadata["wasDownloaded"] = wasDownloaded ? "true" : "false"
        metadata["keptDownloaded"] = keptDownloaded ? "true" : "false"
        metadata["resetToQueued"] = resetDownloaded ? "true" : "false"
        metadata["mediaURLChanged"] = mediaURLChanged ? "true" : "false"
        metadata["entryExpectedFileSize"] = "\(entry.expectedFileSize)"
        metadata["existingActualFileSize"] = "\(existing.actualFileSize)"
        WatchDiagnostics.log("manifest-merge-episode", message: keptDownloaded ? "Watch-Downloadzustand erhalten" : "Watch-Downloadzustand zurueckgesetzt", metadata: metadata)
    }

    private func statusCountsMetadata(prefix: String) -> [String: String] {
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

    private var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WatchManifest", isDirectory: true)
    }

    private var manifestURL: URL {
        supportDirectory.appendingPathComponent("manifest.json")
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
