These four artifacts came from the isolated `2026-09-06` German synthetic-speech
Whisper + Codex pipeline, recorded in
`Tools/transcription-server/2026-09-06-sponsor-e2e.json`.

They were copied byte-for-byte from artifact paths referenced by the read-only
SQLite database `/tmp/instacast-sponsor-e2e/isolated-state/pipeline.sqlite3` on the
test server. They contain generated test content, no customer transcript or secret.

Run `python3 Tools/server_sponsor_e2e_client_runtime_test.py` from the project root.
The test compiles the actual app Decodable types, artifact validator and strict SRT
parser under Swift 6. It checks the real result and five deliberately corrupted
variants. It does not call the network, perform inference, import into Core Data,
or exercise AVPlayer playback; separate playback and persistence tests cover those
boundaries.

`fixture.wav` is the matching synthetic input from `/tmp/instacast-sponsor-audio/fixture.wav`.
SHA-256: `92747209c31b54463fa69e40d7b29b15894a13ff00664e86ca8066112984b6d0`.
It is retained for `Tools/server_transcription_app_flow_test.py`: the complete simulator app
downloads and hashes the real audio, submits one durable request to a loopback HTTP peer,
observes each phase, and imports these exact source-bound results. Inference is replayed,
not rerun. Use only the dedicated simulator named `Server transcription flow`; the script
uninstalls its prior test app data before each run.
