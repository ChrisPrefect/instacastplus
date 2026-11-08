# Server transcript text without local audio — test plan

Observed on 2026-10-03: `_generatedTranscriptMayLoadForEpisodeHash:` requires the playback audio proof. The descriptor admission and cache/UI restore paths reuse it, so a valid server transcript imported without a local audio file cannot be read in the player. The root task has reproduced server-only submission/import through the actual app; this is its downstream player boundary.

Required behavior: current, validated generated transcript text is readable and searchable independently of local audio availability. Generated time jumps, automatic following and chapter auto-skip require the current matching playback-audio identity exactly as before. The user sees a short explanation when timing is unavailable, without a mandatory-download instruction.

Failure matrix before test or production changes:

- Pending/missing audio proof: current transcript text must load; generated timing remains disabled.
- Confirmed audio mismatch: current text remains readable; timing stays disabled.
- Matching audio and current SRT: both text and timing are available.
- Episode switch while cached data parses: old transcript must not be applied to the new episode.
- SRT replacement during parsing or after static-cache capture: stale text descriptor is rejected; old timing proof cannot authorize new text.
- Audio replacement after proof: text remains current, but generated timing is revoked.
- Publisher timed transcripts retain their distinct source contract; untimed text is never seekable.
- Main-controller application sets cues and transcript availability for readable current text without starting the follow timer for unverified audio.
- Pending generated timing displays a readable-text notice; ordinary publisher text and fully verified generated text do not.

Isolation justification: the app E2E covers the no-download request/import path, but reliably pausing a parser callback across an episode switch or replacing the audio/SRT at the exact callback boundary requires controlled fixtures. Extend the existing native Foundation runtime tests by compiling the actual Objective-C descriptor, timing, cue-application and timer methods, with only playback/source/UI side-effect boundaries replaced. Do not copy the predicates or inspect source spelling. Run red before changing production. Keep actual app UI/transport evidence in the parent task.

Commands:

```
python3 Tools/player_transcript_audio_binding_regression_test.py
python3 Tools/player_audio_notice_state_regression_test.py
python3 Tools/playback_autoskip_live_settings_runtime_test.py
python3 Tools/playback_artifact_freshness_runtime_test.py
python3 Tools/transcription_audio_identity_runtime_test.py
```

## Results

Environment: macOS, repository checkout at `/Users/prefect/Developer/instacastplus`, native Foundation runtime compiled with the active Xcode command-line tools (`xcrun clang`). No simulator state or local podcast download is needed for these isolated callback tests.

The first two commands were run before the production edit. `text-before.log` records six failures: pending/unverified/audio-replaced text admission, new-text admission with an old timing proof, actual cue application, and the subsequent stale-callback assertion. All publisher and generated timing assertions passed. `notice-before.log` records the missing pending notice and the old uninformative failed-timing text. Both commands exited 1 for behavioral assertions; compilation succeeded.

After the edit, the exact same tests exited 0. `text-after.log` proves that actual cue application exposes the readable text while leaving the follow timer absent and timing permission false, and that a stale SRT callback cannot overwrite it. `notice-after.log` proves that pending and rejected timing get the reading/verification explanation, while verified generated text and publisher text do not.

Adjacent production-runtime checks also exited 0:

- `autoskip-after.log`: current source proof remains mandatory for generated timing and live auto-skip settings/interval behavior remains intact.
- `freshness-after.log`: changing either analysis or SRT during audio hashing still yields `[false, false]`.
- `identity-after.log`: exact-byte audio identity checks pass.

Log capture command pattern: append `> Tools/transcription-server/2026-10-03-server-source-evidence/player-text/<log-name>.log 2>&1` to the corresponding command above. Localization syntax was additionally checked with `plutil -lint Resources/de.lproj/Localizable.strings Resources/en.lproj/Localizable.strings`; `git diff --check` passed.

Scope of proof: these are isolated native production-method tests, not E2E results. Actual application submission, import, player presentation and visible footer layout are verified by the parent task's app flow in the enclosing evidence directory. The controller uses its existing multiline footer for the timing explanation; no forced audio-download action was added.

## Full-player media failure (additional E2E failure)

The parent task then reproduced a second failure through the full `PlaybackViewController`: imported server SRT, no local media, and HTTP 503 for the player media URL. `app-recovery/transcript-view.json` reports zero cues and unavailable text; the player briefly appears and closes. `/tmp/server-source-player.log` confirms the streaming HTTP 503. The E2E now also asserts that the full player remains presented, preventing a detached retained controller from producing a false green result.

Cause: the failed AVPlayerItem calls the same `close` path as intentional stop. That clears the selected episode and AudioSession and posts the normal end notification, which dismisses PlayerController. Separately, PlayerController's loaded-to-ready transition waits for media readiness and its loading modal remains active on failure.

Before extending an isolated controller test, the relevant failure matrix is:

- Episode content must load when the player appears even if media is still pending.
- A pending playback without readable text keeps its existing loading indication.
- Once local text becomes readable, that media loading overlay must close.
- A failed playback closes the loading overlay and reports the actual error once, without claiming a missing file for HTTP 503.
- Repeated status updates must not continually re-present the same error.
- Media readiness after content loading still initializes video/media-dependent content and updates playback controls.
- The failed media cleanup must preserve selected context and revoke timing; intentional close must still clear context and signal normal end (covered by the parallel PlaybackManager owner).

Isolation justification: the full app E2E reliably reproduces this failure and remains the acceptance test. A focused native test of the actual `_stateMachine` supplements it with deterministic pending → text available → failed → recovered transitions and repeated updates; forcing those exact transitions separately in AVFoundation is nondeterministic. Only UIKit display and media boundaries are substituted. The actual production controller method is compiled, not copied.

`python3 Tools/player_media_failure_state_runtime_test.py` failed six assertions before the controller change (`media-before.log`) and passes all eight afterwards (`media-after.log`). Initial pending media still shows its loading indication. Readable text and failed audio both remove it; the real error is shown once; subsequent media readiness initializes the media-dependent view. Text, notice and auto-skip regression commands above were rerun and pass.

### Explicit playback retry control

The retained failed episode can be retried by the existing `AudioSession.togglePlay` path, but the visible Play button was enabled only for `pman.ready`, and its action called `PlaybackManager.play` directly. Failure matrix before test/code: ready transport remains enabled; failed audio with a retained selected episode enables only Play for a user-initiated retry and forwards that tap to AudioSession's existing reopen path; no episode means no retry; ordinary pending media does not enable Play; back/forward/seek stay media-ready gated. A deterministic native execution of the actual `updateControlsUI` and `togglePlay:` supplements the failed-media E2E because this matrix distinguishes separate instantaneous control states; it does not simulate audio transport or replace the app acceptance flow.

`python3 Tools/player_failed_media_retry_controls_runtime_test.py` reproduced the disabled button and wrong action before editing production (`retry-controls-before.log`). All seven assertions pass after the focused fix (`retry-controls-after.log`). Nearby actual playback action tests also pass:

```
python3 Tools/sleep_timer_playback_resume_regression_test.py
python3 Tools/sleep_timer_controls_regression_test.py
```

Their retained output is `sleep-resume-after.log` and `sleep-controls-after.log`. The existing shared Foundation harness now declares the real `ready`/`failed` properties and the AudioSession retry selector; that boundary aborts if reached because this suite exercises already loaded playback, preserving its existing behavioral assertions. The separate retry test exercises the intended failed-media branch.

### Retained-context lifecycle follow-ups

Read-only cross-review identified two concrete consequences of retaining the selected episode after a media failure. Before new test/code edits, the failure matrix is:

- The manager's `state=Idle` emits paused KVO before `failed=YES`. Controls therefore initially disable Play. The subsequent completed failure notification must refresh Controls once, with the final failed state. Repeated progress/status notifications must not continually refresh them.
- Publisher timed transcripts remain readable during pending/failed audio, but must not authorize timestamp taps or automatic following without ready media. Publisher timing with ready media remains available; generated text still additionally requires exact current audio/SRT proof.

Isolation justification: the app E2E exercises the real failed-player controls but cannot deterministically separate the synchronous paused KVO from the later completed-state notification. The existing native controller test now executes the actual notification method and records the final controls state. The server-generated E2E fixture does not take the publisher-transcript branch; the existing native production timing test checks that specific branch directly. Neither test copies the production predicates. Red logs are retained before the production changes, and the full-player app E2E remains the final integration acceptance flow.

Results: `python3 Tools/player_media_failure_state_runtime_test.py` first failed the final-state transport-refresh assertions (`failure-notification-before.log`); all ten cases pass after adding the targeted controls refresh to the existing new-error transition (`failure-notification-after.log`). Repeated unchanged notifications do not repeat the refresh.

`python3 Tools/player_transcript_audio_binding_regression_test.py` first failed both publisher pending/lost-ready timing cases (`publisher-timing-before.log`); all nineteen cases pass once readiness is required only by the timing predicate (`publisher-timing-after.log`). Current text still loads without ready audio. The adjacent actual Auto-Skip test passes (`autoskip-final.log`) after its existing loaded-player fixture was given the real `ready=YES` state; no assertions were removed or weakened. Retry-controls and notice tests were rerun successfully, and `git diff --check` passes.

## Confirmed phase during service pause

Final app-flow screenshots reproduce a contradictory step list: `app-server-source-recovery-final/transcribing.png` reports 0:30 transcribed; the later `paused.png` marks server audio download as current and transcript creation as not started. `paused.json` confirms that the service pause overwrites `serverPhase` with `paused` and clears `serverWork`, losing the confirmed phase used by the timeline. The actual production cell renderer defaults an admitted unknown phase to stage 1.

Failure matrix before the focused test/code: a service pause after confirmed transcription must keep audio download completed, mark transcript creation paused, leave later work not started, and show no active worker spinner; a fresh pause without any confirmed phase must not invent progress; completion still marks all steps done; restarting the same durable request must retain the last confirmed phase. The Manager/Queue owner covers phase capture, durable persistence and restart behavior.

The existing native UIKit status-controller harness exercises the actual table cell renderer and captures a screenshot plus exact row texts. Isolation is used to test the precise saved-phase presentation without depending on server timing while the full app-flow acceptance run is being prepared; the existing app screenshots already establish the end-to-end symptom. The fixture only supplies the confirmed prior phase and pause state, not copied rendering logic.

Command (iPhone 18 Pro, iOS 27.0 simulator `675CC86D-C1EA-41D7-A244-0318E0EE1121`, separate from the full app E2E device):

```
python3 Tools/server_transcription_status_screen_runtime_test.py --scenario paused_after_transcribing --locale de --output Tools/transcription-server/2026-10-03-server-source-evidence/player-text/pause-timeline-after
```

Before the UI edit the same scenario exited 1; `pause-timeline-before/result.json` and `screen.png` show the false download-current / transcript-not-started state. After the edit it exits 0; `pause-timeline-after` contains the corrected screenshot and exact five-row texts. Repeating with `--locale en --output .../pause-timeline-en` also passes. `--scenario paused --locale de --output .../pause-without-phase` confirms that no completed processing step is invented when no earlier phase is known. All three have `activity=false`. `python3 Tools/server_transcription_presentation_runtime_test.py` and `git diff --check` pass. The Manager/Queue owner supplies and persists `serverLastProcessingPhase`; the parent full app E2E now asserts actual production table rows after service pause as its integration check.
