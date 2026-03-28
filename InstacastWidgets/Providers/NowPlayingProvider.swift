import WidgetKit
import SwiftUI

struct NowPlayingEntry: TimelineEntry, Sendable {
    let date: Date
    let data: WNowPlaying?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), data: WidgetSampleData.nowPlaying)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (NowPlayingEntry) -> Void) {
        let data = SharedContainerReader.readNowPlaying() ?? WidgetSampleData.nowPlaying
        completion(NowPlayingEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NowPlayingEntry>) -> Void) {
        let data = SharedContainerReader.readNowPlaying()

        // Diagnostics: log every getTimeline call so we can verify the widget is being refreshed
        WidgetDiagnostics.log("getTimeline", details: [
            "episode": data?.episode?.title ?? "nil",
            "isPaused": data?.isPaused ?? true,
            "chapters": data?.chapters?.count ?? 0,
            "family": "\(context.family)"
        ])

        #if DEBUG
        print("[NowPlayingWidget] getTimeline: episode='\(data?.episode?.title ?? "nil")', isPaused=\(data?.isPaused ?? false), chapters=\(data?.chapters?.count ?? 0), timestamp=\(data?.timestamp.description ?? "nil")")
        #endif

        // Single entry per getTimeline call. The app calls reloadTimelines on every
        // relevant state change (play/pause, episode change, chapter change).
        let entry = NowPlayingEntry(date: Date(), data: data)
        let refreshInterval: TimeInterval = (data?.isPaused == false && data?.episode != nil) ? 60 : 2 * 60
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refreshInterval)))
        completion(timeline)
    }
}
