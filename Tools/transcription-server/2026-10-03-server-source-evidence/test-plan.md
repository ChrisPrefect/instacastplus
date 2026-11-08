# Server-owned source: failure analysis before implementation

Observed: the live API unconditionally rejects a request without a device SHA with audio_identity_required; its worker subsequently marks every NULL source hash unverified. This prevents the intended server-only URL-to-transcription flow before a job can be submitted.

User intent overrides the old precondition: server transcription must not require an iPhone audio download. Existing device-bound requests remain strict. A new explicit audio_source=server selects the source on the server; a default/explicit audio_source=client still requires the device hash.

Failure cases to exercise before production code changes:
- A server-mode request containing only the episode URL and durable UUID must be admitted through HTTP without any client audio or hash.
- Default/client requests must still reject missing or malformed device hashes before job creation.
- Invalid mode, server mode with a client hash, or server mode without UUID must be rejected explicitly.
- UUID replay must preserve source mode and URL. A mode change under the same UUID must produce409, including after first download has bound the server hash.
- First server download must be performed in the worker and persist its real SHA before ASR; a replay cannot replace that binding.
- A client-bound mismatching request must fail before ASR, including when a separate server-mode client legitimately keeps shared work running.
- A server-mode late join must bind the already verified source; client-bound late joins retain their strict comparison.
- Cancellation before and after admission must survive replay. Worker restart must preserve source selection and the bound source.
- Additive SQLite/MariaDB migration must preserve historical client-bound behavior and existing rows.

Tests: use real ASGI HTTP routes with disposable SQLite/MariaDB state. The source fixture is a real WAV served by a loopback HTTP server; production worker download, hashing, measured-duration subprocess and claim fencing run, and inference is intercepted only at its exact invocation boundary. No model inference is needed to prove whether source admission permits or prevents ASR. Root separately reproduces and validates the actual iOS flow without a cached episode. Database corruption, concurrent identities and source changes are deterministic boundary cases that cannot be safely injected into production or reliably reached through a physical-device UI.

No production database, production job, credentials or server configuration is modified by these tests. Detailed logs and HTTP observations are retained here. A passing boundary test is not described as a fresh paid-model full pipeline run.

## Swift App-Intent playback bridge follow-up (before tests)

The playback manager now retains a failed episode for readable content while releasing its player, and its Objective-C factory is explicitly imported as `shared()`. The Swift intent bridge still invokes `PlaybackManager()` and dispatches retained-episode Play directly to the released player.

Failure matrix: (1) the actual Swift getter must return the actual Objective-C factory's single object without extra initialization; (2) explicit Play after failed/non-ready retained playback must reopen via the real `AudioSession.togglePlay`; (3) Play/Pause must do the same; (4) healthy paused/playing transport remains unchanged; (5) an in-progress, nonfailed open must not be restarted; (6) no selected episode remains a no-op when no recent episode is available.

Isolation rationale: invoking Siri/Shortcuts through the simulator is not a deterministic way to hold the exact failed-player lifecycle boundary, and it cannot directly observe repeated singleton initialization. The focused executable therefore imports the production Objective-C factory declarations and compiles the actual factory method bodies, the real AudioSession toggle method, and the actual extracted Swift getter/transport methods. Only media/CoreData state and terminal play/open calls are boundary doubles. It measures object identity/initialization count and actual dispatched calls; no source-spelling assertions or reimplemented Swift decision model are used. Root separately validates real playback failure in the app.
