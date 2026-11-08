# Local chapter identity regression

The actual persistence/proof probe `local-chapter-probe.py` reproduced the failure
on 2026-10-03: locally saved chapter-only JSON loaded successfully, but matching
complete audio authorized the transcript and never the chapters, both immediately
and after creating a fresh generator. Evidence: `local-chapter-before.log`.

The existing app E2E imports server analysis JSON and therefore cannot exercise
the chapter-only format. A deterministic native test is necessary to exercise
the actual save/load/hash methods with source replacement at precise generation
and commit boundaries. It does not execute the local model or replace app E2E.

Before changing production code, the failure matrix is:

- Matching source: newly generated chapter-only artifacts must verify after save
  and after a fresh generator loads the persisted file.
- Different complete audio, including different bytes at the same URL, must not
  authorize chapter or transcript timing.
- Replacing the transcript text or its source identity invalidates saved chapters.
- Replacing or deleting the transcript while generation is pending must reject
  the commit and retain any prior chapter artifact.
- Identical cue text must not silently acquire a different source-audio identity.
- Legacy chapter files without recorded provenance must never acquire timing
  permission from whatever audio happens to be present today.
- Deliberately deleting only the transcript must preserve already proven chapter
  provenance; the transcript must no longer be verified.
- The current semantic artifact snapshot must resolve both chapter-only and full
  analysis files, preserving full-analysis priority and callback freshness.

Command: `python3 Tools/local_chapter_audio_identity_runtime_test.py`.
The test compiles production Swift persistence, revision, snapshot and verification
methods on macOS with actual files and actual SHA-256 hashing. Test fixtures supply
the input transcript and chapter result; assertions exercise behavior, not spelling.

## Result

`local-chapter-matrix-before.log` retains the failing production run; the same
matrix after the fix passes all 15 checks in `local-chapter-matrix-after.log`.
The original `local-chapter-probe.py` records the pre-fix save API; the maintained
regression command above includes the immutable generation input now required by
the save contract.

Chapter-only JSON now stores the cue revision and the original SRT audio hash.
The queue captures its SRT snapshot and source before generation; publication
rejects replacement or deletion instead of attaching the current audio identity.
Playback verifies the actual priority artifact, whether full analysis JSON or
chapter-only JSON. Missing legacy provenance remains unverified.

Adjacent passing commands on the same macOS host, using Swift language mode 6:

```sh
python3 Tools/playback_artifact_freshness_runtime_test.py
python3 Tools/transcription_audio_identity_runtime_test.py
python3 Tools/playback_autoskip_live_settings_runtime_test.py
python3 Tools/chapter_resume_runtime_test.py
python3 Tools/transcription_validated_snapshot_cache_runtime_test.py
python3 Tools/playback_artifact_semantics_runtime_test.py
python3 Tools/server_artifact_commit_tail_runtime_test.py
python3 Tools/server_sponsor_e2e_client_runtime_test.py
```

The server commit-tail probe measured 8.7 ms; the server artifact validator
accepted the real 28-cue fixture and rejected all 10 corruptions. A full simulator
run of local model generation is not claimed by these isolated checks.
