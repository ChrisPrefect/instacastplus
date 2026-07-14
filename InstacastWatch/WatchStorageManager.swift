import Combine
import Foundation

struct WatchStorageRemovalContext: Sendable {
    let downloadsDirectory: URL
    let artworkFilesByEpisodeHash: [String: [URL]]
}

struct WatchStorageEpisodeIdentity: Hashable, Sendable {
    let episodeHash: String
    let selectionIdentifier: String
    let watchAddedDate: Date
    let mediaURL: URL
    let localFileURL: URL?

    init(episode: WatchEpisode) {
        episodeHash = episode.episodeHash
        selectionIdentifier = episode.selectionIdentifier
        watchAddedDate = episode.watchAddedDate
        mediaURL = episode.mediaURL
        localFileURL = episode.localFileURL
    }

    func matches(_ episode: WatchEpisode) -> Bool {
        episodeHash == episode.episodeHash &&
            selectionIdentifier == episode.selectionIdentifier &&
            watchAddedDate == episode.watchAddedDate &&
            mediaURL == episode.mediaURL &&
            localFileURL == episode.localFileURL
    }
}

struct WatchStorageCleanupSnapshot: Sendable {
    let bytesNeeded: Int64
    let activeDownloadHashes: Set<String>
    let excludingEpisodeHash: String
    let playingEpisodeHash: String?
    let episodes: [WatchEpisode]
    let downloadsDirectory: URL
    let chapterArtworkDirectory: URL
    let simulatedFreeBytesURL: URL
}

struct WatchStorageCleanupCandidate: Sendable {
    let episode: WatchEpisode
    let identity: WatchStorageEpisodeIdentity
    let expectedBytes: Int64
}

struct WatchStorageCleanupPlan: Sendable {
    let snapshot: WatchStorageCleanupSnapshot
    let minimumFreeBytes: Int64
    let freeBytesBefore: Int64
    let projectedFreeBytes: Int64
    let selectedCandidates: [WatchStorageCleanupCandidate]
    let hasSufficientCapacity: Bool
    let wasCancelled: Bool
}

struct WatchStorageRemovalIssue: Sendable {
    let event: String
    let message: String
    let episodeHash: String?
    let errorDescription: String
}

struct WatchStorageRemovalPreparation: Sendable {
    let context: WatchStorageRemovalContext
    let issues: [WatchStorageRemovalIssue]
}

struct WatchStorageCleanupExecution: Sendable {
    let plan: WatchStorageCleanupPlan
    let physicallyRemovedHashes: Set<String>
    let issues: [WatchStorageRemovalIssue]

    var completedEverySelectedRemoval: Bool {
        !plan.wasCancelled &&
            plan.hasSufficientCapacity &&
            physicallyRemovedHashes.count == plan.selectedCandidates.count
    }
}

struct WatchStorageFileRemovalResult: Sendable {
    let removedHashes: Set<String>
    let issues: [WatchStorageRemovalIssue]
}

struct WatchStorageStatusMeasurements: Sendable {
    let freeBytes: Int64
    let rawFreeBytes: Int64
    let usedBytes: Int64
    let totalBytes: Int64
    let downloadBytes: Int64
    let episodeCount: Int
    let downloadedCount: Int
    let downloadedBytes: Int64
    let wantedBytes: Int64
}

struct WatchStorageLocalFileInspection: Sendable {
    let resolvedURL: URL?
    let fileExists: Bool
    let fileSize: Int64?
}

private func watchSafeEpisodeHash(_ episodeHash: String) -> String {
    episodeHash.replacingOccurrences(
        of: "[^A-Za-z0-9._-]",
        with: "_",
        options: .regularExpression
    )
}

private func watchStorageByteSum(_ first: Int64, _ second: Int64) -> Int64 {
    let (sum, overflow) = max(first, 0).addingReportingOverflow(max(second, 0))
    return overflow ? Int64.max : sum
}

private func watchStorageRemovalContext(
    downloadsDirectory: URL,
    artworkFiles: [URL],
    episodeHashes: Set<String>
) -> WatchStorageRemovalContext {
    let safeHashes = Set(episodeHashes.map(watchSafeEpisodeHash))
    var artworkFilesByEpisodeHash: [String: [URL]] = [:]
    for fileURL in artworkFiles {
        let filename = fileURL.lastPathComponent
        guard let delimiter = filename.range(of: "-chapter-", options: .backwards) else { continue }
        let episodeHash = String(filename[..<delimiter.lowerBound])
        guard safeHashes.contains(episodeHash) else { continue }
        artworkFilesByEpisodeHash[episodeHash, default: []].append(fileURL)
    }
    return WatchStorageRemovalContext(
        downloadsDirectory: downloadsDirectory,
        artworkFilesByEpisodeHash: artworkFilesByEpisodeHash
    )
}

@MainActor
final class WatchStorageManager: ObservableObject {
    static let shared = WatchStorageManager()

    /// The watch always keeps at least this much free space so watchOS is not starved — it suspends
    /// apps and audio under storage pressure. Shared by the pre-download capacity check and the live
    /// guard that aborts a running download before it eats into the reserve.
    nonisolated static let minimumReserveBytes: Int64 = 50 * 1024 * 1024

    @Published private(set) var latestFreeBytes: Int64?

    private init() {}

    func recordAvailableBytes(_ freeBytes: Int64) {
        latestFreeBytes = max(0, freeBytes)
    }

    func recordMeasurements(_ measurements: WatchStorageStatusMeasurements) {
        recordAvailableBytes(measurements.freeBytes)
    }

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

    nonisolated static func inspectLocalFile(
        for episode: WatchEpisode
    ) async -> WatchStorageLocalFileInspection {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            let downloadsDirectory = documentsDirectory.appendingPathComponent(
                "Episodes",
                isDirectory: true
            )
            var fileNames: [String] = []
            if let fileName = episode.localFileURL?.lastPathComponent, !fileName.isEmpty {
                fileNames.append(fileName)
            }
            let mediaExtension = episode.mediaURL.pathExtension
            let computedFileName = mediaExtension.isEmpty
                ? episode.episodeHash
                : "\(episode.episodeHash).\(mediaExtension)"
            if !computedFileName.isEmpty, !fileNames.contains(computedFileName) {
                fileNames.append(computedFileName)
            }

            for fileName in fileNames {
                let currentURL = downloadsDirectory.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: currentURL.path) {
                    return Self.inspectFileOffMain(at: currentURL)
                }
            }
            if let localFileURL = episode.localFileURL,
               fileManager.fileExists(atPath: localFileURL.path) {
                return Self.inspectFileOffMain(at: localFileURL)
            }
            return WatchStorageLocalFileInspection(
                resolvedURL: nil,
                fileExists: false,
                fileSize: nil
            )
        }.value
    }

    nonisolated static func inspectFile(
        at fileURL: URL
    ) async -> WatchStorageLocalFileInspection {
        await Task.detached(priority: .utility) {
            Self.inspectFileOffMain(at: fileURL)
        }.value
    }

    private nonisolated static func inspectFileOffMain(
        at fileURL: URL
    ) -> WatchStorageLocalFileInspection {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return WatchStorageLocalFileInspection(
                resolvedURL: nil,
                fileExists: false,
                fileSize: nil
            )
        }
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        return WatchStorageLocalFileInspection(
            resolvedURL: fileURL,
            fileExists: true,
            fileSize: size
        )
    }

    nonisolated static func removalContext(
        downloadsDirectory: URL,
        chapterArtworkDirectory: URL,
        episodeHashes: Set<String>
    ) async -> WatchStorageRemovalPreparation {
        await Task.detached(priority: .utility) {
            Self.removalContextOffMain(
                downloadsDirectory: downloadsDirectory,
                chapterArtworkDirectory: chapterArtworkDirectory,
                episodeHashes: episodeHashes
            )
        }.value
    }

    nonisolated static func removeLocalFiles(
        for episodes: [WatchEpisode],
        downloadsDirectory: URL,
        chapterArtworkDirectory: URL
    ) async -> WatchStorageFileRemovalResult {
        await Task.detached(priority: .utility) {
            Self.removeLocalFilesOffMain(
                for: episodes,
                downloadsDirectory: downloadsDirectory,
                chapterArtworkDirectory: chapterArtworkDirectory
            )
        }.value
    }

    nonisolated static func removeLocalFiles(
        for episodes: [WatchEpisode],
        context: WatchStorageRemovalContext
    ) async -> WatchStorageFileRemovalResult {
        await Task.detached(priority: .utility) {
            Self.removeLocalFilesOffMain(for: episodes, context: context)
        }.value
    }

    private nonisolated static func removalContextOffMain(
        downloadsDirectory: URL,
        chapterArtworkDirectory: URL,
        episodeHashes: Set<String>
    ) -> WatchStorageRemovalPreparation {
        do {
            let artworkFiles = try FileManager.default.contentsOfDirectory(
                at: chapterArtworkDirectory,
                includingPropertiesForKeys: nil
            )
            return WatchStorageRemovalPreparation(
                context: watchStorageRemovalContext(
                    downloadsDirectory: downloadsDirectory,
                    artworkFiles: artworkFiles,
                    episodeHashes: episodeHashes
                ),
                issues: []
            )
        } catch {
            return WatchStorageRemovalPreparation(
                context: watchStorageRemovalContext(
                    downloadsDirectory: downloadsDirectory,
                    artworkFiles: [],
                    episodeHashes: episodeHashes
                ),
                issues: [WatchStorageRemovalIssue(
                    event: "storage-artwork-index-failed",
                    message: "Watch-Kapitelbilder konnten nicht für die Bereinigung gelesen werden",
                    episodeHash: nil,
                    errorDescription: error.localizedDescription
                )]
            )
        }
    }

    private nonisolated static func removeLocalFilesOffMain(
        for episodes: [WatchEpisode],
        downloadsDirectory: URL,
        chapterArtworkDirectory: URL
    ) -> WatchStorageFileRemovalResult {
        let preparation = removalContextOffMain(
            downloadsDirectory: downloadsDirectory,
            chapterArtworkDirectory: chapterArtworkDirectory,
            episodeHashes: Set(episodes.map(\.episodeHash))
        )

        let result = removeLocalFilesOffMain(for: episodes, context: preparation.context)
        return WatchStorageFileRemovalResult(
            removedHashes: result.removedHashes,
            issues: preparation.issues + result.issues
        )
    }

    private nonisolated static func removeLocalFilesOffMain(
        for episodes: [WatchEpisode],
        context: WatchStorageRemovalContext
    ) -> WatchStorageFileRemovalResult {
        guard !episodes.isEmpty else {
            return WatchStorageFileRemovalResult(removedHashes: [], issues: [])
        }
        let fileManager = FileManager.default
        var removedHashes: Set<String> = []
        var issues: [WatchStorageRemovalIssue] = []
        for episode in episodes {
            if Task.isCancelled { break }
            var audioRemovalError: Error?
            var audioFileURLs: [URL] = []
            if let localFileURL = episode.localFileURL {
                audioFileURLs.append(localFileURL)
            }
            let fileExtension = episode.mediaURL.pathExtension
            let fileName = fileExtension.isEmpty ? episode.episodeHash : "\(episode.episodeHash).\(fileExtension)"
            let computedURL = context.downloadsDirectory.appendingPathComponent(fileName)
            if !audioFileURLs.contains(where: { $0.standardizedFileURL == computedURL.standardizedFileURL }) {
                audioFileURLs.append(computedURL)
            }
            for fileURL in audioFileURLs where fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    audioRemovalError = audioRemovalError ?? error
                }
            }

            let safeHash = watchSafeEpisodeHash(episode.episodeHash)
            var episodeArtworkURLs = Set(context.artworkFilesByEpisodeHash[safeHash] ?? [])
            if let baseURL = episode.chapterArtworkBaseURL {
                for chapter in episode.chapters {
                    guard let imageFileName = chapter.imageFileName else { continue }
                    episodeArtworkURLs.insert(baseURL.appendingPathComponent(imageFileName))
                }
            }
            var artworkRemovalError: Error?
            for fileURL in episodeArtworkURLs where fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                } catch {
                    artworkRemovalError = artworkRemovalError ?? error
                }
            }

            if let audioRemovalError {
                issues.append(WatchStorageRemovalIssue(
                    event: "storage-audio-remove-failed",
                    message: "Watch-Audiodatei konnte nicht entfernt werden",
                    episodeHash: episode.episodeHash,
                    errorDescription: audioRemovalError.localizedDescription
                ))
            } else {
                removedHashes.insert(episode.episodeHash)
            }
            if let artworkRemovalError {
                issues.append(WatchStorageRemovalIssue(
                    event: "storage-artwork-remove-failed",
                    message: "Watch-Kapitelbilder konnten nicht vollständig entfernt werden",
                    episodeHash: episode.episodeHash,
                    errorDescription: artworkRemovalError.localizedDescription
                ))
            }
        }
        return WatchStorageFileRemovalResult(removedHashes: removedHashes, issues: issues)
    }

    func downloadBytes() -> Int64 {
        Self.downloadBytes(in: downloadsDirectory)
    }

    nonisolated static func measureDownloadBytes(in downloadsDirectory: URL) async -> Int64 {
        await Task.detached(priority: .utility) {
            Self.downloadBytes(in: downloadsDirectory)
        }.value
    }

    nonisolated static func measureAvailableBytes(
        for episodes: [WatchEpisode]
    ) async -> Int64 {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            let downloadsDirectory = documentsDirectory.appendingPathComponent(
                "Episodes",
                isDirectory: true
            )
            try? fileManager.createDirectory(
                at: downloadsDirectory,
                withIntermediateDirectories: true
            )
#if DEBUG
            let measuredDownloadBytes: Int64? = Self.downloadBytes(in: downloadsDirectory)
#else
            let measuredDownloadBytes: Int64? = nil
#endif
            return Self.availableBytes(
                in: downloadsDirectory,
                episodes: episodes,
                measuredDownloadBytes: measuredDownloadBytes
            )
        }.value
    }

    nonisolated static func measureStatus(
        for episodes: [WatchEpisode]
    ) async -> WatchStorageStatusMeasurements {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first!
            let downloadsDirectory = documentsDirectory.appendingPathComponent(
                "Episodes",
                isDirectory: true
            )
            try? fileManager.createDirectory(
                at: downloadsDirectory,
                withIntermediateDirectories: true
            )

            let downloadBytes = Self.downloadBytes(in: downloadsDirectory)
            let rawValues = try? downloadsDirectory.resourceValues(
                forKeys: [.volumeAvailableCapacityKey]
            )
            let rawFreeBytes = Int64(rawValues?.volumeAvailableCapacity ?? 0)
            let totalBytes = max(
                0,
                Self.int64VolumeResourceValue(
                    at: downloadsDirectory,
                    for: .volumeTotalCapacityKey
                )
            )
            let freeBytes = Self.availableBytes(
                in: downloadsDirectory,
                episodes: episodes,
                measuredDownloadBytes: downloadBytes
            )

            var downloadedCount = 0
            var downloadedBytes: Int64 = 0
            var wantedBytes: Int64 = 0
            for episode in episodes {
                if episode.status == .downloaded {
                    downloadedCount += 1
                    downloadedBytes = watchStorageByteSum(
                        downloadedBytes,
                        episode.actualFileSize
                    )
                }
                wantedBytes = watchStorageByteSum(
                    wantedBytes,
                    max(episode.actualFileSize, episode.expectedBytes)
                )
            }
            return WatchStorageStatusMeasurements(
                freeBytes: freeBytes,
                rawFreeBytes: rawFreeBytes,
                usedBytes: totalBytes > 0 ? max(0, totalBytes - freeBytes) : 0,
                totalBytes: totalBytes,
                downloadBytes: downloadBytes,
                episodeCount: episodes.count,
                downloadedCount: downloadedCount,
                downloadedBytes: downloadedBytes,
                wantedBytes: wantedBytes
            )
        }.value
    }

    private nonisolated static func availableBytes(
        in downloadsDirectory: URL,
        episodes: [WatchEpisode],
        measuredDownloadBytes: Int64?
    ) -> Int64 {
#if DEBUG
        let fileManager = FileManager.default
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let simulatedFreeBytesURL = supportDirectory
            .appendingPathComponent("WatchManifest/simulated-free-bytes.txt")
        if let text = try? String(contentsOf: simulatedFreeBytesURL, encoding: .utf8),
           let simulatedBytes = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let inProgressBytes = episodes.reduce(Int64(0)) { total, episode in
                guard episode.status == .downloading else { return total }
                return watchStorageByteSum(total, episode.downloadedBytes)
            }
            let downloadBytes = measuredDownloadBytes ?? Self.downloadBytes(in: downloadsDirectory)
            let consumedBytes = watchStorageByteSum(downloadBytes, inProgressBytes)
            let simulatedAvailableBytes = max(0, simulatedBytes)
            return max(
                0,
                simulatedAvailableBytes - min(simulatedAvailableBytes, consumedBytes)
            )
        }
#endif
        return max(
            0,
            Self.int64VolumeResourceValue(
                at: downloadsDirectory,
                for: .volumeAvailableCapacityKey
            )
        )
    }

    private nonisolated static func downloadBytes(in downloadsDirectory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: downloadsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
            total = watchStorageByteSum(total, Int64(values?.fileSize ?? 0))
        }
        return total
    }

    func freeBytes() -> Int64 {
#if DEBUG
        // Simulator-test seam (DEBUG only): models a small disk. The file
        // "Application Support/WatchManifest/simulated-free-bytes.txt" holds the free space the
        // volume would have with an EMPTY downloads directory — finished downloads and in-flight
        // progress consume it, deletions free it. File absent = real volume capacity. The test
        // harness writes the file into the simulator app container; release builds compile
        // this out. (UserDefaults/launch-args do not reach the sandboxed watch app reliably.)
        let seamURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("WatchManifest/simulated-free-bytes.txt")
        if let text = try? String(contentsOf: seamURL, encoding: .utf8),
           let simulatedBytes = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let inProgressBytes = WatchManifestStore.shared.episodes
                .filter { $0.status == .downloading }
                .reduce(Int64(0)) { $0 + max(0, $1.downloadedBytes) }
            return max(0, simulatedBytes - downloadBytes() - inProgressBytes)
        }
#endif
        // Read the raw NSNumber instead of URLResourceValues.volumeAvailableCapacity. The typed Swift
        // property is Int-sized; on watchOS arm64_32 that truncates multi-GB capacities into negative
        // values (customer log: about -755 MB while Settings showed about 18 GB free). That negative
        // value made every pre-download check report "Speicher voll".
        return max(0, int64VolumeResourceValue(for: .volumeAvailableCapacityKey))
    }

    /// The old typed Swift value. Used ONLY for diagnostics so a field log can show the arm64_32
    /// truncation that used to feed negative free-space values into the storage checks.
    func rawAvailableBytes() -> Int64 {
        let values = try? downloadsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    func totalBytes() -> Int64 {
        return max(0, int64VolumeResourceValue(for: .volumeTotalCapacityKey))
    }

    func usedBytes() -> Int64 {
        let total = totalBytes()
        guard total > 0 else { return 0 }
        return max(0, total - freeBytes())
    }

    nonisolated static func makeCleanupPlan(
        for snapshot: WatchStorageCleanupSnapshot
    ) async -> WatchStorageCleanupPlan {
        await Task.detached(priority: .utility) {
            let reservedDownloadBytes = snapshot.episodes.reduce(Int64(0)) { total, episode in
                guard snapshot.activeDownloadHashes.contains(episode.episodeHash) else { return total }
                let downloadedBytes = max(0, episode.downloadedBytes)
                let remainingBytes = episode.expectedBytes > downloadedBytes
                    ? episode.expectedBytes - downloadedBytes
                    : 0
                return watchStorageByteSum(total, remainingBytes)
            }
            let minimumFreeBytes = watchStorageByteSum(
                watchStorageByteSum(snapshot.bytesNeeded, reservedDownloadBytes),
                minimumReserveBytes
            )
            let freeBytesBefore = cleanupAvailableBytes(snapshot: snapshot)
            guard !Task.isCancelled, freeBytesBefore < minimumFreeBytes else {
                return WatchStorageCleanupPlan(
                    snapshot: snapshot,
                    minimumFreeBytes: minimumFreeBytes,
                    freeBytesBefore: freeBytesBefore,
                    projectedFreeBytes: freeBytesBefore,
                    selectedCandidates: [],
                    hasSufficientCapacity: freeBytesBefore >= minimumFreeBytes,
                    wasCancelled: Task.isCancelled
                )
            }

            let candidates = snapshot.episodes
                .filter {
                    $0.episodeHash != snapshot.excludingEpisodeHash &&
                        $0.episodeHash != snapshot.playingEpisodeHash &&
                        $0.status != .removing &&
                        $0.localFileURL != nil
                }
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

            var projectedFreeBytes = freeBytesBefore
            var selectedCandidates: [WatchStorageCleanupCandidate] = []
            for episode in candidates where projectedFreeBytes < minimumFreeBytes {
                if Task.isCancelled { break }
                let reclaimableBytes = cleanupLocalFileSize(
                    for: episode,
                    downloadsDirectory: snapshot.downloadsDirectory
                )
                guard reclaimableBytes > 0 else { continue }
                projectedFreeBytes = watchStorageByteSum(projectedFreeBytes, reclaimableBytes)
                selectedCandidates.append(WatchStorageCleanupCandidate(
                    episode: episode,
                    identity: WatchStorageEpisodeIdentity(episode: episode),
                    expectedBytes: max(episode.expectedBytes, episode.actualFileSize)
                ))
            }

            return WatchStorageCleanupPlan(
                snapshot: snapshot,
                minimumFreeBytes: minimumFreeBytes,
                freeBytesBefore: freeBytesBefore,
                projectedFreeBytes: projectedFreeBytes,
                selectedCandidates: selectedCandidates,
                hasSufficientCapacity: projectedFreeBytes >= minimumFreeBytes,
                wasCancelled: Task.isCancelled
            )
        }.value
    }

    nonisolated static func executeCleanup(
        _ plan: WatchStorageCleanupPlan
    ) async -> WatchStorageCleanupExecution {
        guard plan.hasSufficientCapacity,
              !plan.wasCancelled,
              !Task.isCancelled,
              !plan.selectedCandidates.isEmpty else {
            return WatchStorageCleanupExecution(
                plan: plan,
                physicallyRemovedHashes: [],
                issues: []
            )
        }

        let result = await removeLocalFiles(
            for: plan.selectedCandidates.map(\.episode),
            downloadsDirectory: plan.snapshot.downloadsDirectory,
            chapterArtworkDirectory: plan.snapshot.chapterArtworkDirectory
        )
        return WatchStorageCleanupExecution(
            plan: plan,
            physicallyRemovedHashes: result.removedHashes,
            issues: result.issues
        )
    }

    private nonisolated static func cleanupAvailableBytes(
        snapshot: WatchStorageCleanupSnapshot
    ) -> Int64 {
#if DEBUG
        if let text = try? String(contentsOf: snapshot.simulatedFreeBytesURL, encoding: .utf8),
           let simulatedBytes = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let inProgressDownloadBytes = snapshot.episodes.reduce(Int64(0)) { total, episode in
                guard episode.status == .downloading else { return total }
                return watchStorageByteSum(total, episode.downloadedBytes)
            }
            let consumedBytes = watchStorageByteSum(
                downloadBytes(in: snapshot.downloadsDirectory),
                inProgressDownloadBytes
            )
            let simulatedAvailableBytes = max(0, simulatedBytes)
            return max(
                0,
                simulatedAvailableBytes - min(simulatedAvailableBytes, consumedBytes)
            )
        }
#endif
        return max(
            0,
            int64VolumeResourceValue(
                at: snapshot.downloadsDirectory,
                for: .volumeAvailableCapacityKey
            )
        )
    }

    private nonisolated static func cleanupLocalFileSize(
        for episode: WatchEpisode,
        downloadsDirectory: URL
    ) -> Int64 {
        guard
            let fileURL = cleanupResolvedLocalFileURL(
                for: episode,
                downloadsDirectory: downloadsDirectory
            ),
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    private nonisolated static func cleanupResolvedLocalFileURL(
        for episode: WatchEpisode,
        downloadsDirectory: URL
    ) -> URL? {
        var fileNames: [String] = []
        if let fileName = episode.localFileURL?.lastPathComponent, !fileName.isEmpty {
            fileNames.append(fileName)
        }
        let fileExtension = episode.mediaURL.pathExtension
        let computedFileName = fileExtension.isEmpty
            ? episode.episodeHash
            : "\(episode.episodeHash).\(fileExtension)"
        if !fileNames.contains(computedFileName) {
            fileNames.append(computedFileName)
        }
        for fileName in fileNames {
            let currentURL = downloadsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: currentURL.path) {
                return currentURL
            }
        }
        if let localFileURL = episode.localFileURL,
           FileManager.default.fileExists(atPath: localFileURL.path) {
            return localFileURL
        }
        return nil
    }

    private func int64VolumeResourceValue(for key: URLResourceKey) -> Int64 {
        Self.int64VolumeResourceValue(at: downloadsDirectory, for: key)
    }

    private nonisolated static func int64VolumeResourceValue(
        at url: URL,
        for key: URLResourceKey
    ) -> Int64 {
        var value: AnyObject?
        do {
            try (url as NSURL).getResourceValue(&value, forKey: key)
        }
        catch {
            return 0
        }
        guard let number = value as? NSNumber else { return 0 }
        return number.int64Value
    }

}
