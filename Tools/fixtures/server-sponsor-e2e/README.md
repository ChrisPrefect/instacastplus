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
