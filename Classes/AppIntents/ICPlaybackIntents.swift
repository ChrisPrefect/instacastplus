//
//  ICPlaybackIntents.swift
//  Instacast
//
//  Global playback-control App Intents (Siri / Shortcuts / Spotlight).
//  These run in the app process in the background (`openAppWhenRun = false`);
//  the ones that use the active playback context conform to `AudioPlaybackIntent`
//  so the system executes them as audio playback actions.
//
//  All work is delegated to `ICIntentBridge` (which hops to the main actor).
//

import AppIntents
import Foundation

func ICLocalizedIntentDialog(_ key: String, _ arguments: CVarArg...) -> IntentDialog {
    let format = NSLocalizedString(key, comment: "")
    let text = String(format: format, locale: Locale.current, arguments: arguments)
    return IntentDialog(stringLiteral: text)
}

// MARK: - Transport

struct ICPlayIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Resume playback, or continue the last episode you were listening to.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.play()
        return .result()
    }
}

struct ICPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Pause"
    static let description = IntentDescription("Pause playback.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.pause()
        return .result()
    }
}

struct ICPlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Toggle playback.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.playPause()
        return .result()
    }
}

struct ICSkipForwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Forward"
    static let description = IntentDescription("Skip forward by your configured interval.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.skipForward()
        return .result()
    }
}

struct ICSkipBackwardIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip Back"
    static let description = IntentDescription("Skip backward by your configured interval.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.skipBackward()
        return .result()
    }
}

struct ICNextEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Episode"
    static let description = IntentDescription("Play the next episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.nextEpisode()
        return .result()
    }
}

struct ICPreviousEpisodeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Episode"
    static let description = IntentDescription("Play the previous episode.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.previousEpisode()
        return .result()
    }
}

struct ICNextChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Chapter"
    static let description = IntentDescription("Jump to the next chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.nextChapter()
        return .result()
    }
}

struct ICPreviousChapterIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Chapter"
    static let description = IntentDescription("Jump to the previous chapter.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.previousChapter()
        return .result()
    }
}

// MARK: - Speed

struct ICSetPlaybackSpeedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let description = IntentDescription("Set the playback speed (0.5×–3×).")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Speed", default: 1.0)
    var speed: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set playback speed to \(\.$speed)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ICIntentBridge.setSpeed(speed)
        let value = await ICIntentBridge.currentSpeed()
        let formatted = String(format: "%g", value)
        return .result(dialog: ICLocalizedIntentDialog("Playback speed set to %@×", formatted))
    }
}

struct ICCyclePlaybackSpeedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Cycle Playback Speed"
    static let description = IntentDescription("Cycle through your enabled playback speeds.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.cycleSpeed()
        return .result()
    }
}

// MARK: - Sleep timer

struct ICSetSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Start a sleep timer for the given number of minutes.")
    static var openAppWhenRun: Bool { false }

    @Parameter(title: "Minutes", default: 15)
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set a sleep timer for \(\.$minutes) minutes")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ICIntentBridge.setSleepTimer(minutes: minutes)
        return .result(dialog: ICLocalizedIntentDialog("Sleep timer set for %d minutes.", minutes))
    }
}

struct ICCancelSleepTimerIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Cancel Sleep Timer"
    static let description = IntentDescription("Cancel a running sleep timer.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        await ICIntentBridge.cancelSleepTimer()
        return .result()
    }
}

// MARK: - Episode flags

struct ICMarkPlayedIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Mark Current Episode as Played"
    static let description = IntentDescription("Mark the currently playing episode as played.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = await ICIntentBridge.markCurrentPlayed()
        if let title {
            return .result(dialog: ICLocalizedIntentDialog("Marked “%@” as played.", title))
        }
        return .result(dialog: ICLocalizedIntentDialog("Nothing is playing."))
    }
}

struct ICToggleStarIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Star Current Episode"
    static let description = IntentDescription("Add or remove the currently playing episode from favorites.")
    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let starred = await ICIntentBridge.toggleStarCurrent()
        switch starred {
        case .some(true):  return .result(dialog: ICLocalizedIntentDialog("Added to favorites."))
        case .some(false): return .result(dialog: ICLocalizedIntentDialog("Removed from favorites."))
        case .none:        return .result(dialog: ICLocalizedIntentDialog("Nothing is playing."))
        }
    }
}
