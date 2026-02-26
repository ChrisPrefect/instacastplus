import WidgetKit
import SwiftUI

struct FavoritesGridEntry: TimelineEntry, Sendable {
    let date: Date
    let feeds: [WFeed]
}

struct FavoritesGridProvider: TimelineProvider {
    func placeholder(in context: Context) -> FavoritesGridEntry {
        FavoritesGridEntry(date: Date(), feeds: [])
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FavoritesGridEntry) -> Void) {
        let feeds = SharedContainerReader.readFeeds() ?? []
        completion(FavoritesGridEntry(date: Date(), feeds: feeds))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FavoritesGridEntry>) -> Void) {
        let feeds = SharedContainerReader.readFeeds() ?? []
        let entry = FavoritesGridEntry(date: Date(), feeds: feeds)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60)))
        completion(timeline)
    }
}
