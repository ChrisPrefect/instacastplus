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

        if let data, let episode = data.episode, !data.isPaused {
            // Generate projected entries every second for 3 minutes.
            // This keeps progress updates smooth while still avoiding excessive timeline work.
            var entries: [NowPlayingEntry] = []
            let now = Date()
            let projectionInterval: TimeInterval = 1
            let projectionCount = 180  // 180 entries × 1s = 3 minutes

            // Parse speed multiplier from speed string (e.g. "1.5x" → 1.5)
            let speedMultiplier: Double
            if let speedStr = data.playbackSpeed?.replacingOccurrences(of: "x", with: ""),
               let parsed = Double(speedStr), parsed > 0 {
                speedMultiplier = parsed
            } else {
                speedMultiplier = 1.0
            }

            for i in 0..<projectionCount {
                let wallOffset = TimeInterval(i) * projectionInterval
                let playbackOffset = wallOffset * speedMultiplier
                let projectedPos = min(episode.duration, episode.position + Int32(playbackOffset))
                let projectedEp = episode.withPosition(projectedPos)
                let projectedData = data.withEpisode(projectedEp)
                entries.append(NowPlayingEntry(date: now.addingTimeInterval(wallOffset), data: projectedData))
            }

            let timeline = Timeline(entries: entries, policy: .after(now.addingTimeInterval(projectionInterval * TimeInterval(projectionCount))))
            completion(timeline)
        } else {
            // Paused or no episode: single entry, refresh in 2 minutes so
            // multiple widget instances stay in sync even without explicit reloads.
            let entry = NowPlayingEntry(date: Date(), data: data)
            let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(2 * 60)))
            completion(timeline)
        }
    }
}
