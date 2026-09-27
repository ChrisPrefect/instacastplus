# Server transcription: observable handoff and work

## Report and expected behavior

The iOS status page did not explicitly confirm server acceptance or show server
activity. A coarse preparation step mixed audio verification, persistence, HTTP
and a server-side feed fetch. It displayed operator instructions and missing ETA
implementation as user-facing status. Expected: immediate local acknowledgement,
durable identity, explicit remote acceptance, measured current work, a clear next
step and recoverable interruptions without duplicate processing.

## Failure boundaries, written before changes

- A slow or unavailable publisher feed must not delay admission of an episode
  whose URL, title and audio identity are already provided by the app.
- Successful admission must remain visible across polls, server pauses,
  connection loss and app restart. A lost POST response must reuse its UUID.
- Only a live worker claim may report active work; an API response timestamp
  alone is not proof of worker activity. Old measurements must not cross phases
  or claims. Canceled, paused and failed jobs must not keep an active indicator.
- Progress must use observed bytes/audio time, with its denominator and phase.
  Unknown totals must not become fabricated percentages. Any time estimate is
  limited to the measured phase, never presented as overall completion time.
- New and reused results must preserve audio identity and strict artifact checks.
  A failed artifact download must retry retrieval without repeating inference.
- Queue rows and the detail page must agree, with explicit admission, activity,
  concise DE/EN messages and usable narrow/Dynamic Type layouts.

## Why targeted boundary tests are also needed

The complete simulator/HTTP/import flow exercises the actual app. Deliberately
blocking a publisher feed, expiring worker claims, disk failures and adversarial
concurrent claims must be induced against isolated databases and HTTP boundaries;
doing this in the production queue would interrupt real work. Backend boundary
tests use production routes, transactions and worker functions, not copied state
machines. Native presentation tests exercise the production controller for a
repeatable matrix of states, in addition to actual-app evidence.

Production source was freshly retrieved before analysis into the ignored
`.codex/private/server-status-20260927` directory; the original is retained in
`.codex/private/server-status-20260927-original`. No production jobs are test data.

## Changes and proof

- Direct episode admission no longer fetches the publisher feed. The blocking
  feed test failed before the change and passed afterward in 60–67 ms on the
  isolated server API/SQLite path. It retains the episode title, podcast link,
  durable receipt and exactly one job on replay. This does not measure cellular
  transport or promise a 100 ms end-to-end response.
- `episode.work` publishes a claim-fenced worker heartbeat, actual queue position,
  byte counts and completed ASR chunk audio duration. The optional ETA describes
  this phase only. Old claims, phases and stale measurements cannot manufacture
  activity or estimates. `jobs.work_json` is an additive nullable TEXT column.
- A confirmed running worker is no longer hidden by an unrelated provider check.
  Healthy polls use 5 seconds with budgets covering all 25 client jobs (450 reads
  per client/minute, 4500 per IP/minute). Service outages retain longer backoff.
- A MariaDB-only 1213 deadlock in simultaneous first status requests was
  reproduced. Expired counter cleanup now commits before the atomic rate-counter
  transaction; the configured limits and row locking remain unchanged.
- The app persists measured work and confirmed admission across restarts. Native
  status shows acceptance, the specific server operation, truthful activity,
  phase progress and a next action. Stale worker activity stops after 30 seconds.
  Queueing, service pause and manual pause have distinct wording. Unknown download
  size shows bytes without inventing a denominator.

The actual simulator application downloaded and hashed the retained 3.67 MB WAV,
sent the saved request through HTTP, received all phases, downloaded all four
matching artifacts and imported them strictly. `app-recovery/result.json` also
proves a lost POST response, process termination/relaunch, provider interruption
and a failed status request: one POST/UUID throughout, successful final import.
Inference is replayed from the real September 6 fixture, not rerun.

The app test now also verifies that the real status controller is presented.
An earlier harness incorrectly attempted presentation beneath the initial
changelog; the retained `app-presentation-before/run.log` and earlier screenshots
show this failure. The DEBUG/simulator-only driver now invokes the same start
action from the currently presented screen. It changes no production navigation.

## Repeatable verification

Environment: macOS 27, Xcode/iOS 27, dedicated `Server transcription flow`
simulator `79C6B540-E8DC-4E2A-8171-25BB70F7E5D1`. App fixture:
`Tools/fixtures/server-sponsor-e2e/fixture.wav` and adjacent four artifacts.

```sh
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=79C6B540-E8DC-4E2A-8171-25BB70F7E5D1' -derivedDataPath build/ServerStatusDD build
python3 Tools/server_transcription_app_flow_test.py --device 79C6B540-E8DC-4E2A-8171-25BB70F7E5D1 --app build/ServerStatusDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --scenario happy --output /tmp/server-status-happy
python3 Tools/server_transcription_app_flow_test.py --device 79C6B540-E8DC-4E2A-8171-25BB70F7E5D1 --app build/ServerStatusDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --scenario recovery --output /tmp/server-status-recovery
python3 Tools/server_transcription_admission_runtime_test.py
python3 Tools/server_transcription_cancellation_runtime_test.py
python3 Tools/server_transcription_errors_runtime_test.py
python3 Tools/server_transcription_storage_runtime_test.py
python3 Tools/server_transcription_retry_interval_runtime_test.py
python3 Tools/server_poll_lifecycle_runtime_test.py
python3 Tools/server_sponsor_e2e_client_runtime_test.py
python3 Tools/localization_coverage_regression_test.py
git diff --check
```

Backend commands/results, including isolated SQLite and MariaDB, are in
[server-progress-validation.md](server-progress-validation.md). Additional API
tests run with server Python against the isolated source copy:

```sh
.venv/bin/python tools/admission_latency_regression.py AdmissionLatencyTests
.venv/bin/python tools/server_reliability_regression.py
.venv/bin/python tools/api_contract_v3_regression.py
```

The retained server patch includes these exact tests. Admission/HTTP contract:
22 passed; SQLite reliability: 88 passed. Native UI matrix, screenshots, DE/EN
and narrow layouts: [status UX evidence](../2026-09-27-status-ux/README.md).
Client boundary details: [client evidence](../2026-09-27-flow-evidence/client-failure-analysis.md).

## Deployment and remaining verification boundary

13 files were deployed after comparing every original live hash and backing up
source and the production database. Backup:
`var/backups/status-flow-20260927-verified`. `deployment-result-verified.log`
and `production-verification.json` prove matching files, the nullable column,
unchanged job states, restarted services, and HTTP 200 from the public authenticated
schema and existing ready-episode routes. No production test jobs were created.
The first backup attempt using the server administrator's implicit SQL account
failed before any source/schema change; the successful attempt used the configured
database account through a temporary protected options file.

At final live inspection the API and worker were running but new AI work was
unavailable: the real account usage endpoint returned 401 `token_revoked`, even
after regular account refresh. This is documented in `live-provider-diagnosis.json`
and `production-health-after.json`. A fresh live AI processing run requires the
requested account reauthentication. Login-status alone falsely reported logged-in.

Physical airplane mode, iOS background scheduling and actual fingertip navigation
are not verified here. Computer Use could not attach to Device Hub (both bundle ID
and full path timed out). Full-app screenshots retain the OS notification prompt;
the real status page is visible behind it. Unobscured native layout is verified
separately by the actual UIKit controller matrix. No physical-iPhone installation
or TestFlight release was performed.
