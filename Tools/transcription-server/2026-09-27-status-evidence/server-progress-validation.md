# Server work/status implementation and evidence

Source: freshly fetched production files; baseline hashes in `server-source-baseline.json`. Owned before/after hashes in `server-progress-source-inventory.json`. Implementation path: `.codex/private/server-status-20260927`. This document is a verification record, not a production deployment claim.

## Actual changes

- `jobs.work_json` stores the worker's actual heartbeat, phase start and measurements under the current claim token. Arbitrary API/admin/episode writes cannot make a dead worker look current. A new claim clears previous throughput observations; the prior owner remains fenced out.
- `episode.work` identifies queued/running/paused/retrying/recovering/complete/stopped work independently from processing phase. A running claim requires a valid lease and a worker heartbeat no older than30seconds. Expiry suppresses the active-work claim and estimate.
- Queue rank uses the actual transcription queue order (priority, creation time, ID), excluding jobs whose retry time has not arrived. Rank counts waiting transcription jobs, not occupied workers or feed-scan jobs.
- Download measurements use bytes from the real supervised downloader; unknown Content-Length has no denominator or estimate. ASR measurements count only completed logical chunks. First-pass segment positions are intentionally not counted as final, because VAD gap recovery can still follow them. Overlap/context audio is excluded.
- Per-phase remaining time is derived only from observed advancement and elapsed time in the same claim/phase. Checkpoint reuse is the starting point, never credited as fresh throughput. There are no weighted overall percentages, queue wait forecasts, analysis completion fractions or invented total-time estimates.
- Healthy status responses now advertise5seconds instead of15. The existing budget formula expands to450clientreads/minute and4500IPreads/minute; tokenlimit12000 still covers the latter. Paused service retries remain300seconds. Actual running API/worker processes had no environment overrides; see `live-polling-overrides.jsonl`.
- Public provider failures retain stable machine-readable reason codes but no longer instruct customers to log an operator in or alter billing/configuration. Detailed runtime diagnostics remain stored privately.
- Mandatory MariaDB validation exposed a real concurrent-first-read deadlock(1213). Expired-window cleanup now commits before the atomic counter transaction starts. The upsert/write-lock/counter limit remains intact; no retry loop masks the defect.

## Test commands and environment

Tests run with the existing installed Python dependencies, a disposable copy at `/tmp/instacast-status-20260927-progress`, temporary SQLite stores and random disposable MariaDB databases. No production DB environment is loaded. MariaDB helper reads administrator credentials internally and never outputs them; it asserts the selected test database and removes that database afterwards.

From the disposable copy:

```sh
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/work_status_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/queue_admission_mysql_regression.py --work-status
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/rate_limit_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/queue_admission_mysql_regression.py --rates
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/audio_admission_regression.py
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/queue_admission_mysql_regression.py --audio-admission
sudo env INSTACAST_DB_BACKEND=sqlite /home/instacast/domains/transcript.instacast.ch/.venv/bin/python tools/queue_admission_mysql_regression.py --reliability
```

`work_status_regression.py` uses the actual ASGI HTTP routes, queue/claim and progress methods; it also downloads2MiB+71bytes through a real loopback HTTP server and supervised worker child. Another test starts a real subprocess that publishes an ASR progress file, and the actual supervisor persists that data before HTTP retrieval. Only expensive inference/external-provider readiness and controlled clock/failure boundaries are fixture-controlled. For HTTP JSON evidence, set `WORK_STATUS_EVIDENCE=/tmp/work-status-http-evidence.jsonl`; the retained export is in this directory.

## Proof sequence and results

- `progress-before.log`: original API lacks `work`, worker rejects measured arguments, ASR writer lacks completed seconds.
- `provider-copy-before.log` and `budget-copy-before.log`: raw operational instructions leak into customer status; failure reason is missing.
- `polling-before.log`: actual HTTP response15seconds violates the required maximum5seconds; `polling-after.log` passes after the config change.
- `rate-concurrency-before.log`: synchronized actual MariaDB counter transactions deterministically raise1213 instead of admitting one call and limiting the other. `progress-rates-fixed-*` proves all4rate tests onSQLite/MariaDB and a further run of the exact concurrency case pass.
- Work contract:14SQLite tests pass;13MariaDB work tests passed before the5secondchange, and the added14th polling/budget contract passed separately onMariaDB. This includes additive migration preserving every existing job field and obsolete-claim rejection.
- Audio identity gates pass onSQLite andMariaDB. The mismatch path remains blocked before duration/ASR; matching/shared requests preserve their existing behavior.
-51MariaDB reliability cases pass. The88SQLite reliability suite's original overlapping-request test was coupled to the removed synchronous feed call; root updated its injection to the actual transaction boundary while preserving all asserted identity/state invariants and reran the suite.
- Neighboring queue admission, phase presentation, pipeline checkpoint resume, realSIGTERM/SIGKILL restart, worker edge cases, provider polling and capacity-policy tests pass. Logs and command/elapsed/exit-code JSON are retained here.

This is backend integration/lifecycle evidence. It is not a physical-device flight-mode test or fresh paid-model end-to-end run. Production authentication was separately found revoked by root; these tests do not bypass it, submit production jobs or alter credentials.
