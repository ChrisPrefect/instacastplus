# Player title navigation and list scroll restoration

Reported 2026-10-02: tapping the player title briefly reveals the subscriptions
list before opening the podcast. Returning from the podcast reveals the top of
the subscriptions list before restoring its previous scroll position. Both lists
must have their saved position from their first visible frame.

The supplied recording confirms the subscriptions view during dismissal at
approximately 1.24–1.72 seconds and the wrong list position during the back
transition at approximately 4.24–4.72 seconds.

## Cause and change

- `PlayerController` previously opened the destination in the dismissal completion.
  It now prepares the podcast beneath the player before starting dismissal.
  `showEpisodeListOfEpisode:` leaves dismissal to that caller.
- Subscriptions restored in `viewDidAppear`, then queued another main-thread
  block. Both affected controllers now restore synchronously in their first
  on-window layout. Other screens retain their existing restoration API.
- Subscriptions now save before disappearance and consume a pending reload in
  `viewWillAppear`, before restoring geometry.
- Podcast episodes reloaded again after appearing, and their height estimator
  discarded already measured row heights. Reloading now precedes display, and
  the podcast reuses the existing cell-height cache for measured rows. Unmeasured
  rows keep estimated sizing; this adds no eager full-list text measurement.

There are no fixed delays in these title/back navigation paths. The existing
player-end handler separately contains 0.5/0.1-second scheduling, and search,
refresh coalescing, scroll-state persistence and onboarding use their own timers.
Those are not responsible for the reported transitions and are outside this fix.

## Repeatable simulator run

Use the dedicated **Instacast Navigation Regression** simulator. Its fixture data
is owned by this test; the driver replaces only feeds named `Navigation Fixture…`.
The driver creates 45 feeds and 144 episodes, with 100 episodes in feed 25, and a
180-second silent WAV. It scrolls subscriptions to row 22 and episodes to row 35,
opens/closes the player, returns to subscriptions, opens the player again, invokes
the production title action, then pops the podcast navigation controller.

```sh
xcrun simctl boot 5492733F-33EF-4C7A-9484-3E9C31E47EED
xcrun simctl bootstatus 5492733F-33EF-4C7A-9484-3E9C31E47EED -b
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'platform=iOS Simulator,id=5492733F-33EF-4C7A-9484-3E9C31E47EED' build
python3 Tools/player_navigation_simulator_test.py --udid 5492733F-33EF-4C7A-9484-3E9C31E47EED --app /Users/Chris/Library/Developer/Xcode/DerivedData/Instacast-cgtqgggsjixnfbdsmznxtbkjogvj/Build/Products/Debug-iphonesimulator/InstacastPlus.app --evidence build/NavigationRegression/verified
```

Skip `boot` when already booted. The script records its exact command, OS/device,
fixture, app/source hashes, all command responses, stdout/stderr, CADisplayLink
samples, PNGs and a simulator video. No app method is replaced.

Evidence retained in `build/NavigationRegression/`:

- `before/`: original failing run, build log, three failed transition assertions.
  29 frames expose subscriptions during player dismissal; subscriptions differ by
  1538 points during back navigation; podcast episodes differ by 240 points.
- `after/`: destination/lifecycle correction fixes the two intermediate views;
  episode height estimation still fails.
- `after-heights/`: all original assertions pass after reusing measured heights.
- `verified/`: final scoped implementation, plus stronger checks for the visible
  episode and ordinary player dismissal. Zero offset drift is required in every
  visible sample, as well as the same visible episode and relative screen Y.
- `user-recording/`: frame sheets extracted from the supplied recording.

`*-app.png` captures render the actual application window, excluding system
windows. Raw simulator screenshots/video also retain a notification permission
prompt. Desktop Device Hub accessibility calls timed out, so that prompt was not
dismissed. Geometry is sampled inside the real app, but native finger recognition,
an unobscured device-level recording, release performance and a physical iPhone
have **not** been verified. The test invokes production UI actions rather than
synthesizing touches. This is not a timing/performance benchmark.

## Adjacent validation

```sh
python3 Tools/list_refresh_scroll_simulator_test.py --udid 55AC6F95-4BD9-443B-917A-3B4584495A69 --app /Users/Chris/Library/Developer/Xcode/DerivedData/Instacast-cgtqgggsjixnfbdsmznxtbkjogvj/Build/Products/Debug-iphonesimulator/InstacastPlus.app --case first25 --evidence build/NavigationRegression/list-refresh-first25
git diff --check
```

The focused refresh run passes 8/8 checks for insert, unchanged and repeated
refresh, preserving the episode and screen Y throughout. The broader `--case all`
run in `list-refresh/` passes those first eight checks, then fails during fixture
setup for the deep case: the feed contains 80 episodes but the unplayed list reports
50. It never reaches that case's scroll assertion and is not a passing result.
The cause of that separate count discrepancy has not been established here.
