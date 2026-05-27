---
name: instacast-testflight-release
description: "Use in the InstacastPlus repo when asked to build, archive, upload, or release an InstacastPlus iOS build to TestFlight or App Store Connect, especially for external tester distribution. This skill captures the repo-specific versioning, signing, ASC API key, German What to Test, tester notification, and verification rules."
---

# Instacast TestFlight Release

## Preconditions

Read [CLAUDE.md](/Users/Chris/Developer/instacastplus/CLAUDE.md) before release work. Treat it as the source of truth for current App Store ID, bundle ID, team ID, ASC key metadata, and known release caveats.

Never print, copy, commit, or expose the private key at `/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8`.

## Workflow

1. Check the worktree and current version/build. Do not revert unrelated local changes.
2. If uploading a new build, increment the build number with `agvtool new-version -all <next-build>`.
3. Archive the iOS app:

```bash
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Release -destination 'generic/platform=iOS' -archivePath build/TestFlight/InstacastPlus-<version>-<build>.xcarchive -allowProvisioningUpdates archive
```

4. Upload using the repo export options:

```bash
xcodebuild -exportArchive -archivePath build/TestFlight/InstacastPlus-<version>-<build>.xcarchive -exportOptionsPlist build/TestFlight/ExportOptionsUpload.plist -allowProvisioningUpdates
```

5. Confirm processing in App Store Connect before saying the build is available.
6. For external testing, set `What to Test` yourself in German, keep it concise and user-facing, and notify testers.
7. Do not re-release build `3.4 (10)`, which was already released by the user on 2026-05-23.

## App Store Connect API

Use the local ASC API key metadata from project docs:

- Key ID: `7QUKV6MHZ2`
- Issuer ID: `69a6de70-cba8-47e3-e053-5b8c7c11a4d1`
- Private key path: `/Users/Chris/Developer/AuthKey_7QUKV6MHZ2.p8`

Confirm important ASC state through the actual source system before reporting success.

## Final Response

Report the version, build number, archive/upload status, processing/external-testing status, tester notification status, and the exact validation commands that succeeded.
