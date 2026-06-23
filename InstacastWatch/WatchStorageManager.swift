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

    var chapterArtworkDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("ChapterArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func localFileURL(for episode: WatchEpisode, temporaryURL: URL? = nil) -> URL {
        let ext = temporaryURL?.pathExtension.isEmpty == false ? temporaryURL!.pathExtension : episode.mediaURL.pathExtension
        let fileName = ext.isEmpty ? episode.episodeHash : "\(episode.episodeHash).\(ext)"
        return downloadsDirectory.appendingPathComponent(fileName)
    }

    func resolvedLocalFileURL(for episode: WatchEpisode) -> URL? {
        var fileNames: [String] = []
        if let fileName = episode.localFileURL?.lastPathComponent, !fileName.isEmpty {
            fileNames.append(fileName)
        }
        let computedFileName = localFileURL(for: episode).lastPathComponent
        if !computedFileName.isEmpty, !fileNames.contains(computedFileName) {
            fileNames.append(computedFileName)
        }

        for fileName in fileNames {
            let currentURL = downloadsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: currentURL.path) {
                return currentURL
            }
        }

        if let localFileURL = episode.localFileURL, FileManager.default.fileExists(atPath: localFileURL.path) {
            return localFileURL
        }
        return nil
    }

    func removeLocalFile(for episode: WatchEpisode) {
        if let localFileURL = episode.localFileURL {
            try? FileManager.default.removeItem(at: localFileURL)
        }
        let computedURL = localFileURL(for: episode)
        try? FileManager.default.removeItem(at: computedURL)
        removeChapterArtwork(for: episode)
    }

    func removeChapterArtwork(for episode: WatchEpisode) {
        if let baseURL = episode.chapterArtworkBaseURL {
            for chapter in episode.chapters {
                guard let imageFileName = chapter.imageFileName else { continue }
                try? FileManager.default.removeItem(at: baseURL.appendingPathComponent(imageFileName))
            }
        }

        let safeHash = episode.episodeHash.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        guard let files = try? FileManager.default.contentsOfDirectory(at: chapterArtworkDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("\(safeHash)-chapter-") {
            try? FileManager.default.removeItem(at: file)
        }
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

    func totalBytes() -> Int64 {
        let values = try? downloadsDirectory.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }

    func usedBytes() -> Int64 {
        let total = totalBytes()
        guard total > 0 else { return 0 }
        return max(0, total - freeBytes())
    }

    func cleanupIfNeeded(bytesNeeded: Int64, excluding episodeHash: String?) -> [WatchEpisode] {
        var removed: [WatchEpisode] = []
        let minimumFreeBytes = max(bytesNeeded, 50 * 1024 * 1024)
        if freeBytes() >= minimumFreeBytes {
            return []
        }

        let playingEpisodeHash = WatchPlayerController.shared.playingEpisodeHash
        let candidates = WatchManifestStore.shared.episodes
            .filter { $0.episodeHash != episodeHash && $0.episodeHash != playingEpisodeHash && $0.localFileURL != nil }
            .sorted { first, second in
                switch (first.playbackOrder, second.playbackOrder) {
                case let (.some(firstOrder), .some(secondOrder)) where firstOrder != secondOrder:
                    return firstOrder > secondOrder
                case (.some, .none):
                    return false
                case (.none, .some):
                    return true
                default:
                    return first.sortDate < second.sortDate
                }
            }

        for episode in candidates where freeBytes() < minimumFreeBytes {
            removeLocalFile(for: episode)
            WatchManifestStore.shared.updateEpisode(hash: episode.episodeHash) { item in
                item.status = .queued
                item.localFileURL = nil
                item.actualFileSize = 0
                item.downloadedBytes = 0
                item.expectedBytes = 0
                item.chapters = []
                item.chapterArtworkBaseURL = nil
            }
            removed.append(episode)
        }

        return removed
    }

}
