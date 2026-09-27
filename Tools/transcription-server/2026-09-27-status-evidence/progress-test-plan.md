# Server work contract: failure analysis before implementation

Observed: live API suppresses internal weighted progress; workers already receive byte counts and completed ASR chunks but do not publish those measurements. API phase alone cannot distinguish a live worker from a stale claim or a queued retry. A first-pass segment timestamp does not prove completion because VAD recovery still follows it.

Success: a correctly admitted request can be observed through the real HTTP contract with the actual queue/worker ownership, named phase, fresh activity, measured completed units and an explicitly phase-only throughput estimate. No global percentage or inferred total duration is created.

Failure boundaries to exercise before production edits:
- POST acceptance then GET before claim must expose queued with its actual queue rank; no claimed processing.
- Worker claim and heartbeat must expose live activity; episode-only/API updates must not refresh worker activity.
- Expired lease or stale heartbeat must suppress live claim and ETA; pause, retry, cancel and failure must not appear as working.
- Download byte counts must come from the real supervised download process; unknown length permits completed bytes but no denominator/estimate.
- ASR completed seconds must count only completed logical chunks, excluding context overlap and incomplete first-pass segments.
- ETA requires advancing observed units within the same phase and claim; restored checkpoints, phase changes, nonfinite/invalid counts or stale measurements cannot provide an ETA.
- Claim replacement must clear old metrics and prevent the obsolete owner from publishing progress.
- Existing artifact/audio identity validation, billing, provider eligibility, cancellation and retry contracts stay unchanged.

Test strategy: HTTP through the actual ASGI app and real SQLite queue/claim methods, using a disposable DB. The download proof uses a real local HTTP source and the production killable child downloader. Network-address validation is replaced only in this controlled fixture so no external host is required. The ASR proof uses the production progress writer with completed chunk artifacts; no paid inference is involved. Clock/claim expiry and invalid numeric boundaries are isolated because a full app/inference run cannot reliably induce their exact timing or corrupt measurements. These are backend integration proofs, not physical-device or paid-inference E2E results.

Environment: fresh production source fetched 2026-09-27, hashes in server-source-baseline.json. Tests run at /tmp/instacast-status-20260927-progress on the server using the installed dependency interpreter and explicit SQLite paths. No production DB environment is loaded and no production job is created.

## Newly reproduced concurrent rate-counter boundary

The mandatory MariaDB rate-limit run failed for concurrent first requests with OperationalError rather than one admission and one429. Existing test captures the exception class but omits its number. Before changing production rate limiting, the test now retains the error number and synchronizes the two cleanup statements to expose the InnoDB empty-range gap-lock/insertion boundary. SQLite cannot reproduce InnoDB gap locks; the exact same queue/API tests therefore run against a freshly-created MariaDB database with no production selection. Root-cause correction must preserve the atomic per-bucket counter, bounds, independent cancellation budgets and cleanup; no catch-and-retry path is permitted.
