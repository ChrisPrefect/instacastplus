# App Intent playback bridge: retained failure and singleton regression

Scope: `Classes/AppIntents/ICIntentBridge.swift`. No Siri UI or intent declaration changes.

The pre-implementation failure matrix and isolation rationale were recorded in `test-plan.md`, under “Swift App-Intent playback bridge follow-up (before tests)”. The executable imports the real Objective-C factory declarations, compiles their actual method bodies and `AudioSession.togglePlay`, and executes the actual Swift bridge getter and transport method bodies. Media state, Core Data lookup, and terminal playback calls are controlled boundaries. This is a focused runtime contract test, not a full Siri E2E test.

Environment: macOS arm64, Xcode at `/Applications/Xcode.app`, Apple Swift 6.4 (`swiftlang-6.4.0.34.1 clang-2100.3.34.1`), Swift language mode 6. Run from the repository root:

```sh
python3 Tools/app_intent_playback_bridge_runtime_test.py
python3 Tools/playback_media_failure_runtime_test.py
git diff --check -- Classes/AppIntents/ICIntentBridge.swift Tools/app_intent_playback_bridge_runtime_test.py
```

Inputs are embedded in the executable test: a selected episode with healthy, loading, or failed/non-ready media state; no selected/recent episode; explicit Play and Play/Pause calls. A failed playback has already released its player and remains paused with its episode selected.

Before the fix, the test executable exited 1 (`intent-bridge-before.log`):

- Accessing the production Swift getter increased PlaybackManager initializations from 1 to 2. The explicit Swift name `shared()` means `PlaybackManager()` now calls the ordinary initializer.
- Play with retained failed/non-ready playback called direct `play` once and never reopened the episode.
- Play/Pause in the same state called direct `playPause` once and never reopened the episode.
- The other five healthy/loading/empty cases passed.

The bridge now uses `PlaybackManager.shared()` and sends explicit Play/Play-Pause for failed, non-ready retained playback through `AudioSession.togglePlay()`. That existing method reopens the selected episode while preserving its source.

After the fix, all eight cases pass with exit 0 (`intent-bridge-after.log`): singleton initialization remains 1; both failed transport actions reopen exactly once with source preservation and zero direct released-player calls. The focused playback lifecycle neighbor also passes (`intent-bridge-playback-neighbor.log`), and `git diff --check` passes.

No physical-device or Siri invocation is claimed by this test. Root coordinates the final full app build and separate real app playback/transcription validation.
