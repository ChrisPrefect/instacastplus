#!/usr/bin/env python3
"""Publisher chapter links survive only inside their real timeline interval.

Regression scenario: a publisher chapter has an explicit duration and is followed by
an intentional gap. The generated sponsor overlay represents that gap as a neutral
non-sponsor chapter. Matching only against the next publisher start incorrectly gives
the neutral gap the preceding publisher chapter's link.
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


playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
start_loading = method_body(playback_manager, "- (void) _startLoadingChapters")

require(
    "ch.link = cdChapter.linkURL;" in start_loading,
    "The publisher chapter snapshot must retain CDChapter.linkURL.",
)
require(
    "if (!gch.isSponsor)" in start_loading
    and "feedChapterFallback" in start_loading
    and "CMTimeGetSeconds(candidate.start)" in start_loading,
    "Generated non-sponsor fragments are not matched back to their publisher chapter interval.",
)
require(
    "CMTIME_IS_VALID(candidate.end)" in start_loading
    and "CMTimeGetSeconds(candidate.end)" in start_loading,
    "Publisher-link matching ignores an explicit publisher chapter end.",
)
require(
    "gch.end <= candidateEnd" in start_loading,
    "A generated fragment can inherit a publisher link while extending beyond that publisher chapter.",
)
require(
    "CMTimeGetSeconds(nextCandidate.start)" in start_loading
    and "generatedTimelineEnd" in start_loading,
    "Open-ended publisher chapters must derive their end from the next publisher start or timeline end.",
)
require(
    "ch.link = publisherChapter.link;" in start_loading,
    "The publisher link is lost when generated sponsor chapters replace the playback timeline.",
)

print("playback generated sponsor metadata regression checks passed")
