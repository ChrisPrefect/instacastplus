import Foundation
import AppIntents

// MARK: - Now Playing widget buttons
//
// Compiled into BOTH the app and the widget extension. As AudioPlaybackIntents that exist in
// the app, the system performs them in the app process and launches the app in the background
// when it is not running (Apple's mechanism for audio controls in interactive widgets). The
// previous widget-only intents only queued a file plus a Darwin notification: with the app
// suspended or terminated a tap did nothing, and the queued tap fired later when the app was
// opened (playback started on its own).
//
// `WidgetControlActionPerformer` is defined once per target: the app calls WidgetDataExporter
// directly (WidgetKitHelper.swift), the widget extension keeps the queue fallback
// (InstacastWidgets/Intents/WidgetControlIntents.swift).
//
// Button actions are internal; Shortcuts exposes the app playback intents (ICPlaybackIntents).

struct PlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play/Pause"
    static let description = IntentDescription("Toggle playback.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("playpause")
        return .result()
    }
}

struct SkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("skipforward")
        return .result()
    }
}

struct SkipBackwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Backward"
    static let description = IntentDescription("Skip backward.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("skipbackward")
        return .result()
    }
}

struct NextChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Go to next chapter.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("nextchapter")
        return .result()
    }
}

struct PrevChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription("Go to previous chapter.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("prevchapter")
        return .result()
    }
}

struct NextEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Episode"
    static let description = IntentDescription("Play next episode.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("nextepisode")
        return .result()
    }
}

struct PrevEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Episode"
    static let description = IntentDescription("Play previous episode.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("previousepisode")
        return .result()
    }
}

struct CycleSpeedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Cycle Speed"
    static let description = IntentDescription("Cycle through playback speeds.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("cyclespeed")
        return .result()
    }
}

struct ToggleSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Toggle Sleep Timer"
    static let description = IntentDescription("Start or cancel sleep timer.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("togglesleeptimer")
        return .result()
    }
}

struct SkipToChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip to Chapter"
    static let description = IntentDescription("Jump directly to a specific chapter.")
    static var openAppWhenRun: Bool { false }
    static var isDiscoverable: Bool { false }

    @Parameter(title: "Chapter Index")
    var chapterIndex: Int

    @Parameter(title: "Chapter Timeline")
    var chapterTimelineIdentifier: String?

    // The row's episode and start time select the chapter when its timeline is no longer the
    // loaded one, e.g. after the app was terminated (a new load gets a new timeline identifier).
    @Parameter(title: "Episode")
    var episodeID: String?

    @Parameter(title: "Chapter Start")
    var chapterStartTime: Double?

    init() {}

    init(chapterIndex: Int, chapterTimelineIdentifier: String, episodeID: String, chapterStartTime: Double) {
        self.chapterIndex = chapterIndex
        self.chapterTimelineIdentifier = chapterTimelineIdentifier
        self.episodeID = episodeID
        self.chapterStartTime = chapterStartTime
    }

    func perform() async throws -> some IntentResult {
        try await WidgetControlActionPerformer.perform("skipchapter", chapterIndex: chapterIndex,
                                                       chapterTimelineIdentifier: chapterTimelineIdentifier,
                                                       episodeID: episodeID, chapterStartTime: chapterStartTime)
        return .result()
    }
}
