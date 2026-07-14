import Foundation

enum WatchManifestTransferError: Error {
    case emptyFile
    case invalidJSONLine
    case invalidMessageType
    case invalidRevision
    case revisionMismatch
    case invalidEntries
    case entryCountMismatch
}

private enum WatchManifestTransferLimits {
    static let maximumEntryCount = 10_000
    static let maximumManifestBytes = 16 * 1024 * 1024
    static let maximumLineBytes = 256 * 1024
}

enum WatchManifestTransferInbox {
    private static let filenamePrefix = "manifest-"
    private static let filenameSuffix = ".jsonl"

    static var defaultDirectoryURL: URL {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return supportURL.appendingPathComponent("PendingWatchManifests", isDirectory: true)
    }

    static func stage(
        fileURL: URL,
        revision: Int64,
        directoryURL: URL = defaultDirectoryURL
    ) throws -> URL {
        guard revision > 0 else { throw WatchManifestTransferError.invalidRevision }
        let fileManager = FileManager.default
        let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize, fileSize >= 0,
              fileSize <= WatchManifestTransferLimits.maximumManifestBytes else {
            throw WatchManifestTransferError.invalidEntries
        }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try mutableDirectoryURL.setResourceValues(resourceValues)

        let destinationURL = directoryURL.appendingPathComponent(filename(for: revision), isDirectory: false)
        let temporaryURL = directoryURL.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try fileManager.copyItem(at: fileURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        return destinationURL
    }

    static func pendingFileURLs(directoryURL: URL = defaultDirectoryURL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { revision(fileURL: $0) != nil }
        .sorted { (revision(fileURL: $0) ?? 0) < (revision(fileURL: $1) ?? 0) }
    }

    static func revision(fileURL: URL) -> Int64? {
        let filename = fileURL.lastPathComponent
        guard filename.hasPrefix(filenamePrefix), filename.hasSuffix(filenameSuffix) else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: filenamePrefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -filenameSuffix.count)
        guard start < end, let revision = Int64(filename[start..<end]), revision > 0 else { return nil }
        return revision
    }

    static func remove(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private static func filename(for revision: Int64) -> String {
        "\(filenamePrefix)\(revision)\(filenameSuffix)"
    }
}

struct WatchManifestTransferSnapshot: Sendable {
    let manifestRevision: Int64
    let watchEventProtocolVersion: Int
    let accentColorHex: String?
    let entries: [WatchManifestEntry]

    static func decode(fileURL: URL) throws -> WatchManifestTransferSnapshot {
        let maximumEntryCount = WatchManifestTransferLimits.maximumEntryCount
        let maximumManifestBytes = WatchManifestTransferLimits.maximumManifestBytes
        let maximumLineBytes = WatchManifestTransferLimits.maximumLineBytes
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        var entries: [WatchManifestEntry] = []
        var manifestRevision: Int64?
        var watchEventProtocolVersion = 1
        var accentColorHex: String?
        var expectedEntryCount: Int?
        var lineIndex = 0

        func process(line: Data) throws {
            guard !line.isEmpty,
                  let dictionary = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw WatchManifestTransferError.invalidJSONLine
            }
            if lineIndex == 0 {
                guard dictionary["type"] as? String == "manifest.replace" else {
                    throw WatchManifestTransferError.invalidMessageType
                }
                guard let revision = (dictionary["manifestRevision"] as? NSNumber)?.int64Value,
                      revision > 0 else {
                    throw WatchManifestTransferError.invalidRevision
                }
                guard let count = (dictionary["entryCount"] as? NSNumber)?.intValue,
                      count >= 0, count <= maximumEntryCount else {
                    throw WatchManifestTransferError.invalidEntries
                }
                manifestRevision = revision
                watchEventProtocolVersion = max(1, (dictionary["watchEventProtocolVersion"] as? NSNumber)?.intValue ?? 1)
                accentColorHex = dictionary["accentColorHex"] as? String
                expectedEntryCount = count
                entries.reserveCapacity(count)
            } else {
                guard let expectedEntryCount, entries.count < expectedEntryCount else {
                    throw WatchManifestTransferError.invalidEntries
                }
                guard let entry = WatchManifestEntry(dictionary: dictionary, dateFormatter: dateFormatter) else {
                    throw WatchManifestTransferError.invalidEntries
                }
                entries.append(entry)
            }
            lineIndex += 1
        }

        var pendingData = Data()
        var totalBytesRead = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            totalBytesRead += chunk.count
            guard totalBytesRead <= maximumManifestBytes else {
                throw WatchManifestTransferError.invalidEntries
            }
            pendingData.append(chunk)
            while let newlineIndex = pendingData.firstIndex(of: 0x0A) {
                let lineLength = pendingData.distance(from: pendingData.startIndex, to: newlineIndex)
                guard lineLength <= maximumLineBytes else {
                    throw WatchManifestTransferError.invalidJSONLine
                }
                let line = Data(pendingData[..<newlineIndex])
                pendingData.removeSubrange(...newlineIndex)
                try process(line: line)
            }
            if pendingData.count > maximumLineBytes {
                throw WatchManifestTransferError.invalidJSONLine
            }
        }
        if !pendingData.isEmpty {
            try process(line: pendingData)
        }
        guard lineIndex > 0 else {
            throw WatchManifestTransferError.emptyFile
        }
        guard let revision = manifestRevision,
              let expectedEntryCount,
              entries.count == expectedEntryCount else {
            throw WatchManifestTransferError.entryCountMismatch
        }

        return WatchManifestTransferSnapshot(
            manifestRevision: revision,
            watchEventProtocolVersion: watchEventProtocolVersion,
            accentColorHex: accentColorHex,
            entries: entries
        )
    }
}
