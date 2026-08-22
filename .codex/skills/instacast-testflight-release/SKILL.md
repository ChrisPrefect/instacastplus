---
name: instacast-testflight-release
description: "Use in the InstacastPlus repo when asked to build, archive, upload, or release an InstacastPlus iOS build to TestFlight or App Store Connect, especially for external tester distribution. This skill captures the repo-specific versioning, signing, ASC API key, German What to Test, tester notification, and verification rules."
---

# Instacast TestFlight Release

## Preconditions

Read [CLAUDE.md](/Users/Chris/Developer/instacastplus/CLAUDE.md) before release work. Treat it as the source of truth for current App Store ID, bundle ID, team ID, ASC key metadata, and known release caveats.

Never print, copy, commit, or expose the private key at `/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8`.

App Store Connect facts currently used by this project:

- App Store ID: `6472283494`
- Bundle ID: `com.iteconomy.instacastplus`
- External tester group: `External Testers` (`aefb6bc1-71f0-4c9d-a792-9b455c0d9a23`)
- Primary beta locale in ASC: `en-US`; still write `What to Test` in German.

## Release Source Of Truth

The current filesystem contents are the only source of truth for a release, including every uncommitted and untracked source, configuration, and resource file. Git commits, branches, tags, remotes, and GitHub never define what is current in this project; GitHub is backup only. Never identify or validate a release by a commit ID.

Inventory the relevant local files immediately before archiving. Recheck them after the archive and before upload, excluding only generated build output and intentional build-number edits. If any relevant file changed, the archive is stale: do not upload it; archive again from the newest filesystem state.

## Scope Discipline

Keep TestFlight releases narrow. Do not run regression tests, broad build suites, long diff archaeology, or simulator checks just because the worktree already contains related changes. For a release-only request, the archive, upload, and ASC state are the required verification.

Use only cheap release facts before building: an inventory of the current local files (including untracked files), current version/build, latest ASC builds for the same marketing version, and at most a diff stat or changed-file list to draft `What to Test`. Git output is only an inventory aid and never the definition of the release contents.

If a release blocker appears, read the failing log and fix only the explicit root cause when it is local and necessary for upload. Then rerun the minimum command that proves that exact blocker is gone. If the blocker is external or ambiguous, stop with the real error instead of expanding into unrelated tests or speculative fixes.

## Workflow

1. Inventory the current filesystem contents and current version/build, including uncommitted and untracked files. Do not revert unrelated local changes. Ignore user-specific Xcode state files unless they block the release. Record enough file state to detect relevant changes before upload; do not use a commit or branch as the release boundary.
2. Confirm the current ASC build state before choosing the next build number. Do not release expired builds or reuse a build number already uploaded for the current release. Do not re-release build `3.4 (10)`, which was already released by the user on 2026-05-23.
3. If uploading a new build, increment only the build number with `agvtool new-version -all <next-build>`. Leave `MARKETING_VERSION` unchanged unless the user explicitly requests a version bump.
4. Archive the iOS app and log the full output:

```bash
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Release -destination 'generic/platform=iOS' -archivePath build/TestFlight/InstacastPlus-<version>-<build>.xcarchive -allowProvisioningUpdates archive > build/TestFlight/archive-<version>-<build>.log 2>&1
```

5. Verify the archive before upload:

```bash
plutil -p build/TestFlight/InstacastPlus-<version>-<build>.xcarchive/Info.plist
tail -n 30 build/TestFlight/archive-<version>-<build>.log
```

Require `CFBundleShortVersionString=<version>`, `CFBundleVersion=<build>`, bundle ID `com.iteconomy.instacastplus`, team `L95F4M2LHG`, and `** ARCHIVE SUCCEEDED **`.

Recheck the relevant local source, configuration, and resource files against the pre-archive inventory. If they changed, discard the archive and rebuild it from the latest filesystem contents before any upload.

If the archive contains the embedded Watch app, check only its built `Info.plist` with `plutil`; require `UIBackgroundModes` to contain `audio`. Do not run Watch regression scripts for a release-only request unless the user explicitly asks.

6. Upload using the repo export options, the ASC API key from the project docs, and log the full output:

```bash
xcodebuild -exportArchive -archivePath build/TestFlight/InstacastPlus-<version>-<build>.xcarchive -exportOptionsPlist build/TestFlight/ExportOptionsUpload.plist -allowProvisioningUpdates -authenticationKeyPath /Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8 -authenticationKeyID 7QUKV6MHZ2 -authenticationKeyIssuerID 69a6de70-cba8-47e3-e053-5b8c7c11a4d1 > build/TestFlight/upload-<version>-<build>.log 2>&1
```

7. Verify the upload log contains `Upload succeeded` and `** EXPORT SUCCEEDED **`.
8. Poll App Store Connect until the new, non-expired build is `processingState=VALID`. Do not claim availability while ASC has not surfaced the uploaded build.
9. Release the build to external testers:

```bash
.codex/skills/instacast-testflight-release/scripts/release_external_testflight.py \
  --build-number <build> \
  --marketing-version <version> \
  --what-to-test "<German user-facing test note>"
```

The script sets or updates `What to Test`, enables `autoNotifyEnabled`, adds the build to the external tester group, submits Beta App Review when ASC reports `READY_FOR_BETA_SUBMISSION`, waits for `externalBuildState=IN_BETA_TESTING`, and attempts a tester notification. If ASC returns `Auto-notify already enabled`, treat testers as notified through auto-notify and report that exact status.

## App Store Connect API

Use the local ASC API key metadata from project docs:

- Key ID: `7QUKV6MHZ2`
- Issuer ID: `69a6de70-cba8-47e3-e053-5b8c7c11a4d1`
- Private key path: `/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8`

Generate JWTs with `xcrun altool --generate-jwt ... --p8-file-path ...` or use the bundled script. `altool` prints the JWT to stderr; never relay that output directly.

Confirm important ASC state through the actual source system before reporting success. At minimum verify:

- `processingState=VALID`
- `internalBuildState=READY_FOR_BETA_TESTING`
- `externalBuildState=IN_BETA_TESTING`
- `betaReviewState=APPROVED` when a review submission exists
- The final `What to Test` text

Stop and report the real ASC error if processing fails, export compliance is missing, review is rejected, or the expected external group cannot be added. Do not work around those states.

## Final Response

Report the version, build number, archive/upload status, ASC build ID, processing/external-testing status, tester notification status, `What to Test`, local files changed by the build-number update or any release-blocker fix, and the exact release validation commands that succeeded.
