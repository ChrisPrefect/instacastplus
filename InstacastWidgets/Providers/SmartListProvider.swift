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
            compact: true
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
                compact: configuration.compact
            )
        }
        return entry
    }

    func timeline(for configuration: SmartListConfigIntent, in context: Context) async -> Timeline<SmartListEntry> {
        let entry = loadEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    private func loadEntry(for configuration: SmartListConfigIntent) -> SmartListEntry {
        let compact = configuration.compact
        widgetLog.info("loadEntry: list=\(configuration.list?.id ?? "nil", privacy: .public), compact=\(compact)")

        if let listEntity = configuration.list {
            if let listData = SharedContainerReader.readListEpisodes(listId: listEntity.id) {
                widgetLog.info("loaded \(listData.episodes.count) episodes for '\(listEntity.name, privacy: .public)'")
                return entry(from: listData, compact: compact)
            }
            widgetLog.error("no data for list '\(listEntity.name, privacy: .public)' id=\(listEntity.id, privacy: .public)")
            return SmartListEntry(date: Date(), listName: listEntity.name, listId: listEntity.id, episodes: [], compact: compact)
        }

        // No list configured — choose the best currently available list.
        if let fallback = fallbackEntry(excluding: nil, compact: compact) {
            widgetLog.info("fallback: '\(fallback.listName, privacy: .public)' \(fallback.episodes.count) episodes")
            return fallback
        }

        widgetLog.warning("no lists at all — empty state")
        return SmartListEntry(date: Date(), listName: "Episodes", listId: "", episodes: [], compact: compact)
    }

    private func entry(from listData: WListEpisodes, compact: Bool) -> SmartListEntry {
        SmartListEntry(
            date: Date(),
            listName: listData.listName,
            listId: listData.listId,
            episodes: listData.episodes,
            compact: compact
        )
    }

    private func fallbackEntry(excluding excludedListID: String?, compact: Bool) -> SmartListEntry? {
        guard let list = preferredFallbackList(excluding: excludedListID),
              let listData = SharedContainerReader.readListEpisodes(listId: list.id) else {
            return nil
        }
        return entry(from: listData, compact: compact)
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
