# AGENTS.md

This repository uses [CLAUDE.md](./CLAUDE.md) as the primary project instruction file.
Read it before changing code. Do not duplicate or reinterpret it loosely.

## Bugfix Gate

When the user reports a bug, regression, crash, flaky UI behavior, or says a previous fix did not work:

1. Do not start by patching code.
2. Restate the observed symptom, expected behavior, actual behavior, platform, and reproduction steps. If any of these are unclear, ask before changing code.
3. Reproduce the bug or create the closest deterministic proof. For UI/lifecycle bugs, prefer simulator/app reproduction, logs, screenshots, or a focused source-aware regression test.
4. Write or extend a failing regression test before the production fix. Confirm it fails for the intended reason.
5. Only after the failing proof exists, identify the real root cause from code, logs, and lifecycle/state transitions.
6. Do not use workarounds, fallback behavior, delays, broad reloads, speculative guards, or "try this" fixes.
7. Make the smallest surgical code change that explains the failing test and the observed bug.
8. Run the exact regression test again and any nearby focused checks needed to prove the fix.
9. In the final response, state problem, root cause, fix, and validation commands.

If the bug cannot be reproduced with the available information, stop and ask for the missing evidence instead of guessing.

When a bug or release risk depends on external state — cloud schemas, server
configuration, permissions, App Store Connect/TestFlight state, provisioning, or
other production infrastructure — verify the real remote/production state directly
against the expected state. Do not infer it from local code, development
environments, or successful builds alone.

## Build And Test Policy

Follow `CLAUDE.md`:

- Do not run full builds automatically unless the change is large or build verification is specifically needed.
- For small changes, prefer focused tests or `git diff --check`; the user can verify directly.
- If build/test verification is needed but not executed, provide the exact commands.

## Scope Discipline

Follow `CLAUDE.md` and keep every changed line traceable to the user request. Do not refactor adjacent code, clean up unrelated code, or revert unrelated dirty files unless the user explicitly asks.

Normal active development is expected in this repository. "Dirty" only means Git has
uncommitted changes; do not treat that as a blocker by itself. Ignore routine Xcode
workspace/user-state churn such as `*.xcuserstate` and continue editing code for the
user's task. When existing uncommitted code overlaps the requested change, read it and
work with it instead of reverting it.

## UI-Reaktivität

UI-Reaktivität hat oberste Priorität. Sync-, Abonnier- und Massen-Ladevorgänge (iCloud Sync, Feed-Hydration, Episoden-Nachladen) müssen mit niedriger Priorität asynchron im Hintergrund ausgeführt werden — die UI darf dadurch nie blockieren oder stottern, auch nicht bei 1000 Abonnements. Große Core-Data-Schreibvorgänge gehören in kleine Batches mit Pausen, nie in einen einzelnen Main-Context-Push (siehe CLAUDE.md „iCloud Sync").
