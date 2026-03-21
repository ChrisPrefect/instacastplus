import Foundation

enum WidgetSampleData {
    static let sampleEpisodes: [WEpisode] = [
        WEpisode(
            id: "sample-episode-1",
            title: "The hidden cost of fast playback",
            feedTitle: "Podcast Notes",
            feedImageURL: nil,
            localImagePath: nil,
            duration: 3_120,
            position: 1_248,
            consumed: false,
            starred: true,
            downloaded: true,
            pubDate: Date().addingTimeInterval(-7_200)
        ),
        WEpisode(
            id: "sample-episode-2",
            title: "Shipping better defaults without extra settings",
            feedTitle: "Build Log",
            feedImageURL: nil,
            localImagePath: nil,
            duration: 2_760,
            position: 0,
            consumed: false,
            starred: false,
            downloaded: false,
            pubDate: Date().addingTimeInterval(-43_200)
        ),
        WEpisode(
            id: "sample-episode-3",
            title: "Why queue semantics matter in audio apps",
            feedTitle: "Runtime",
            feedImageURL: nil,
            localImagePath: nil,
            duration: 1_980,
            position: 420,
            consumed: false,
            starred: false,
            downloaded: true,
            pubDate: Date().addingTimeInterval(-86_400)
        )
    ]

    static let nowPlaying = WNowPlaying(
        episode: sampleEpisodes[0],
        chapterTitle: "Queue correctness",
        chapterIndex: 1,
        chapterCount: 4,
        chapterArtPath: nil,
        chapters: [
            WChapter(title: "Cold open", startTime: 0, duration: 180),
            WChapter(title: "Queue correctness", startTime: 180, duration: 600),
            WChapter(title: "Widget contracts", startTime: 780, duration: 720),
            WChapter(title: "Wrap-up", startTime: 1_500, duration: 540),
        ],
        isPaused: false,
        sleepTimerRemaining: 900,
        sleepTimerStopDate: Date().addingTimeInterval(900),
        skipForwardSeconds: 30,
        skipBackwardSeconds: 15,
        playbackSpeed: "1.5x",
        hasPreviousEpisode: false,
        hasNextEpisode: true,
        timestamp: Date()
    )

    static let smartList = WListEpisodes(
        listId: "sample.list",
        listName: "Episode List",
        episodes: sampleEpisodes,
        timestamp: Date()
    )

    static let stats = WStats(
        listenedTodaySec: 4_560,
        listenedWeekSec: 18_900,
        downloadedCount: 27,
        downloadedSizeBytes: 1_542_000_000,
        subscribedCount: 48,
        unplayedCount: 136,
        newEpisodesTodayCount: 9,
        sleepTimerUsedCount: 14,
        timestamp: Date()
    )
}
