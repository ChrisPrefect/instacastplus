import WidgetKit
import SwiftUI
import AppIntents
import os.log

private let widgetLog = Logger(subsystem: "com.iteconomy.instacastplus.widgets", category: "SmartList")

struct SmartListEntry: TimelineEntry, Sendable {
    let date: Date
    let listName: String
    let listId: String
    let episodes: [WEpisode]
    let compact: Bool
    let order: SmartListOrder
    /// True when the app has never exported list data yet (widget freshly added, app not opened).
    var needsData: Bool = false
}

struct SmartListProvider: AppIntentTimelineProvider {
    private static let preferredFallbackListIDs = [
        "default.unplayed",
        "default.started",
        "default.downloaded",
        "default.favorites",
        "default.video"
    ]

    func placeholder(in context: Context) -> SmartListEntry {
        SmartListEntry(
            date: Date(),
            listName: WidgetSampleData.smartList.listName,
            listId: WidgetSampleData.smartList.listId,
            episodes: WidgetSampleData.smartList.episodes,
            compact: true,
            order: .columns
        )
    }

    func snapshot(for configuration: SmartListConfigIntent, in context: Context) async -> SmartListEntry {
        let entry = loadEntry(for: configuration)
        if entry.listId.isEmpty && entry.episodes.isEmpty {
            return SmartListEntry(
                date: Date(),
                listName: WidgetSampleData.smartList.listName,
                listId: WidgetSampleData.smartList.listId,
                episodes: WidgetSampleData.smartList.episodes,
                compact: configuration.compact,
                order: configuration.order
            )
        }
        return entry
    }

    /// Snapshot file key for a configured source. Lists use their uid directly; a podcast
    /// (entity id "feed:<uid>") is combined with the chosen filter, matching the file the app
    /// exports on demand for configured podcast widgets.
    static func snapshotKey(entityId: String, filter: SmartListPodcastFilter) -> String {
        if entityId.hasPrefix("feed:") {
            let uid = String(entityId.dropFirst("feed:".count))
            return "feed.\(uid).\(filter.rawValue)"
        }
        return entityId
    }

    func timeline(for configuration: SmartListConfigIntent, in context: Context) async -> Timeline<SmartListEntry> {
        var entry = loadEntry(for: configuration)
        // Prompt to open the app when the data the selection needs has never been exported:
        // either the app never ran at all (no index), or this specific podcast+filter snapshot
        // hasn't been produced yet (freshly configured — the app exports it on next launch).
        if !SharedContainerReader.snapshotExists(ICWidgetConstants.listsIndexFile) {
            entry.needsData = true
        } else if let listEntity = configuration.list {
            let key = Self.snapshotKey(entityId: listEntity.id, filter: configuration.filter)
            if !SharedContainerReader.snapshotExists(ICWidgetConstants.listEpisodesPrefix + key + ".json") {
                entry.needsData = true
            }
        }
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    private func loadEntry(for configuration: SmartListConfigIntent) -> SmartListEntry {
        let compact = configuration.compact
        let order = configuration.order
        widgetLog.info("loadEntry: list=\(configuration.list?.id ?? "nil", privacy: .public), compact=\(compact)")

        if let listEntity = configuration.list {
            // Record a selected podcast+filter so the app exports episode data for exactly this
            // combo on its next run (the app can't read this widget-extension intent directly).
            if listEntity.id.hasPrefix("feed:") {
                recordRequestedPodcast(uid: String(listEntity.id.dropFirst("feed:".count)),
                                       filter: configuration.filter.rawValue)
            }
            let key = Self.snapshotKey(entityId: listEntity.id, filter: configuration.filter)
            if let listData = SharedContainerReader.readListEpisodes(listId: key) {
                widgetLog.info("loaded \(listData.episodes.count) episodes for '\(listEntity.name, privacy: .public)'")
                return entry(from: listData, compact: compact, order: order)
            }
            widgetLog.error("no data for list '\(listEntity.name, privacy: .public)' id=\(listEntity.id, privacy: .public)")
            return SmartListEntry(date: Date(), listName: listEntity.name, listId: listEntity.id, episodes: [], compact: compact, order: order)
        }

        // No list configured — choose the best currently available list.
        if let fallback = fallbackEntry(excluding: nil, compact: compact, order: order) {
            widgetLog.info("fallback: '\(fallback.listName, privacy: .public)' \(fallback.episodes.count) episodes")
            return fallback
        }

        widgetLog.warning("no lists at all — empty state")
        return SmartListEntry(date: Date(), listName: "Episodes", listId: "", episodes: [], compact: compact, order: order)
    }

    /// Records a configured podcast+filter combo in the App Group defaults so the app exports
    /// its episodes on the next run. Keeps a bounded, de-duplicated set.
    private func recordRequestedPodcast(uid: String, filter: String) {
        guard !uid.isEmpty,
              let defaults = UserDefaults(suiteName: ICWidgetConstants.appGroupID) else { return }
        let combo = ["uid": uid, "filter": filter]
        var existing = (defaults.array(forKey: ICWidgetConstants.requestedPodcastKeysDefaultsKey) as? [[String: String]]) ?? []
        if existing.contains(combo) { return }
        existing.append(combo)
        if existing.count > 24 { existing.removeFirst(existing.count - 24) }
        defaults.set(existing, forKey: ICWidgetConstants.requestedPodcastKeysDefaultsKey)
    }

    private func entry(from listData: WListEpisodes, compact: Bool, order: SmartListOrder) -> SmartListEntry {
        SmartListEntry(
            date: Date(),
            listName: listData.listName,
            listId: listData.listId,
            episodes: listData.episodes,
            compact: compact,
            order: order
        )
    }

    private func fallbackEntry(excluding excludedListID: String?, compact: Bool, order: SmartListOrder) -> SmartListEntry? {
        guard let list = preferredFallbackList(excluding: excludedListID),
              let listData = SharedContainerReader.readListEpisodes(listId: list.id) else {
            return nil
        }
        return entry(from: listData, compact: compact, order: order)
    }

    /// Finds the best fallback list by actually loading episode data files,
    /// because episodeCount in the index can transiently be 0 (CDEpisodeList cache invalidation).
    private func preferredFallbackList(excluding excludedListID: String?) -> WList? {
        guard let lists = SharedContainerReader.readLists(), !lists.isEmpty else { return nil }

        let availableLists = lists.filter { $0.id != excludedListID }
        guard !availableLists.isEmpty else { return nil }

        // Preferred lists: check if their episode files actually have data
        for preferredID in Self.preferredFallbackListIDs {
            if let list = availableLists.first(where: { $0.id == preferredID }),
               let data = SharedContainerReader.readListEpisodes(listId: list.id),
               !data.episodes.isEmpty {
                return list
            }
        }

        // Any list with actual episode data
        for list in availableLists {
            if let data = SharedContainerReader.readListEpisodes(listId: list.id),
               !data.episodes.isEmpty {
                return list
            }
        }

        // Last resort: first preferred list (even if empty)
        for preferredID in Self.preferredFallbackListIDs {
            if let list = availableLists.first(where: { $0.id == preferredID }) {
                return list
            }
        }

        return availableLists.first
    }
}
