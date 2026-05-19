import Foundation

@MainActor
final class WatchStorageManager {
    static let shared = WatchStorageManager()

    private init() {}

    var downloadsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = documents.appendingPathComponent("Episodes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func localFileURL(for episode: WatchEpisode, temporaryURL: URL? = nil) -> URL {
        let ext = temporaryURL?.pathExtension.isEmpty == false ? temporaryURL!.pathExtension : episode.mediaURL.pathExtension
        let fileName = ext.isEmpty ? episode.episodeHash : "\(episode.episodeHash).\(ext)"
        return downloadsDirectory.appendingPathComponent(fileName)
    }

    func removeLocalFile(for episode: WatchEpisode) {
        if let localFileURL = episode.localFileURL {
            try? FileManager.default.removeItem(at: localFileURL)
        }
        let computedURL = localFileURL(for: episode)
        try? FileManager.default.removeItem(at: computedURL)
    }

    func downloadBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: downloadsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    func freeBytes() -> Int64 {
        let values = try? downloadsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    func cleanupIfNeeded(bytesNeeded: Int64, excluding episodeHash: String?) -> [WatchEpisode] {
        var removed: [WatchEpisode] = []
        let minimumFreeBytes = max(bytesNeeded, 50 * 1024 * 1024)
        if freeBytes() >= minimumFreeBytes {
            return []
        }

        let candidates = WatchManifestStore.shared.episodes
            .filter { $0.episodeHash != episodeHash && $0.localFileURL != nil }
            .sorted { first, second in
                let firstRank = cleanupRank(first)
                let secondRank = cleanupRank(second)
                if firstRank != secondRank {
                    return firstRank < secondRank
                }
                return first.sortDate < second.sortDate
            }

        for episode in candidates where freeBytes() < minimumFreeBytes {
            removeLocalFile(for: episode)
            WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                item.status = .queued
                item.localFileURL = nil
                item.actualFileSize = 0
                item.downloadedBytes = 0
                item.expectedBytes = 0
            }
            removed.append(episode)
        }

        return removed
    }

    private func cleanupRank(_ episode: WatchEpisode) -> Int {
        if episode.consumed {
            return 0
        }
        if episode.selectionSource == .latestRule {
            return 1
        }
        return 2
    }
}
