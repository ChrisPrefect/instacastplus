import WidgetKit
import SwiftUI

struct NowPlayingEntry: TimelineEntry, Sendable {
    let date: Date
    let data: WNowPlaying?
    /// True when the app has never exported a snapshot for this widget yet (freshly added,
    /// app not opened since). The view then prompts the user to open the app.
    var needsData: Bool = false
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
        ICWidgetConstants.recordWidgetKindInstalled(ICWidgetConstants.nowPlayingWidgetKind)
        let data = SharedContainerReader.readNowPlaying()
        let needsData = !SharedContainerReader.snapshotExists(ICWidgetConstants.nowPlayingFile)

        #if DEBUG
        print("[NowPlayingWidget] getTimeline: episode='\(data?.episode?.title ?? "nil")', isPaused=\(data?.isPaused ?? false), chapters=\(data?.chapters?.count ?? 0), timestamp=\(data?.timestamp.description ?? "nil")")
        #endif

        // Single entry per getTimeline call. The app calls reloadAllTimelines() on every
        // relevant state change (play/pause, episode change, chapter change). Pre-projected
        // multi-entry timelines prevent WidgetKit from calling getTimeline again after a
        // reloadAllTimelines() request, because WidgetKit considers its existing entries
        // still "valid" for the current time slot — causing stale play/pause state and
        // stale episode info even after an explicit reload. Single entries force WidgetKit
        // to call getTimeline whenever the current entry is consumed or a reload is requested.
        let entry = NowPlayingEntry(date: Date(), data: data, needsData: needsData)
        let refreshInterval: TimeInterval = (data?.isPaused == false && data?.episode != nil) ? 60 : 2 * 60
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refreshInterval)))
        completion(timeline)
    }
}
