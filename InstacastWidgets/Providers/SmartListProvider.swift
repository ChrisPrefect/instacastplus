import WidgetKit
import SwiftUI
import AppIntents

struct SmartListEntry: TimelineEntry, Sendable {
    let date: Date
    let listName: String
    let listId: String
    let episodes: [WEpisode]
    let compact: Bool
    let needsConfiguration: Bool  // true when no list has been selected yet
}

struct SmartListProvider: AppIntentTimelineProvider {

    func placeholder(in context: Context) -> SmartListEntry {
        SmartListEntry(
            date: Date(),
            listName: WidgetSampleData.smartList.listName,
            listId: WidgetSampleData.smartList.listId,
            episodes: WidgetSampleData.smartList.episodes,
            compact: true,
            needsConfiguration: false
        )
    }

    func snapshot(for configuration: SmartListConfigIntent, in context: Context) async -> SmartListEntry {
        if context.isPreview {
            return SmartListEntry(
                date: Date(),
                listName: WidgetSampleData.smartList.listName,
                listId: WidgetSampleData.smartList.listId,
                episodes: WidgetSampleData.smartList.episodes,
                compact: configuration.compact,
                needsConfiguration: false
            )
        }
        return loadEntry(for: configuration)
    }

    func timeline(for configuration: SmartListConfigIntent, in context: Context) async -> Timeline<SmartListEntry> {
        let entry = loadEntry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(10 * 60)))
    }

    private func loadEntry(for configuration: SmartListConfigIntent) -> SmartListEntry {
        let compact = configuration.compact
        print("[Widget] SmartListProvider.loadEntry: list=\(configuration.list?.id ?? "nil"), compact=\(compact)")

        // No list selected → show configuration prompt
        guard let listEntity = configuration.list else {
            print("[Widget] SmartListProvider: no list configured, showing configuration prompt")
            return SmartListEntry(date: Date(), listName: "", listId: "", episodes: [], compact: compact, needsConfiguration: true)
        }

        if let listData = SharedContainerReader.readListEpisodes(listId: listEntity.id) {
            print("[Widget] SmartListProvider: loaded \(listData.episodes.count) episodes for list '\(listEntity.name)'")
            return entry(from: listData, compact: compact)
        }

        print("[Widget] SmartListProvider: no episode data for list '\(listEntity.name)' (id=\(listEntity.id))")
        return SmartListEntry(date: Date(), listName: listEntity.name, listId: listEntity.id, episodes: [], compact: compact, needsConfiguration: false)
    }

    private func entry(from listData: WListEpisodes, compact: Bool) -> SmartListEntry {
        SmartListEntry(
            date: Date(),
            listName: listData.listName,
            listId: listData.listId,
            episodes: listData.episodes,
            compact: compact,
            needsConfiguration: false
        )
    }

}
