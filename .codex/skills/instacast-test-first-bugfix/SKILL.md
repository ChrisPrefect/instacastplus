---
name: instacast-test-first-bugfix
description: "Use in the InstacastPlus repo when the user reports a bug, regression, crash, flaky UI behavior, or broken Objective-C, Swift, watchOS, widget, playback, sync, transcription, or list behavior. This skill enforces the project workflow: reproduce with a focused regression test first, identify the real root cause, then make the smallest fix and prove it with the test."
---

# Instacast Test-First Bugfix

## Workflow

1. Read [AGENTS.md](/Users/Chris/Developer/instacastplus/AGENTS.md) and [CLAUDE.md](/Users/Chris/Developer/instacastplus/CLAUDE.md) before editing.
2. Build a short bug packet: symptom, expected behavior, actual behavior, platform, reproduction steps, and likely ownership area.
3. Write or extend one focused failing regression test before fixing code.
   - Prefer `Tools/*_regression_test.py`.
   - Keep the test narrow and source-aware when a full simulator reproduction is impractical.
   - Run the test and confirm it fails for the intended reason before patching.
4. Trace the real cause with `rg`, nearby code, existing tests, and relevant lifecycle or state transitions. Do not use delays, fallbacks, broad rewrites, or speculative fixes.
5. Patch the smallest code path that explains the failing test.
   - If current instructions allow subagents, hand the failing test plus a strict file ownership boundary to a worker.
   - Tell workers they are not alone in the codebase and must not revert unrelated edits.
6. Validate with the exact regression test, then any nearby low-cost tests. Build only for larger changes or build failures.
7. Final response must state: problem, root cause, fix, and validation commands.

## Common Validation

Use the smallest relevant command first:

```bash
python3 Tools/<name>_regression_test.py
git diff --check -- <touched paths>
```

For larger changes or build-break reports:

```bash
xcodebuild -project Instacast.xcodeproj -scheme Instacast -configuration Debug -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Instacast.xcodeproj -scheme InstacastWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
```

## Failure Shields

- Never fix before reproducing unless the user explicitly asks for analysis only and no code.
- Never hide the bug with timing delays, alternate fallbacks, or unrelated UX changes.
- Do not touch unrelated dirty files, Xcode user state, or generated workspace state.
- Keep Objective-C and Swift changes in the established style.
- If a runtime test is impossible, say why and create the closest deterministic source-level proof.
