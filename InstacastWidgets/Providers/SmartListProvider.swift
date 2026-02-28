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
    func placeholder(in context: Context) -> SmartListEntry {
        SmartListEntry(date: Date(), listName: "Episodes", listId: "", episodes: [], tapAction: .play, compact: false)
    }

    func snapshot(for configuration: SmartListConfigIntent, in context: Context) async -> SmartListEntry {
        loadEntry(for: configuration)
    }

    func timeline(for configuration: SmartListConfigIntent, in context: Context) async -> Timeline<SmartListEntry> {
        let entry = loadEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func loadEntry(for configuration: SmartListConfigIntent) -> SmartListEntry {
        let tapAction = configuration.tapAction
        let compact = configuration.compact

        if let listEntity = configuration.list {
            if let listData = SharedContainerReader.readListEpisodes(listId: listEntity.id) {
                return SmartListEntry(
                    date: Date(),
                    listName: listData.listName,
                    listId: listData.listId,
                    episodes: listData.episodes,
                    tapAction: tapAction,
                    compact: compact
                )
            }
            return SmartListEntry(date: Date(), listName: listEntity.name, listId: listEntity.id, episodes: [], tapAction: tapAction, compact: compact)
        }

        // No list configured — try to show the first available list
        if let lists = SharedContainerReader.readLists(), let first = lists.first {
            if let listData = SharedContainerReader.readListEpisodes(listId: first.id) {
                return SmartListEntry(
                    date: Date(),
                    listName: listData.listName,
                    listId: listData.listId,
                    episodes: listData.episodes,
                    tapAction: tapAction,
                    compact: compact
                )
            }
        }

        return SmartListEntry(date: Date(), listName: "Episodes", listId: "", episodes: [], tapAction: tapAction, compact: compact)
    }
}
