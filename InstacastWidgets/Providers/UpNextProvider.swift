import WidgetKit
import SwiftUI

struct UpNextEntry: TimelineEntry, Sendable {
    let date: Date
    let data: WUpNext?
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date(), data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (UpNextEntry) -> Void) {
        let data = SharedContainerReader.readUpNext()
        completion(UpNextEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<UpNextEntry>) -> Void) {
        let data = SharedContainerReader.readUpNext()
        let entry = UpNextEntry(date: Date(), data: data)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(10 * 60)))
        completion(timeline)
    }
}
