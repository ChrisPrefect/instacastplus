# Reproduction: imported transcript hidden by media failure

Environment: iOS 27.0 simulator `79C6B540-E8DC-4E2A-8171-25BB70F7E5D1`, Debug app, German locale.

Command:
```
python3 Tools/server_transcription_app_flow_test.py --device 79C6B540-E8DC-4E2A-8171-25BB70F7E5D1 --app build/ServerStatusDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --scenario server_source_recovery --output Tools/transcription-server/2026-10-03-server-source-evidence/app-recovery
```

Inputs: unchanged `Tools/fixtures/server-sponsor-e2e` audio/artifacts; no device cache; one lost POST acknowledgement, process relaunch, temporary service and connection interruption. All server phases and strict import complete before the player opens. The controlled peer returns HTTP 503 for audio only while reading the imported transcript.

Expected: the actual full Player stays open, all 28 cues are readable; no generated timing proof is granted. Observed: zero loaded cues, no available transcript, Player closes and returns to the completed status screen. The App E2E failed its content assertion; see `run.log` and `transcript-view.json`. `player-runtime.log` records the actual AVFoundation HTTP 503 failure.

Manual UI confirmation via Computer Use / Device Hub: choose the dedicated simulator, dismiss its notification permission prompt, then tap the visible “Player öffnen” completion button. The full Player appears briefly and returns to the status screen on the unavailable audio source. This occurred with the production navigation action, independently of the DEBUG driver.

Root cause: AVPlayerItemStatusFailed called normal `close`; that erased the selected episode and AudioSession and emitted the regular playback-end notification. PlayerController then dismissed. Its content loading also waited for audio readiness. Pure PlayerInfo loading alone was insufficient proof; the final test uses the full Player and requires that its view remains attached to a window.
