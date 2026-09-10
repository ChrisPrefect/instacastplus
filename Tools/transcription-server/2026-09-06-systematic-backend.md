# S1 backend reliability implementation

Source: `/Users/Chris/Developer/instacastplus/.codex/private/server-src`. Testing: `/tmp/instacast-admission-regression` on the server, using disposable SQLite directories and disposable MariaDB databases. No production writes, jobs, deployments, ASR inference, or provider calls were performed by this packet.

## Final behavior and cause

- Ordinary episode/podcast admission cannot overwrite a canceled/deleted legacy interest. The terminal transition check now lives in `service.store_client_request`, so every ordinary writer shares it. Automatic episode/feed enqueue also cannot reset a failed generation's attempt budget.
- `episodes.terminal_error` preserves the actual failure after failed-job retention. Existing retained errors are copied during migration; already-lost historical evidence is not invented.
- Retryable processing failures persist `jobs.next_attempt_at`. Claims select only due work, and successful claims clear that timestamp. Source Retry-After seconds/date is retained; values outside the documented0–86400-second metadata range become `invalid_retry_metadata`. Missing hints use bounded exponential retry (30–1800s), within the same max-attempt job. Shared `service.job_error` now controls worker permanence too, including HTTP400/413; public permanent failures no longer secretly retry.
- Each new transcription job binds `jobs.source_url`. A fresh explicit generation uses the supplied current URL; updating a feed alias cannot rotate an already accepted active source. This does not infer equal audio from aliases or fabricate historical model/audio provenance.
- MariaDB URL uniqueness is SHA256 of the entire URL, replacing512-character unique prefixes. Existing URL reads/writes use the generated index; an EXPLAIN regression first demonstrated that ordinary TEXT equality lost its usable index after migration. Episodes, aliases and podcast lookups are covered. Production URL columns were independently confirmed binary by root; case-sensitive paths remain distinct.
- Complete ASR output embeds exact audio hash, decoding/chunk options and producer implementation hashes. The ASR producer publishes the completed raw-file checksum marker before returning or removing chunk work. The worker accepts only a matching complete set. Historical unproven raw results are recomputed from preserved audio; provenance is never backfilled by assumption.
- All12 production AI checkpoint readers must provide full upstream input data. Checkpoints bind its full SHA, audio/raw source, actual provider/model, configured endpoint and prompt implementation. Changed input/model or unproven historical checkpoint is rejected. No optional no-input reuse path remains. Metadata is attached only when the inference's returned provider/model matches the expected configuration.
- Ready/failed transition and webhook outbox creation share one DB transaction. An outbox insertion failure rolls back the terminal transition; duplicate completion cannot create another event. Post-success maintenance exceptions do not turn a completed job into a processing retry. This is transactional event creation, not a claim of exactly-once external HTTP delivery.
- Schema revision is2026-09-06.1 and advertises retry maximum86400 plus the25MiB artifact bound. Worker feed fetch uses root's bounded, cancelable RSS transport.

## Owned final files

Production code:

1. `app/main.py`
2. `app/service.py`
3. `app/worker.py`
4. `app/db.py`
5. `app/checkpoint_provenance.py` — new, required by both worker and ASR tool
6. `tools/transcribe_podcast_parallel.py`

Tests:

7. `tools/systematic_state_regression.py` — new
8. `tools/queue_admission_mysql_regression.py`
9. `tools/server_model_regression.py`
10. `tools/pipeline_resume_regression.py`
11. `tools/api_contract_v3_regression.py`

Root separately owns final rss.py/config.py/artifact_contract.py, transport/artifact tests and API documentation. Their final versions were synchronized to staging; do not replace them with an earlier archive.

## Migration and rollback

With API and both workers stopped and after root's source/database backup, run the normal `app.db.init_db()` once using the deployed environment. It is idempotent. Additions:

| Table | Column | Type / meaning |
|---|---|---|
| episodes | terminal_error | TEXT, retained structured/original terminal cause |
| episodes | latest_source_url | TEXT, most recently observed supplied feed URL |
| jobs | source_url | TEXT, immutable accepted-generation source |
| jobs | next_attempt_at | TEXT, UTC ISO due timestamp |
| episodes | episode_url_sha256 | stored generated CHAR(64), SHA2(episode_url,256) |
| episode_aliases | url_sha256 | stored generated CHAR(64), SHA2(url,256) |
| podcasts | feed_url_sha256 | stored generated CHAR(64), SHA2(feed_url,256) |

Unique indexes installed: `uniq_episodes_full_url`, `uniq_episode_aliases_full_url`, `uniq_podcasts_full_url`. Only after the new unique index exists, drop corresponding old unique prefix indexes. `idx_guid` and alias episode index are unchanged. Existing job sources are backfilled from their historical canonical episode URL, matching prior execution behavior; this is source-URL lineage, not an assertion about historical audio bytes.

The migration was tested against a populated disposable MariaDB old-prefix schema with these new columns removed, then run twice. Existing failure/source records remained correct and formerly colliding long URLs became independently admissible.

Rollback to previous source is structurally compatible while leaving the additive columns/full-hash indexes. Do not blindly reintroduce512-prefix uniqueness after accepting formerly colliding URLs; it can no longer be satisfied. Root owns any restore decision. Prior code would also restore its previous retry/cache behavior, so code rollback is not a reliability-equivalent state.

## Validation and evidence limits

Python executable used: `/home/instacast/domains/transcript.instacast.ch/.venv/bin/python`, cwd `/tmp/instacast-admission-regression`. No test invokes the production database. The MariaDB runner reads host administrator credentials internally without printing them, asserts the selected random test database, and drops only that database in `finally`.

Commands:

```sh
python tools/systematic_state_regression.py
python tools/queue_admission_mysql_regression.py --systematic
python tools/server_reliability_regression.py
python tools/worker_edge_cases_regression.py
python tools/pipeline_resume_regression.py
python tools/api_contract_v3_regression.py
python tools/atomic_publication_regression.py
python tools/podcast_contract_regression.py
python tools/worker_restart_process_regression.py
python tools/feed_transport_regression.py
python tools/artifact_resource_regression.py
```

The server-model status fixture is separately executable without unavailable production artifact fixtures:

```sh
python -c 'import sys; sys.path.insert(0,"tools"); import server_model_regression as t; print(t.run_status_regression())'
```

Results at latest verification: final systematic22 tests passed (20 runtime passes,2 MariaDB-only skips); full MariaDB57 passed including inherited lifecycle/admission tests and all migration/query-plan checks. Final shared HTTP classification changes were subsequently verified separately on MariaDB. Final reliability88 and edge19 were rerun after that classifier change and passed. Pipeline12, API4, atomic publication1, podcast contract2, actual SIGTERM/SIGKILL process restart2, bounded feed9 and artifact resource2 passed. Reliability88 and edge19 include repeated inherited cases; do not sum these into a unique coverage count.

The full `server_model_regression.py` artifact half cannot run in this staging copy: historical `bits-2026-07-06-1013/ads.json` fixture is absent. Its isolated status/claim/retry/terminal function passes. Root independently checked actual ready production artifacts; this packet does not claim that historical artifact fixture passed.

| Failure boundary | Evidence now | Still not proved by these tests |
|---|---|---|
| Membership terminal × episode/podcast writers | Runtime cancellation with another owner, failed before fix; existing lifecycle suite | Every network-ack-loss × owner-restore combination |
| Failure/retry/retention | Runtime source503 due time, reboot init, exhausted scan, retained no_speech, permanent HTTP400/413 | Every clock jump and every DB disconnect instant |
| Full URL identity | Real MariaDB old-schema migration, prefix collision, path case, three EXPLAIN plans | SHA collision resistance is a cryptographic assumption |
| Source generation | Runtime active source unaffected by alias refresh; new explicit job uses renewed URL | Remote server serving changed bytes under the same URL before download |
| ASR completion | Real exporter control flow with deterministic ASR result; marker exists before worker follow-up; wrong identity rejected | Host power loss and filesystem fsync guarantees; every ENOSPC instruction boundary |
| AI checkpoint | Runtime mandatory input binding, model/input mismatch, exact match reuse; all production callers inspected | Provider success before durable usage/checkpoint write can still cost another call after crash; no provider idempotency guarantee |
| Completion event | Runtime outbox rollback and duplicate finish, plus prior claim/publication fencing tests | Exactly-once webhook delivery; crash after receiver processed but before delivery receipt |
| Worker restart | Real SIGTERM and SIGKILL/new claim with source/checkpoint preservation | Full machine power cut and every subprocess instruction boundary |

These results are focused state-machine/failure-injection evidence, not a250-real-client load test or a proof of semantic sponsor quality over arbitrary languages/podcasts.
