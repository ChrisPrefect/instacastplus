#!/usr/bin/env python3
"""Generated playback chapters must never become publisher CDChapter rows.

Regression scenario: Core Data has no chapters, but the episode already has a
generated analysis JSON when it is played for the first time. Playback may use
that generated timeline, while AudioSession may persist only the parser's raw
embedded chapters (if any).

If the user switches from episode A to B while A's asynchronous metadata parse
is in flight, A's callback must not publish chapters into B's playback/KVO state.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method {signature!r}")
    end = source.find("\n- (", start + 1)
    return source[start:end] if end > start else source[start:]


audio_session = (ROOT / "Classes" / "AudioSession.m").read_text()
playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()

store_observer = method_body(audio_session, "- (void) _observePlaybackForStoringChapters")
start_loading = method_body(playback_manager, "- (void) _startLoadingChapters")

require(
    "embeddedChaptersForPersistence" in store_observer,
    "AudioSession must use an explicitly publisher-owned chapter source for CDChapter persistence.",
)
require(
    "[pman.chapters enumerateObjectsUsingBlock" not in store_observer,
    "AudioSession still persists the composed playback timeline, which may be generated AI/sponsor data.",
)
require(
    "pman.chapters.count > 0" in store_observer,
    "A KVO clear must not persist stale embedded provenance when no playback timeline is loaded.",
)

completion_index = start_loading.find("loadAsynchronouslyWithCompletionHandler")
require(completion_index >= 0, "PlaybackManager must parse embedded metadata asynchronously.")
completion = start_loading[completion_index:]
raw_chapters_index = completion.find("parser.metadataAsset.chapters")
generated_index = completion.find("loadChaptersFor:")
persistence_index = completion.find("embeddedChaptersForPersistence =")
playback_commit_index = completion.find("self.chapters = chapters;")

episode_hash_capture_index = start_loading.find(
    "NSString* episodeHash = self.playingEpisode.objectHash"
)
identity_comparison_index = completion.find(
    "[self.playingEpisode.objectHash isEqualToString:episodeHash]"
)
stale_callback_return_index = completion.find("return;", identity_comparison_index)
require(
    0 <= episode_hash_capture_index < completion_index,
    "The metadata parse must capture its originating episode identity before it starts.",
)
require(
    0 <= identity_comparison_index < stale_callback_return_index < persistence_index,
    "A stale metadata callback can publish episode A's chapters after playback moved to episode B.",
)
require(
    "episodeHash.length == 0" in completion[:identity_comparison_index],
    "An empty episode hash must not be accepted as a metadata ownership identity.",
)
require(
    identity_comparison_index < generated_index
    and identity_comparison_index < playback_commit_index,
    "The callback must verify episode ownership before reading or publishing chapter state.",
)

require(
    raw_chapters_index >= 0 and persistence_index >= 0,
    "PlaybackManager must retain the parser's raw embedded chapters as persistence provenance.",
)
require(
    persistence_index < generated_index,
    "Publisher persistence provenance must be captured before generated chapters replace the playback timeline.",
)
require(
    persistence_index < playback_commit_index,
    "Publisher chapter provenance must be ready before the observable playback chapter update.",
)

persistence_statement = completion[persistence_index:completion.find(";", persistence_index) + 1]
require(
    "parser.metadataAsset.chapters" in persistence_statement,
    "Only raw embedded parser chapters may be exposed for CDChapter persistence.",
)
require(
    "metaChapters" not in persistence_statement and "chapters" not in persistence_statement.replace("parser.metadataAsset.chapters", ""),
    "The generated/composed playback timeline leaked into publisher persistence provenance.",
)

print("playback generated-chapter persistence regression checks passed")
