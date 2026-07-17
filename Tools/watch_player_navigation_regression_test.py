#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WATCH_EPISODE_VIEWS = ROOT / "InstacastWatch" / "WatchEpisodeViews.swift"


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    source = WATCH_EPISODE_VIEWS.read_text(encoding="utf-8")

    assert_true(
        "@State private var handledActiveScenePlayback = false" in source,
        "Player auto-navigation must be gated to one presentation per active scene session.",
    )
    assert_true(
        "handleActiveScenePlaybackIfNeeded()" in source,
        "List appearance and scene activation must share the gated player presentation path.",
    )
    assert_true(
        "guard scenePhase == .active, !handledActiveScenePlayback else { return }" in source
        and "handledActiveScenePlayback = true\n        showPlayerForActivePlaybackIfNeeded()" in source,
        "Player auto-navigation must mark the current active scene session as handled before pushing.",
    )
    assert_true(
        "} else {\n                    handledActiveScenePlayback = false\n                }" in source,
        "Leaving the active scene must reset the player presentation gate for the next activation.",
    )
    assert_true(
        "showPlayerForActivePlaybackIfNeeded()\n            }\n            // Re-entering" not in source,
        "Returning from the player must not auto-push it again from the list's onAppear callback.",
    )


if __name__ == "__main__":
    main()
