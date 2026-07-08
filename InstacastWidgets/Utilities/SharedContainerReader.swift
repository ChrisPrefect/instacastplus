import Foundation
import os.log

private let readerLog = Logger(subsystem: "com.iteconomy.instacastplus.widgets", category: "ContainerReader")

/// Reads JSON snapshot data from the App Group shared container.
enum SharedContainerReader {

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID)
    }

    /// Whether a snapshot file exists in the shared container. Used to distinguish "the app has
    /// never exported for this widget yet" (→ prompt to open the app) from "exported but empty".
    static func snapshotExists(_ filename: String) -> Bool {
        guard let container = containerURL else { return false }
        return FileManager.default.fileExists(atPath: container.appendingPathComponent(filename).path)
    }

    // MARK: - Generic JSON reading

    static func read<T: Decodable & Sendable>(_ type: T.Type, from filename: String) -> T? {
        guard let container = containerURL else {
            readerLog.error("containerURL is nil!")
            return nil
        }
        let fileURL = container.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            readerLog.error("file not found: \(filename, privacy: .public)")
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let result = try decoder.decode(T.self, from: data)
            readerLog.info("decoded \(filename, privacy: .public) OK (\(data.count) bytes)")
            return result
        } catch {
            readerLog.error("DECODE FAILED \(filename, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Typed accessors

    static func readNowPlaying() -> WNowPlaying? {
        read(WNowPlaying.self, from: ICWidgetConstants.nowPlayingFile)
    }

    static func readLists() -> [WList]? {
        read([WList].self, from: ICWidgetConstants.listsIndexFile)
    }

    static func readListEpisodes(listId: String) -> WListEpisodes? {
        let filename = ICWidgetConstants.listEpisodesPrefix + listId + ".json"
        return read(WListEpisodes.self, from: filename)
    }

    static func readStats() -> WStats? {
        read(WStats.self, from: ICWidgetConstants.statsFile)
    }

    static func readSettings() -> WSettings? {
        read(WSettings.self, from: ICWidgetConstants.settingsFile)
    }
}
