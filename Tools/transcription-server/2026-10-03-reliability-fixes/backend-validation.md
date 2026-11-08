# Backend reliability fixes — 3 October 2026

Four reported failures were reproduced against unchanged server methods before production edits. The baseline sources were compared by SHA-256 directly with production. This package is prepared and tested; deployment/live verification is owned by the coordinating task and must be recorded separately.

## Changes

- A complete HTTP206 is accepted only when its Content-Range covers the entire representation and the received bytes match. Partial or malformed range responses never become the saved audio source. Full HTTP200 and full HTTP206 remain supported; truncated transfers remain failures.
- The recovery marker for a fully downloaded and hashed source is published under the worker claim before its request binding is committed. A process interruption during duration probing now resumes the original audio, including when its public URL has changed. A failed checkpoint write does not bind an unrecoverable source.
- `episodes.source_generation` distinguishes real audio generations at the same real URL. New UUID plus `force=true` selects a new generation or compatible active work. Different client hashes select separate generations, matching hashes may reuse a valid ready generation. Previous UUIDs, episode IDs, artifacts and source hashes retain their bindings. Normal server-mode requests may reuse a valid ready result; an explicit new attempt performs new source selection. No invented URL identifiers are used.
- Explicit repair of a broken ready result uses a new generation with `ALLOW_API_FORCE=false`. Administrative force without a UUID stays restricted. Selection is repeated under the admission lock when another request created/completed the episode after the initial lookup. Podcast discovery returns the current generation once. Cancellation of an old generation does not guess ownership of an unbound new UUID from URL equality.

Schema revision: `2026-10-03.2`. Existing episodes become generation 0. MariaDB installs uniqueness on the full URL SHA-256 plus generation before dropping the previous single-URL indexes. SQLite rebuilds the episodes table atomically only when its old inline single-URL constraint exists, preserving IDs, referencing tables, indexes and triggers.

## Reproduction and boundaries

`failure-matrix.md` records expected/actual behavior and isolation reasoning before each fix. `audit-before.jsonl` retains the original probes. Red logs are the files ending in `-before.log`; green logs are the corresponding after/final suite logs.

Tests execute the actual API, queue transactions, request bindings, HTTP downloader, source checkpoints, artifact validator and duration decoder. Network is loopback; public address validation is the only HTTP network policy substituted. Source fixtures are deterministic mono PCM WAV files. Expensive ASR is stopped at its invocation boundary; no inference or paid provider calls occur. Worker failure timing is controlled at an actual method boundary. No production DB environment is loaded into tests; every test uses temporary SQLite files or a freshly created disposable MariaDB database.

This is backend HTTP/runtime and migration evidence, not a full app/real-provider E2E result. The coordinating task owns that final integration verification.

## Exact commands

From the repository root. The remote isolated snapshot is `/tmp/instacast-server-source-20261003`; its `app/*.py` must match `server-reliability-manifest.json`. Copy the files in `tests/` to the snapshot's `tools/` directory; other helper files come from the current server test snapshot. The checked sources remain under `.codex/private/server-source-20261003` locally.

```sh
.codex/private/ssh 'sudo -n env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python -B /tmp/instacast-server-source-20261003/tools/source_generation_regression.py'
.codex/private/ssh 'sudo -n env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python -B /tmp/instacast-server-source-20261003/tools/source_recovery_regression.py'
.codex/private/ssh 'sudo -n env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python -B /tmp/instacast-server-source-20261003/tools/queue_admission_mysql_regression.py --source-generations'
.codex/private/ssh 'sudo -n env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python -B /tmp/instacast-server-source-20261003/tools/queue_admission_mysql_regression.py --source-recovery'
```

Before deployment, the exact migration rehearsal command was:

```sh
.codex/private/ssh 'sudo -n env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python -B /tmp/instacast-server-source-20261003/tools/source_generation_migration_rehearsal.py --baseline-db-module /home/instacast/domains/transcript.instacast.ch/app/db.py'
```

After deployment, point `--baseline-db-module` to the backed-up original `app/db.py` whose hash matches the manifest's `before_sha256`. The rehearsal loads that source's definitions into the temporary database only. It tests old unique-URL enforcement, migration, unchanged existing rows, new-generation insertion, duplicate-generation rejection and repeated initialization.

Neighboring suites used the same command prefix and snapshot `tools/` directory:

- `queue_admission_regression.py`: 19 passed.
- `lifecycle_regression.py`: 56 passed.
- `audio_admission_regression.py`: 9 passed. Old expectations that different requested hashes must share/fail one episode were changed to assert separate generations with preserved old bindings.
- `server_audio_source_regression.py`: 11 passed.
- `worker_edge_cases_regression.py`: 19 passed. Existing HTTP fixture objects now explicitly identify their existing success status as HTTP200.
- `server_reliability_regression.py`: 88 passed.
- `systematic_state_regression.py`: 22 ran, 2 existing skips.
- `work_status_regression.py`: 14 passed.
- `atomic_publication_regression.py`: passed.

New suites: 13 SQLite generation cases; 12 MariaDB generation cases plus the SQLite-only migration case skipped there; 4 source-recovery cases on each backend. Test counts include inherited cases in older suites and must not be summed as unique coverage.

## Deployment handoff

`server-reliability-manifest.json` lists exactly four production paths with before/after hashes. `server-reliability.patch` is the reconstructable source delta. The stage archive path and archive hash are in the manifest. The `tests/` directory retains all new or changed test sources.

1. Compare all four live source hashes with `before_sha256`; preserve a complete DB and source backup.
2. Verify the real queue, stop API admission, recheck the queue, then stop the worker for this worker/schema change. Do not interrupt accepted work without preserving its claim/checkpoint lifecycle.
3. Install only the four manifest files with the service owner's permissions. Verify installed file hashes.
4. In a fresh service-user Python process with the production DB environment loaded privately, run `from app.db import init_db; init_db()`. The API and worker remain stopped during the index migration.
5. Verify pre-existing episode/job/request IDs and states are unchanged and every old episode has generation 0; verify the new composite index and absence of the obsolete single-URL index. Re-run initialization to confirm idempotence if required by deployment validation.
6. Start worker and API; verify service states, public health, authenticated schema revision and the final user-flow behavior. Record actual deployment outcomes separately; the prepared backend tests do not claim deployment success.
