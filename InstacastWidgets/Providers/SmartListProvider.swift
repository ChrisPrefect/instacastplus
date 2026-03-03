import WidgetKit
import SwiftUI
import AppIntents

struct SmartListEntry: TimelineEntry, Sendable {
    let date: Date
    let listName: String
    let listId: String
    let episodes: [WEpisode]
    let tapAction: EpisodeTapAction
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
        SmartListEntry(date: Date(), listName: "Episodes", listId: "", episodes: [], tapAction: .play, compact: false)
    }

    func snapshot(for configuration: SmartListConfigIntent, in context: Context) async -> SmartListEntry {
        loadEntry(for: configuration)
    }

    func timeline(for configuration: SmartListConfigIntent, in context: Context) async -> Timeline<SmartListEntry> {
        let entry = loadEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    private func loadEntry(for configuration: SmartListConfigIntent) -> SmartListEntry {
        let tapAction = configuration.tapAction
        let compact = configuration.compact

        if let listEntity = configuration.list {
            if let listData = SharedContainerReader.readListEpisodes(listId: listEntity.id) {
                return entry(from: listData, tapAction: tapAction, compact: compact)
            }
            if let fallback = fallbackEntry(excluding: listEntity.id, tapAction: tapAction, compact: compact) {
                return fallback
            }
            return SmartListEntry(date: Date(), listName: listEntity.name, listId: listEntity.id, episodes: [], tapAction: tapAction, compact: compact)
        }

        // No list configured — choose the best currently available list.
        if let fallback = fallbackEntry(excluding: nil, tapAction: tapAction, compact: compact) {
            return fallback
        }

        return SmartListEntry(date: Date(), listName: "Episodes", listId: "", episodes: [], tapAction: tapAction, compact: compact)
    }

    private func entry(from listData: WListEpisodes, tapAction: EpisodeTapAction, compact: Bool) -> SmartListEntry {
        SmartListEntry(
            date: Date(),
            listName: listData.listName,
            listId: listData.listId,
            episodes: listData.episodes,
            tapAction: tapAction,
            compact: compact
        )
    }

    private func fallbackEntry(excluding excludedListID: String?, tapAction: EpisodeTapAction, compact: Bool) -> SmartListEntry? {
        guard let list = preferredFallbackList(excluding: excludedListID),
              let listData = SharedContainerReader.readListEpisodes(listId: list.id) else {
            return nil
        }
        return entry(from: listData, tapAction: tapAction, compact: compact)
    }

    private func preferredFallbackList(excluding excludedListID: String?) -> WList? {
        guard let lists = SharedContainerReader.readLists(), !lists.isEmpty else { return nil }

        let availableLists = lists.filter { $0.id != excludedListID }
        guard !availableLists.isEmpty else { return nil }

        for preferredID in Self.preferredFallbackListIDs {
            if let list = availableLists.first(where: { $0.id == preferredID && $0.episodeCount > 0 }) {
                return list
            }
        }

        if let firstNonEmpty = availableLists.first(where: { $0.episodeCount > 0 }) {
            return firstNonEmpty
        }

        for preferredID in Self.preferredFallbackListIDs {
            if let list = availableLists.first(where: { $0.id == preferredID }) {
                return list
            }
        }

        return availableLists.first
    }
}
