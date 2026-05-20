import Foundation

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
    }

    func applyManifest(entries: [WatchManifestEntry]) -> [WatchEpisode] {
        let existingByHash = Dictionary(uniqueKeysWithValues: episodes.map { ($0.episodeHash, $0) })
        let desiredHashes = Set(entries.map(\.episodeHash))
        let removed = episodes.filter { !desiredHashes.contains($0.episodeHash) }

        episodes = entries.map { entry in
            WatchEpisode(entry: entry, existing: existingByHash[entry.episodeHash])
        }
        persist()
        return removed
    }

    func upsert(entries: [WatchManifestEntry]) {
        var byHash = Dictionary(uniqueKeysWithValues: episodes.map { ($0.episodeHash, $0) })
        for entry in entries {
            byHash[entry.episodeHash] = WatchEpisode(entry: entry, existing: byHash[entry.episodeHash])
        }
        episodes = Array(byHash.values)
        persist()
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
