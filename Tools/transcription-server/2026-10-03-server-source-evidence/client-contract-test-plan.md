# Client source contract — before implementation

Actual source evidence: submissionAudioSHA256 rejects absent local media before any
HTTP request. verifiedImportAudio separately rejects otherwise valid server
artifacts when the device has no complete episode. The actual App E2E is being
extended by the root task to exercise this previously omitted normal user flow.

The new contract explicitly chooses server or client audio once per request UUID.
Server source sends the episode URL and no client hash. Existing complete local
media can still create a client-bound request. Existing saved requests without a
source field retain their original client-bound semantics.

Focused isolation rationale: deterministic crash/snapshot and source replacement
boundaries cannot be induced through normal simulator UI at a chosen instruction.
The targeted runtime harness compiles the production manager methods and the real
queue model, replacing only the media and HTTP boundaries. The actual App E2E
remains the proof for uncached start, no source download, and artifact import.

Failure matrix to cover before the change:
- An uncached server-source request must send no client_audio_sha256 and must keep
  that body after loss of acknowledgement, restart and subsequent local download.
- A server-source receipt must echo the source; missing or changed source cannot
  confirm admission to a different contract.
- An old snapshot without a source field must remain client-bound and cannot use
  missing media to relax the existing request's identity.
- Server-source import still requires a valid server audio SHA and strict artifact
  revision/content checks, but requires no device audio proof.
- Client-bound import must continue rejecting missing, changed and mismatched local
  media. A present mismatching local file cannot change a server-source request.
- The saved source hash on imported SRT/analysis continues to gate timed playback;
  absence of a device download must not authorize generated timeline jumps.

Additional source-change failure matrix, recorded before its correction:
- A server-source mismatch after the first download must explain that this
  request's audio changed, never claim that a device download was compared.
- Both an episode failure envelope and HTTP 409 audio_source_mismatch must stop
  automatic polling, preserve historical admission, and allow an explicit new
  request UUID. Rechecking the terminal old UUID cannot recover this failure.
- Client-source mismatches retain their distinct downloaded-audio explanation.
Isolation rationale: normal UI cannot deterministically replace the publisher's
audio between two server downloads. The existing runtime harness exercises the
production apply/handle/retry methods with both actual error contract shapes.
