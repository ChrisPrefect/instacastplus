# Confirmed client-flow assumptions: two runtime proofs

Run from any directory:

```sh
python3 /tmp/instacast-app-assumption-probes-20261003/probe.py
```

Expected current exit code: **1**, because both desired behaviors fail on the reviewed production source. Compilation succeeds with exit 0. No repository files or production server state are changed. The executable uses the existing controlled HTTP/cache/hash boundary harness and executes extracted production manager methods, including the real atomic snapshot writer. `failure-analysis.md` records the failure matrix and isolation justification written before either probe.

## Results

1. **Healthy saved URL-only intent becomes rejected after restart.** The first POST is held at its acknowledgement. A second server-source job is then saved through production `persistQueue()`; the write succeeds, its queue status is queued, admission is pending, and its UUID/URL/source are durable. Production `loadPersistedQueue()` and `resumeIfNeeded()` reject that second job. Observed: failed/rejected, zero POSTs for its unchanged UUID, message “Not added: the app stopped before this request was submitted. Try again explicitly.” Expected: the saved authorized job resumes automatically with that UUID and source.
2. **Accepted client request cannot retrieve matching text after cache removal.** Production admission succeeds and persists the actual harness start SHA. The cache boundary is then marked absent. The result uses the exact persisted SHA. Production `verifiedImportAudio()` throws `ICServerTranscription.Contract`, code 55. The real ready response followed through `apply()` and `importArtifacts()` yields failed/importing with “Download the complete episode before retrieving its transcript.” No artifact download is reached, no extra POST is made, and the request UUID remains unchanged. Expected: a result matching the immutable saved start SHA passes the source gate independently of present device cache.

## Retained evidence

- `evidence/result.json`: expected/observed states, UUIDs, matching hashes, error domain/code, and peer event counts.
- `evidence/pending-before-restart.json`: exact healthy queued pending snapshot while the first POST is still held. `pending-original.json` is the original manager's working snapshot, including fixture cleanup after the observation.
- `evidence/pending-restored.json`: snapshot after the real restore/resume failure.
- `evidence/client-before-cache-removal.json`: accepted client request with persisted start SHA.
- `evidence/client-import.json`: failed import snapshot.
- `manifest.json`: exact source SHA-256 values, compiler/run commands, environment, and exit codes.
- `compile.log`, `runtime.log`, `command.log`: retained execution output.
- `probe.py`, `cases.swift`, `main.swift`: repeatable runner, scenarios, and generated executable source.

The reviewed repository sources are read afresh on each execution. Re-running after a source edit therefore proves that later source version and updates the manifest; preserve this directory before comparing versions. This is not claimed as full app, real model, or physical-device E2E coverage.
