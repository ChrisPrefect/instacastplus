import WidgetKit
import SwiftUI

struct StatsEntry: TimelineEntry, Sendable {
    let date: Date
    let stats: WStats?
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), stats: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (StatsEntry) -> Void) {
        let stats = SharedContainerReader.readStats()
        completion(StatsEntry(date: Date(), stats: stats))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<StatsEntry>) -> Void) {
        let stats = SharedContainerReader.readStats()
        let entry = StatsEntry(date: Date(), stats: stats)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
        completion(timeline)
    }
}
