import WidgetKit
import SwiftUI

struct NowPlayingEntry: TimelineEntry, Sendable {
    let date: Date
    let data: WNowPlaying?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), data: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (NowPlayingEntry) -> Void) {
        let data = SharedContainerReader.readNowPlaying()
        completion(NowPlayingEntry(date: Date(), data: data))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<NowPlayingEntry>) -> Void) {
        let data = SharedContainerReader.readNowPlaying()

        if let data, let episode = data.episode, !data.isPaused {
            // Generate projected entries every 10 seconds for 5 minutes
            // This gives the widget ~10s visual update granularity without timeline reloads
            var entries: [NowPlayingEntry] = []
            let now = Date()
            let projectionCount = 60  // 60 entries × 5s = 5 minutes

            // Parse speed multiplier from speed string (e.g. "1.5x" → 1.5)
            let speedMultiplier: Double
            if let speedStr = data.playbackSpeed?.replacingOccurrences(of: "x", with: ""),
               let parsed = Double(speedStr), parsed > 0 {
                speedMultiplier = parsed
            } else {
                speedMultiplier = 1.0
            }

            for i in 0..<projectionCount {
                let wallOffset = TimeInterval(i * 5)
                let playbackOffset = wallOffset * speedMultiplier
                let projectedPos = min(episode.duration, episode.position + Int32(playbackOffset))
                let projectedEp = episode.withPosition(projectedPos)
                let projectedData = data.withEpisode(projectedEp)
                entries.append(NowPlayingEntry(date: now.addingTimeInterval(wallOffset), data: projectedData))
            }

            let timeline = Timeline(entries: entries, policy: .after(now.addingTimeInterval(5 * 60)))
            completion(timeline)
        } else {
            // Paused or no episode: single entry, refresh in 60 minutes
            let entry = NowPlayingEntry(date: Date(), data: data)
            let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60 * 60)))
            completion(timeline)
        }
    }
}
