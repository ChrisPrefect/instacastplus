# App boundary corrections and validation

The original read-only probes, generated source and manifests remain as before evidence. `independent-before.log` adds a failing executable proof for slow artifact imports delaying unrelated POST/DELETE calls. `explicit-source-before.log`, `import-wake-before.log` and `delete-control-before.log` preserve the additional concrete retry and control-path failures before their surgical corrections.

## Final behavior

- A healthy durable pending request resumes after restart with the same UUID, URL and audio source. A failed queue write prevents HTTP until a complete snapshot is durable; it pauses the saved intent rather than turning it into a server rejection. Explicitly rejected, failed, cancelled and manually paused history remains unchanged.
- A client-source result must match the request's persisted start SHA. It can be read after the device cache is removed or replaced. Server-source results retain their server SHA. Missing historical client proof and mismatching server hashes are rejected. Submission-time file integrity and playback-time audio verification remain in place.
- One bounded result-import task is independent of the serial request-status/submission task and cancellation task. A slow artifact or DELETE response no longer owns unrelated episode control. Ready results wait visibly in `awaiting_import`; only one result's four artifacts download at once. Same-episode replacement remains blocked until its cancellation receipt confirms the tombstone.
- Removing an importing item cancels its task; actual UUID/current-item checks prevent late artifact commits or stale failure publication. Other pending results are preserved and get the released import slot.
- A due import waiting for the occupied slot does not schedule an immediate retry loop. Both the normal scheduler and timer use the same slot eligibility.
- Explicit new transcription of a completed or terminal-source request creates a new UUID with `force=true`, including when a previous response did not provide a numeric server ID. It clears the previous result's import-only flag. Retrying only a failed result retrieval retains its UUID and never requests regeneration.
- Automatic admission skips an already-owned episode and continues with following episodes; actual queue capacity exhaustion still ends the batch.

## Checks

All eight production-method runtime suites listed with exact commands and logs in `fix-validation.json` passed. The independent-control suite exercises pending restart, immutable-source matching without cache, missing/mismatching proof rejection, bounded imports, POST/DELETE independence in both directions, same-episode tombstone ordering, late cancellation, surviving imports, timer eligibility, and explicit new-source retry. The existing suites cover admission, lost/malformed replies, offline recovery, cancellation, storage corruption/owner preservation, retry intervals, visible processing lifecycle, typed errors, and episode deletion before commit.

`git diff --check` passed for this scope. The manifest records final source hashes. Root separately owns the full app build and actual simulator scenarios (`pending_restart`, `cache_removed`, `import_concurrency`) and their screen/HTTP artifacts; these boundary checks are not presented as full app E2E or production model inference. No server deployment was performed by this workstream.
