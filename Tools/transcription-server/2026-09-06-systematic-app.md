# S2 implementation result — 2026-09-06

Production source frozen after focused validation; no build or installation performed by this agent. Engine/Generator interfaces and implementations untouched.

## Fail-first evidence

Permanent `Tools/transcription_queue_storage_regression_test.py` initially failed5 invariants: both failed-load paths, missing atomic owner identity, unreachable storage error, and unbounded retry interval. Permanent `Tools/server_transcription_storage_runtime_test.py` initially trapped on `Unreadable snapshot was overwritten and cancellation intent lost`. Temporary source-extracted proof also demonstrated allocator address reuse inheriting serverID42 and0POST; unbounded retry proof trapped converting Double→UInt64.

## Changes

- Retention retires every per-item metadata entry before removing the object. Fresh episodes cannot inherit stale ObjectIdentifier-bound IDs.
- Both queue loaders now distinguish missing files from read/decode failure. Failure blocks admission, processing, and replacement writes; local cache-deletion preparation/completion receives the storage error. Existing files remain unchanged. Recovery retries loading the original snapshot, preserving its entire item/outbox set.
- Storage errors keep the queue reachable even with no decoded items. Header explains unreadable/corrupt/owner-missing state and exposes `Retry storage access`; both queues retry after protected-data availability and foreground resume. Background completion sees load errors through the existing persistence-error contract. Recent unsaved cancellation changes do not claim to be saved.
- Server snapshot includes ownerClientID alongside items/cancel outbox. Snapshot owner is authoritative even when UserDefaults changes. Legacy snapshots migrate using a valid existing client ID; legacy owned requests without an identifiable owner remain blocked. New installs persist owner before any request. UUID/case is preserved exactly to retain the server's client hash.
- API retry interval contract1...86400seconds is enforced for successful envelopes and Retry-After. Invalid intervals preserve accepted/unconfirmed ownership and app capacity, with a persisted explicit-status-check pause. Explicit check reconciles the same UUID; it does not cancel/create a replacement. Cancellation retry errors preserve the outbox. Persisted poison dates and timer conversion are guarded; no arbitrary fallback delay.
- Root's tested ICServerHTTPClient integrated at file scope: envelope1MiB, each artifact25MiB, descriptor bounds before transport, incremental decoded-body cap off UI, total resource timeout120seconds, cancellation handling. Artifact exact-size/hash/MIME/revision validation remains intact.
- DE/EN messages added. S3's Widget `Chapter Timeline` key added in Widget DE/EN resources.

## Validation passed

New executable checks:

- `python3 Tools/server_transcription_storage_runtime_test.py`: corrupt/unreadable no-clobber, complete recovery, owner migration/defaults loss/unknown-owner block, first-install durability, metadata retirement.
- `python3 Tools/transcription_local_storage_runtime_test.py`: actual local decode/write-entry boundaries; no clobber, deletion-preparation callback failure, recovery preserving deletion intents, absence versus unreadable.
- `python3 Tools/server_transcription_retry_interval_runtime_test.py`: negative/zero/86401/Int.min/Int.max,1/60/300/86400, accepted/unconfirmed ownership, persisted pause, same-UUID explicit check, poisoned saved date.
- `python3 Tools/transcription_queue_storage_regression_test.py`.
- `python3 Tools/server_transcription_http_runtime_test.py` without helper environment variable: declared/chunked oversize, continuous-response total timeout,30prestart cancellation races, in-flight cancel,25concurrent valid requests.

Existing admission, cancellation, unchanged-poll lifecycle, typed-errors runtime checks all passed. Client contract, API, status logging, poll efficiency, capacity, BG persistence/quiescence, BG ownership, queue ownership, remote cancellation, discovery outbox, capacity notice UI, and tap/restart focused checks passed. Old source pins were updated only to reflect the stronger load+write error contract and distinguish a valid normal poll from explicitly rejected malformed scheduling hints.

App and Widget DE/EN `plutil -lint` passed; `git diff --check` passed for owned files/tests.

## Remaining evidence limitations

Desktop harness does not prove real iOS file-protection transitions, lock/unlock callback delivery, BG expiration at every device write/import boundary, or actual full-device-storage recovery. Root owns final integrated build, device installation, and server contract/deployment verification. A legacy snapshot without owner field can only use the existing defaults ID; its historic ownership cannot be independently reconstructed if that older ID had already been replaced before migration. Such missing/invalid ownership is never silently regenerated.

## Final coordinated duration contract

Root's additional demonstrated SRT/audio-duration mismatch is now rejected immediately after SRT parsing and before any artifact writes by `validateServerTranscriptBounds(_ cues: [ICTranscriptCue], serverDuration: Double?) throws`. Measured duration must be present/finite/positive; cue ends are compared to rounded canonical milliseconds without modifying cues. New `Tools/server_transcript_duration_bounds_regression_test.py` first failed for absent guard, then passed. Root owns the complementary actual-cue runtime fixtures and backend bound. Shared cancellation harness now uses typed ICTranscriptCue stubs. Cancellation, storage and HTTP runtime tests passed again after integration. Production freeze sent to root and S3.
