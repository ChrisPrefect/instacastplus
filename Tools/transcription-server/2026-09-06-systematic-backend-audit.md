# S1: Backend state and failure-boundary audit

Read-only code investigation against the deployed edge-case and provider-stop mirror. All behavioral probes used disposable SQLite/MariaDB state. No production changes or new implementation in this audit. RSS/network feed transport belongs to the root workstream.

## Invariants

1. Client identity + request UUID identifies one durable intent; cancellation cannot be undone by an ordinary writer.
2. Admission commits request binding, membership and queue work together; uncertain transport never means definite refusal.
3. Every open job consumes capacity; only one current claim can mutate its generation.
4. A retry preserves identity and completed work, obeys a persisted schedule and cannot reset its budget through another entry point.
5. Checkpoint reuse requires the same source and analysis inputs; a completed marker is published only after its data.
6. Ready status, artifact metadata and any promised completion event must be durably recoverable together.
7. Retention removes expendable data, not terminal semantics or checkpoints needed by open jobs.

## Ranked findings

### P1 — canceled legacy interest is overwritten by two ordinary writers (behaviorally reproduced)

`app/main.py:1577,1681,1768`: episode POST and podcast POST store `legacy:{episode_id}` as active without checking its terminal receipt. With A canceled and B retaining the shared job, both episode POST and podcast POST with `enqueue_latest=false` return202 and change A from canceled to active. GET and legacy retry protect the tombstone; these writers do not. `app/service.py:243` permits unconditional state overwrite.

Proof output: `legacy_before_post=canceled`, `legacy_post_status=202`, `legacy_after_post=active`, `legacy_after_podcast_post=active`.

### P1 — permanent failure and attempt exhaustion are not durable across all enqueue paths (behaviorally reproduced)

`app/worker.py:6459–6470` auto feed scan only excludes ready/canceled/deleted. A failed `no_speech` episode receives a fresh queued job despite retryable=false. `app/main.py:679–694` checks the failed job error instead. `app/worker.py:6537–6539` deletes failed jobs after the configured30days; that deletes the only error evidence, so main subsequently allows enqueue and reports generic retryable transcription_failed.

Proof output: enqueueable false before retention; auto scan creates1 new transcription; enqueueable true after retention; public error becomes transcription_failed.

### P1 — valid URLs collide in MariaDB after their first512 characters (behaviorally reproduced)

`app/db.py:474,485` uses UNIQUE prefixes for episode_url and alias url. The API permits2048-character URLs. Two different valid621-character URLs with the same prefix fail on the second ensure_episode with MariaDB IntegrityError1062. SQLite does not reproduce this backend-specific failure. Disposable test database was removed. Root should compare the actual production index definition before migration.

### P2 — transient source failures are immediately reclaimed (behaviorally reproduced)

`app/worker.py:333–377` sets retryable work directly to queued; `claim_job:225–230` has no next-attempt predicate. Source503 immediately yields the same job at attempts2. Source429 Retry-After is not retained by `_download_audio_process:524–568`. Thus short flaps can exhaust all three attempts before recovery; auto feed scans can subsequently reset the budget by creating a new job.

### P2 — renewed source URL is recorded but ignored by execution (code-proven cause; policy needed)

`app/service.py:402–421` matches podcast+GUID and stores the new URL only as an alias. It does not update episodes.episode_url. `app/worker.py:6720–6725` always downloads that old canonical URL, including a new explicitly requested generation. Therefore a renewed signed URL can be known while retries continue using the expired URL. Required policy: bind each generation to an explicit accepted source URL; keep already-completed byte identity immutable. An alias alone does not prove equal bytes and must not silently authorize old artifact reuse.

### P2 — terminal commit and webhook outbox are separate (inspected, injection proof pending)

`app/worker.py:7410–7424`: finish_job commits ready/done, then source cleanup/readback runs, then queue_webhook inserts in another transaction (`6283–6315`). Crash or exception in between permanently loses a promised completion event. The error handler cannot recover it: fail_job rejects the already-done claim. Current v1 submission does not expose callback_url; this affects retained/legacy callback jobs, not normal app polling.

### Checkpoint identity rule is incomplete (inspected; desired revision policy must be explicit)

Chunk plans now bind exact audio SHA and ASR settings. Full raw reuse (`worker.py:6770–6773`) checks timestamp structure and files; completed AI reuse (`691–705`) checks purpose/revision/payload shape. Neither binds the complete upstream content/model/prompt/settings identity. Tests cover normal private snapshot resume and stale claim fencing, but not changed-model/prompt/revision combinations or crash after provider success before usage/checkpoint writes. Do not claim this area proven merely from existing green tests.

## State/failure matrix

E = existing behavioral regression; P = additional isolated audit probe; I = inspected only; U = missing systematic injection coverage.

| Boundary | Existing or demonstrated coverage | Missing failure cuts / composition |
|---|---|---|
| UUID reserve → feed lookup → bind+enqueue commit | E cancel-before-POST, UUID conflict, overlapping POST, unbound404, authoritative refusal | U connection loss before/after each COMMIT; identity restoration coordinated with app |
| Client membership and global250/client25 | E concurrent SQLite/MariaDB, paused counting, admin/API boundary | P legacy tombstone overwritten by episode/podcast writers; U complete state×writer table |
| All source identities / aliases | E server audio SHA persisted; P MariaDB prefix collision | I renewed URL remains unused; U alias/GUID disagreement and explicit generation source contract |
| Claim → lease → heartbeat → reclaim | E two workers, lease renewal race, exhaustion, real SIGTERM/SIGKILL | U each DB disconnect/commit-ack loss; I fork occurs after production MySQL context closes, no demonstrated inherited-live-transaction bug |
| Download → rename → probe → source marker | E hard deadlines, blocked read, STOP,404,oversize,duration,ENOSPC | U crash before/after target rename/marker/metadata commit, process death without full systemd cgroup termination |
| ASR chunks → raw manifest | E private copies, source/settings mismatch, late old write, empty real exporter | U ENOSPC at each output, raw checksum/revision matrix, abrupt host-power-loss/fsync contract |
| AI request → response → usage → checkpoint | E OAuth auth/quota/timeout, paid usage on malformed response, shutdown race | U success followed by usage/checkpoint write failure; model/prompt/upstream identity and replay-cost policy |
| Publish metadata → finalizing → ready | E late claim denied, atomic artifact checks, invalid artifacts rejected | U exception/DB-ack loss at every transaction and post-success cleanup boundary (root owns independent artifact review) |
| ready/failed → completion notification | I outbox gap; queued webhook retry has bounded delays | U atomic event creation, sending crash recovery with another surviving worker, receipt idempotency |
| Retry / permanent failure / retention | P auto scan resets permanent failure; P retention changes terminal meaning; P immediate source retry | U durable next_attempt_at, clock jumps, exhausted-generation semantics across every writer |
| Cancel/delete → late work → retention | E tombstones, late publication fence, paused-source retention | P legacy writer resurrection; U retention+terminal+new-generation cross product and ambiguous legacy identity |

Existing aggregate test counts contain inherited/repeated tests. They do not constitute enumeration of this matrix or proof of every failure boundary.

## Bounded implementation packets and dependencies

1. **Terminal intent and failure policy:** main/service/worker/db plus lifecycle tests. Central transition rule used by every ordinary admission writer and auto scan; durable terminal reason independent of job-log retention. New user retry must be explicit. First failing tests are the three reproduced sequences above.
2. **Retry schedule:** db/worker/service plus failure-injection tests. Persist next_attempt_at and classify retry delay/Retry-After; claim only when due; preserve max attempts within generation. Depends on packet1 preventing other writers from resetting the budget.
3. **Checkpoint provenance:** worker + transcribe tools, focused snapshots/failure-injection tests. Define generation source/ASR/model/prompt/upstream hashes, validate completed stages against them, prove crash cuts around data/marker/DB pointer. Do not introduce silent cache fallback or claim paid provider calls are exactly-once without provider support.
4. **Transactional completion event:** worker/service/db if needed. Insert outbox with ready/failed commit, snapshot the correct generation, keep post-success cleanup outside job-failure semantics. Inject failures before/after commit and delivery acknowledgement.
5. **Full URL identity / renewed URLs:** separate schema/source-generation packet after root verifies production indexes and decides accepted-generation source policy. Depends on provenance contract; do not rotate an already-bound active source or equate aliases with identical audio.

No production deployment is part of this audit. Root owns bounded RSS transport, live verification, and deployment coordination.
