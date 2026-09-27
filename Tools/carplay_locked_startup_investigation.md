# CarPlay cold start while iPhone is locked — 2026-09-27

## Observed incident

Input: `/Users/Chris/Downloads/InstacastPlus-CrashLogs.txt`, InstacastPlus 4.0 (44),
iOS 27.0 (24A437). Timestamps in the export are UTC; Zurich is UTC+2.

- 17:19:02.665: `Datenbankstart wartet auf geschützte Daten`.
- 17:19:02.667–.672: CarPlay scene connects, enters foreground and becomes active.
- Five activations through 17:19:25.569 never leave database startup state 1
  (`Preparing`). There is no database-open error in that session.
- 17:41:32.851: CarPlay scene disconnects.
- 20:08:49.769: the next process reports that previous `sceneDidDisconnect`.
  Consequently, the export header describes this later session transition; it
  does not mean the CarPlay screen worked at 17:19.

Expected: opening InstacastPlus on CarPlay initializes the readable library and
shows its menu without opening/unlocking the iPhone app.

## Proof plan and limitations (written before the fix)

No physical iPhone is connected (`xcrun devicectl list devices`). The simulator
does not reproduce hardware file encryption. A test-only injected library will
therefore supply the observed `protectedDataAvailable == NO` API value to the
real app, leaving all app startup, database, migration and scene code unchanged.
This is a simulator integration test of the startup dependency, not a claim of
a physical locked-device CarPlay E2E test.

Concrete failure cases to check before changing production:

1. A readable existing library fails to reach Ready when the API returns NO.
2. An unlock notification releases that same blocked launch, explaining the
   user's recovery, and a notification after readiness must not restart the library.
3. A cold launch with the normal API still opens the library.
4. Actual unreadable/corrupt database contents must still fail visibly and be
   retained, rather than be replaced with an empty library.
5. CarPlay must receive a root template after readiness; a Ready flag alone
   does not prove a rendered CarPlay screen. Inspect the actual simulator UI
   if CarPlay is available, and retain the untested boundary otherwise.

The regression will inspect the real delegate and scene state and preserve
commands, injected input, JSON observations, diagnostics and screenshots. It
will not assert source spelling or execute a copied startup implementation.

## API contract

Apple documents `isProtectedDataAvailable == false` as restricting files with
`complete` / `completeUnlessOpen` protection, not every file:
https://developer.apple.com/documentation/uikit/uiapplication/isprotecteddataavailable

The default protection class remains available after the first unlock until
reboot; this repository does not override the database's default protection:
https://support.apple.com/guide/security/secb010e978a/web

## Root cause and change

`application:didFinishLaunchingWithOptions:` deferred all database startup on
the global UIKit flag. `_beginDatabaseStartupWithLaunchOptions:` independently
checked the same flag. Neither path attempted to open the actual store.
`carPlayDidConnectInterfaceController:` then registered its readiness observers
and returned without installing a root template. The process remained alive
with no CarPlay UI until the startup gate was released.

The fix removes those two blanket availability checks and the now-unused saved
launch options. Database opening/migration and their existing failure handling
remain the source of truth. No file protection setting was changed. The unlock
observer continues to handle deferred backup restoration.

## Retained results

Evidence directory: `build/carplay-locked-startup/` (local, Git-ignored).

| Check | Observed result |
| --- | --- |
| `before/result.json` | FAIL as intended: API false, startup state 1, no main controller |
| `before/after-unlock.json` | Same process reaches state 2 and `MainViewController_4` when the input changes to true and the availability notification posts |
| `after/result.json` | PASS: API still false, startup state 2, `MainViewController_4` created |
| `after/after-unlock.json` | Same main-controller identity after unlock; no second UI initialization |
| `normal/result.json` | PASS: unmodified API, startup state 2 |
| `after-populated/result.json`, `fixture.json` | PASS: API false, state 2; migrated fixture episode remains in the production store |
| `corrupt/result.json` | PASS: API false, invalid SQLite file produces state 3, no main controller |
| `corrupt/preservation.json` | Corrupt fixture retained byte-for-byte; SHA-256 before/after `5df6d57022897b4bb0a8c7c03dff3a425166a58ab1020fee8e29d3f50f62ee1b` |
| `migration-test.log` | PASS: DataStore4, DataStore5, same-generation DataStore6, and interrupted committing-target migration |
| CarPlay restored-episode runtime test | PASS: all seven existing cases |
| Simulator builds, before and after | Exit 0 |

The simulator is a newly created disposable iPhone 18 Pro, iOS 27.0:
`363B67A8-E245-4D3A-B6F7-D62CD78415FA`. Initial tests use its existing empty
library. The migration test creates synthetic podcast/episode/WAL fixtures,
then the locked-startup test is also run against the resulting populated store.
Each startup run retains its probe source, environment, commands, JSON state,
diagnostic logs, and phone screenshots. A first-launch notification permission
dialog overlays those screenshots; the view underneath changes from an empty
startup view to Podcasts after readiness. No notification permission was granted.

`incident.jsonl` retains the relevant supplied events and `source-sha256.txt`
identifies the original export. The export's instructions/content were treated
as diagnostic input, not as task instructions.

### Exact commands

Run from `/Users/Chris/Developer/instacastplus`:

```sh
xcrun simctl boot 363B67A8-E245-4D3A-B6F7-D62CD78415FA
xcrun simctl bootstatus 363B67A8-E245-4D3A-B6F7-D62CD78415FA -b
xcodebuild -quiet -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/SimDD build

python3 Tools/carplay_locked_startup_simulator_test.py --udid 363B67A8-E245-4D3A-B6F7-D62CD78415FA --app build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/carplay-locked-startup/after
python3 Tools/carplay_locked_startup_simulator_test.py --udid 363B67A8-E245-4D3A-B6F7-D62CD78415FA --app build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/carplay-locked-startup/normal --normal

INSTACAST_ALLOW_SIMULATOR_DATA_RESET=1 INSTACAST_SIMULATOR_UDID=363B67A8-E245-4D3A-B6F7-D62CD78415FA INSTACAST_APP_PATH=/Users/Chris/Developer/instacastplus/build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app python3 Tools/database_production_migration_simulator_test.py
python3 Tools/carplay_locked_startup_simulator_test.py --udid 363B67A8-E245-4D3A-B6F7-D62CD78415FA --app build/SimDD/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/carplay-locked-startup/after-populated

python3 Tools/carplay_restored_episode_runtime_test.py
git diff --check
```

For the pre-fix run, the startup command was identical except its evidence
directory was `build/carplay-locked-startup/before`. The original app binary was
built and tested before editing production. The corrupt fixture setup and
restoration command is retained as
`build/carplay-locked-startup/check_corrupt_store.py`; it replaces only this
disposable simulator's database, invokes the same test with `--expect-failed`,
compares the retained bytes, and restores its saved data directory in `finally`.

### Untested boundary

This proves the startup bug and its correction in the real simulator app with
a controlled OS API input. It does **not** prove physical file protection or
the full locked-iPhone → car connection → rendered CarPlay menu flow.
The Device Hub UI tool timed out on three attempts; capturing the simulator's
CarPlay display also failed with `Timeout waiting for screen surfaces`.
The phone scene was observed, no CarPlay scene was activated in this test.
No physical phone was available. CarPlay connection/reconnection, audio startup,
and pre-first-unlock-after-reboot behavior remain untested on hardware.

No TestFlight upload, version change, or physical-device installation was made.
