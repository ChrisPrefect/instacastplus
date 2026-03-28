import Foundation

/// Reads JSON snapshot data from the App Group shared container.
enum SharedContainerReader {

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ICWidgetConstants.appGroupID)
    }

    /// Flexible ISO 8601 date decoder that handles both "+00:00" (standard) and "+0000" (legacy) formats.
    private static let flexibleISO8601: JSONDecoder.DateDecodingStrategy = {
        // Use nonisolated(unsafe) to silence Sendable warnings — formatters are only created once
        // and never mutated after initialization.
        nonisolated(unsafe) let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        let legacyFormatter = DateFormatter()
        legacyFormatter.locale = Locale(identifier: "en_US_POSIX")
        legacyFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxx" // xx → "+0000" without colon
        legacyFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        return .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = isoFormatter.date(from: string) { return date }
            if let date = legacyFormatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot parse date: \(string)")
        }
    }()

    // MARK: - Generic JSON reading

    static func read<T: Decodable & Sendable>(_ type: T.Type, from filename: String) -> T? {
        guard let container = containerURL else {
            print("[Widget] SharedContainerReader: containerURL is nil for appGroupID=\(ICWidgetConstants.appGroupID)")
            return nil
        }
        let fileURL = container.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: fileURL) else {
            print("[Widget] SharedContainerReader: file not found or unreadable: \(fileURL.path)")
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = flexibleISO8601
        do {
            let result = try decoder.decode(T.self, from: data)
            print("[Widget] SharedContainerReader: decoded \(filename) OK (\(data.count) bytes)")
            return result
        } catch {
            print("[Widget] SharedContainerReader: DECODE FAILED \(filename): \(error)")
            // Log raw JSON for diagnosis
            if let raw = String(data: data, encoding: .utf8) {
                print("[Widget] SharedContainerReader: raw JSON (\(filename)): \(raw.prefix(500))")
            }
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
