# S3 playback/artifact lifecycle result — 2026-09-06

## Root cause and changes

- **Suspended audio proof survived source replacement.** Source-extracted Swift proof first reproduced `[true, true]` after real cache invalidation/SRT source A→B; it now returns `[false, false]`. Analysis cache/proof includes the paired SRT snapshot. Every proof checks its captured file identities again after the audio hash finishes.
- **Old UI cues could inherit a new same-episode proof.** Generated descriptors retain the snapshot captured before their actual background SRT read. Publication, instance/static-cache restoration and cue navigation require that exact snapshot, and navigation requires the matching Playback proof. Old/unknown/external transcripts remain readable without generated timestamp authorization.
- **Proofs were not revoked after publication.** File identities include device, inode, size and nanosecond mtime/ctime. The local audio identity is anchored when the AVAsset opens; a later replacement cannot be reauthorized for that same buffered asset. Current source/analysis/SRT identity is checked before generated automatic/manual/chapter-end/transcript timing use; mismatch removes generated timeline, revokes transcript timing and leaves publisher metadata plus the existing clear notice. Own streaming-cache completion still permits the original proven loader bytes.
- **Artifact mutations notified only at the queue tail.** Successful local/server SRT writes, analysis commits and deletion now invalidate caches and post `ICTranscriptArtifactsDidChangeNotification` immediately. Existing Manager public save signatures and queue notifications are preserved. Cold one-sided pair reads retain the previous revision gate.
- **Persisted semantic corruption was accepted.** Generated chapter loading rejects nonfinite, negative, reversed, overlapping and CMTime-overflow intervals; verified publication checks the last end against exact AVAsset duration (not PlaybackManager's floored display duration). Matching-hash local checkpoints now require finite, ordered, nonoverlapping cues within actual duration and a resume timestamp equal to the last cue end; invalid checkpoints restart transcription without mixing cues.
- **Widget index referred to an old timeline.** Each published playback timeline has a random identifier. Widget snapshot and action carry it; current index is resolved only for the identical timeline. Missing/old identities do not seek. A stored publisher-only snapshot without a live timeline disables chapter buttons. No index-only compatibility fallback remains.

## Focused proof matrix

| Transition | Evidence |
|---|---|
| Hash suspended; SRT/source/cache invalidated | Actual Swift verifier runtime, red before fix / green after |
| Same path atomically replaced; missing snapshot | Actual stat helper runtime |
| Same audio URL, changed bytes; matching/missing source | Existing real Swift SHA runtime remains green |
| Analysis identity differs from SRT identity | Existing actual Swift verifier runtime remains green |
| Old displayed cue snapshot with fresh proof | Actual ObjC cue guard runtime rejects |
| File replacement after successful proof | Actual ObjC guard revokes published proof |
| Old widget episode/timeline/missing identity/bad index | Actual extracted ObjC action branch runtime rejects; current action succeeds |
| Invalid checkpoint timestamp/overlap | Actual Swift checkpoint validator runtime rejects |
| Invalid generated interval ranges/overlap/infinity/overflow | Actual Swift validator runtime rejects |
| Current/noncurrent episode, stale callback/asset/loader/lease | Existing ObjC runtime remains green |
| Global/feed settings, start/end/adjacency/manual-tail suppression | Existing ObjC runtime remains green |
| Actual server-generated four-artifact client import contract | Real fixture Swift decoding/SRT/artifact validation remains green |
| Hidden UI cache restoration/background reads | Source-aware guards + actual cue guard; no new physical-device UI run |

## Validation

25 focused scripts pass (14 in `/tmp/s3-run.py`, 10 additional Engine/widget neighbors, plus semantic runtime). `swiftc -swift-version 6 -typecheck Shared/WidgetModels.swift` and `git diff --check` pass. Root owns the integrated application build and physical-device installation; none performed by this packet.

Principal commands:

```
python3 Tools/playback_artifact_freshness_runtime_test.py
python3 Tools/playback_artifact_semantics_runtime_test.py
python3 Tools/playback_artifact_lifecycle_regression_test.py
python3 Tools/playback_autoskip_live_settings_runtime_test.py
python3 Tools/transcription_audio_identity_runtime_test.py
python3 Tools/server_sponsor_e2e_client_runtime_test.py
```

New fixture files are source-extracted harnesses, contain no credentials and make no inference calls. Full test logs reside in `/tmp/<script-name>.log`.

## Explicit limits

This proves deterministic lifecycle/source guards, not perfect probabilistic sponsor detection. A changed audio file requires a fresh playback asset before timing can be reauthorized. Identity checks are metadata-only; audio hashing remains asynchronous and incremental. An external file edit can leave old text readable with invalid timing until reload. No auto-install or production server mutation was performed.

## S3b final integration extension

- Real replay first reproduced acceptance of two server cues overlapping by exactly 1 ms (`0…1.000`, `.999…2.000`). Canonical server parsing now allows no overlap; publisher/local parsing keeps its existing tolerance. Root's real fixture now rejects all 10 corruption cases.
- Actual Release-optimized 4,308,894-byte / 43,200-cue parser blocked a scheduled MainActor heartbeat for 257.7 ms. SRT parsing plus JSON decoding/validation now run in one utility task with cancellation propagation and exact request ownership checked after await.
- The exact persisted-SRT parser was then measured at 154.3 ms in the synchronous analysis-save tail. A single-entry cache now reuses only the just-committed, already validated server cues: committed bytes must equal validated bytes, and the file snapshot must match before/after comparison and at every reuse. Replacement or episode mismatch reparses instead. The cache never grows with queue size.
- Actual `makeServerAnalysis` preparation measured 28–32 ms. Its value-only preparation now runs in a second utility task; Core Data chapter snapshots stay on MainActor, with cancellation/request fencing before publication.
- The final source-extracted actual publication tail includes `saveValidatedServerSRTData`, atomic SRT replacement, real xattrs, exact-byte/snapshot comparison, `saveAnalysisResult`, canonical revision check, JSON serialization and atomic analysis write. Final run: **11.25 ms synchronous** (2.33 ms SRT + 8.92 ms analysis); asynchronous diagnostics and real UIKit observers are not instantiated in the isolated harness. This is a measured desktop fixture bound, not an on-device timing guarantee.
- Final runtime: parser utility 257.2 ms, heartbeat 30.0 ms; analysis utility 24.0 ms, heartbeat 2.05 ms. Work remains substantial but no longer occupies the MainActor.
- Widget's only repository callsite is NowPlayingWidget. The token-bearing intent is now non-discoverable; its internal token is optional so old index-only shortcuts cannot prompt for a UUID, and still cannot seek without valid current identity.

Additional permanent validation:

```
python3 Tools/server_artifact_validation_responsiveness_runtime_test.py
python3 Tools/server_analysis_responsiveness_runtime_test.py
python3 Tools/server_artifact_commit_tail_runtime_test.py
python3 Tools/transcription_validated_snapshot_cache_runtime_test.py
python3 Tools/widget_chapter_intent_privacy_regression_test.py
```

All passed in the final focused sweep, together with the 14-script primary suite, exact interval/identity runtime tests, updated pure-method source extraction checks, Swift-6 widget-model typecheck and diff whitespace validation. Parser cancellation and post-await request ownership are pinned. Two source tests were updated only for the new `nonisolated` method declarations; their existing behavioral assertions remain.

Production is frozen. Root was notified of one final new-await fence before build: recheck episode deletion after asynchronous analysis preparation, immediately before file publication. Root owns that final integration line and the full build/device run.
