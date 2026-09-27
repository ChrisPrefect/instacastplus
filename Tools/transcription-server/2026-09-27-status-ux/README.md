# Status UX regression, 2026-09-27

Observed user failure: an accepted, running server job does not clearly say that it was accepted or that processing is currently taking place on the server. The screen substitutes a polling time and a missing-ETA explanation for useful information. Service failures mention an operator.

Expected flow: saved locally → sending → accepted on server → waiting or named active server phase → retrieving/saving → available. Offline, lost response, paused service, terminal failure and failed import must preserve the known admission state and explain the actual next action. No invented percentages or durations.

Before changing production UI, extend the existing runtime tests against the actual production status controller and helpers. Concrete failure boundaries:

- Acceptance must be explicit after confirmation and must never be claimed before confirmation.
- Active server processing must name the server and animate; waiting, paused, disconnected and terminal states must not claim activity.
- Phase completion must reflect the reported phase; an accepted request is not the same as completed audio/transcription/analysis.
- Status text must preserve an actionable real failure reason while avoiding operator instructions and missing-feature explanations.
- Long German and English text must fit at narrow widths; VoiceOver must expose status/phase text.

Why this isolated check is needed alongside the app E2E: a live server cannot reliably be held at every phase and transport-error boundary, and production jobs cannot safely be created solely to induce outages. The runtime test compiles the real Objective-C status controller verbatim with queue/service boundary fixtures, renders it in UIKit, and retains screenshots and visible text. It is not a transport or full app E2E. The parent task runs the actual app/network/import E2E separately.

Baseline command:
`python3 Tools/server_transcription_status_screen_runtime_test.py --scenario running --output /tmp/server-ux-before-running`

Environment: Xcode iOS 27 simulator, iPhone 18 Pro `675CC86D-C1EA-41D7-A244-0318E0EE1121`, DE locale, 393 pt window. Actual source and Localizable.strings are compiled/copied at invocation time.


## Result

The fresh baseline screenshot is `before-running/screen.png`. The extended test failed with `confirmed=false`, `activity=false` and no measured work. Retained red logs also cover stale activity, unknown download size, paused/queued work with a retained prior phase, and internal result-file terminology.

The production UI now distinguishes admission from processing, shows confirmed work activity, and renders only measured phase progress. Activity expires after 30 seconds without a worker heartbeat; the detail screen updates at that real expiry boundary and when reopened. A queued retry with `phase=transcribing` stays visibly waiting. Service unavailability and an explicitly paused job have distinct next actions: only the former promises automatic resumption. Accepted and unaccepted offline requests retain their different known admission state.

Measured fixture input: transcribing `completed=300`, `total=1200`, `unit=audio_seconds`, estimated phase remainder `360` seconds. The screenshot displays `5:00 of 20:00`, a 25% phase bar and about six minutes for that step. These are controlled fixture values, **not measurements of a production job**. Unknown-length download input is `completed=2048`, `total=null`, `unit=bytes`; it displays downloaded bytes with no proportional bar or ETA.

Validation passed:

- `python3 Tools/server_transcription_presentation_runtime_test.py`
- `python3 Tools/localization_coverage_regression_test.py`
- `python3 Tools/server_transcription_status_screen_runtime_test.py --scenario running --output /tmp/server-ux-running-final`
- Scenario matrix with the same command: `offline`, `sending`, `queued`, `paused`, `retrying`, `recovering`, `stale`, `unknown_total`, `offline_accepted`, `failed`, `import`, `completed`, `canceled`, plus final `admin_paused` and `queued_retry`.
- Narrow English matrix: add `--locale en --width 320` for `running`, `offline`, `paused`, `recovering`, `failed`, `completed`.
- Final captures: `python3 Tools/server_transcription_status_screen_runtime_test.py --scenario <scenario> --locale <locale> --width <width> --output /tmp/server-ux-final-<scenario>-<locale>-<width>` for each retained `final-*` folder.
- `python3 Tools/server_transcription_layout_runtime_test.py --device 675CC86D-C1EA-41D7-A244-0318E0EE1121 --locale de --width 320 --output /tmp/server-ux-layout-de` and the same with `--locale en` / `layout-en`.
- `git diff --check -- Classes/TranscriptionQueueViewController.m Resources/de.lproj/Localizable.strings Resources/en.lproj/Localizable.strings Tools/server_transcription_status_screen_runtime_test.py Tools/server_transcription_presentation_runtime_test.py Tools/server_transcription_layout_runtime_test.py`

Screenshots inspected: baseline; running DE; running EN 320 pt; offline DE; service-paused DE. Labels and actual animation state are checked by the controller test for all scenarios. Dynamic Type is enabled by production controls; a full VoiceOver or large-text audit was not performed. These checks do not claim transport, real provider, flight-mode gesture, background scheduling or server recovery E2E coverage; see the parent task's app/server evidence for those boundaries.
