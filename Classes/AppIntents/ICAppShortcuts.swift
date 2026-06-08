//
//  ICAppShortcuts.swift
//  Instacast
//
//  Zero-setup Siri phrases for the headline actions. Every phrase must contain
//  the `\(.applicationName)` token. The system surfaces up to 10 App Shortcuts;
//  the parameterized ones (Play podcast / Play list / Refresh) are added in the
//  content-intents tier. Bilingual phrases are provided via AppShortcuts.xcstrings.
//

import AppIntents

struct ICAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ICPlayIntent(),
            phrases: [
                "Play in \(.applicationName)",
                "Resume \(.applicationName)",
                "Continue playing in \(.applicationName)"
            ],
            shortTitle: "Play",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: ICPauseIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause playback in \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )

        AppShortcut(
            intent: ICSkipForwardIntent(),
            phrases: [
                "Skip forward in \(.applicationName)",
                "Skip ahead in \(.applicationName)"
            ],
            shortTitle: "Skip Forward",
            systemImageName: "goforward.30"
        )

        AppShortcut(
            intent: ICSkipBackwardIntent(),
            phrases: [
                "Skip back in \(.applicationName)",
                "Go back in \(.applicationName)"
            ],
            shortTitle: "Skip Back",
            systemImageName: "gobackward.15"
        )

        AppShortcut(
            intent: ICNextEpisodeIntent(),
            phrases: [
                "Next episode in \(.applicationName)",
                "Play the next episode in \(.applicationName)"
            ],
            shortTitle: "Next Episode",
            systemImageName: "forward.end.fill"
        )

        AppShortcut(
            intent: ICSetSleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Start the sleep timer in \(.applicationName)"
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz"
        )

        AppShortcut(
            intent: ICMarkPlayedIntent(),
            phrases: [
                "Mark as played in \(.applicationName)",
                "Mark this episode as played in \(.applicationName)"
            ],
            shortTitle: "Mark as Played",
            systemImageName: "checkmark.circle"
        )
    }
}
