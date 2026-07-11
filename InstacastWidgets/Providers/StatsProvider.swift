import WidgetKit
import SwiftUI

struct StatsEntry: TimelineEntry, Sendable {
    let date: Date
    let stats: WStats?
    /// True when the app has never exported stats yet (widget freshly added, app not opened).
    var needsData: Bool = false
}

struct StatsProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatsEntry {
        StatsEntry(date: Date(), stats: WidgetSampleData.stats)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (StatsEntry) -> Void) {
        let stats = SharedContainerReader.readStats() ?? WidgetSampleData.stats
        completion(StatsEntry(date: Date(), stats: stats))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<StatsEntry>) -> Void) {
        ICWidgetConstants.recordWidgetKindInstalled(ICWidgetConstants.statsWidgetKind)
        let stats = SharedContainerReader.readStats()
        let needsData = !SharedContainerReader.snapshotExists(ICWidgetConstants.statsFile)
        let entry = StatsEntry(date: Date(), stats: stats, needsData: needsData)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
        completion(timeline)
    }
}
