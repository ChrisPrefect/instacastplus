#!/usr/bin/env python3
"""Pins the 07.07. playback chapter-source fix (CLAUDE.md "Kapitel-Quellen im Playback").

PlaybackManager.chapters loads generated > embedded media > feed chapters (CDChapter/
Podlove) as fallback. Two invariants must hold:

1. The CDChapter snapshot (feedChapterFallback) MUST be built on the calling thread
   BEFORE the async parser completion — Core Data objects must never be touched from
   the parser callback (parserQueue).
2. The fallback must actually be applied when the media file has no embedded chapters,
   and the forward button must advertise the near-chapter-end skip via
   forwardSkipJumpsToNextChapter / ICSkipToNextChapterImage (SF "forward.end").
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
playback_header = (ROOT / "Classes" / "PlaybackManager.h").read_text()
controls = (ROOT / "Classes" / "PlaybackControlsViewController.m").read_text()
image_functions = (ROOT / "Classes" / "ImageFunctions.m").read_text()

start_loading = method_body(playback_manager, "- (void) _startLoadingChapters")

# --- Invariant 1: CDChapter snapshot before the async parser completion -------------
completion_index = start_loading.find("loadAsynchronouslyWithCompletionHandler")
require(completion_index >= 0, "_startLoadingChapters must load metadata asynchronously.")
snapshot_index = start_loading.find("sortedChapters")
require(
    0 <= snapshot_index < completion_index,
    "The CDChapter snapshot (sortedChapters) must be built BEFORE the parser completion.",
)
require(
    "feedChapterFallback" in start_loading[:completion_index],
    "The feed-chapter fallback array must be filled before the parser completion.",
)
completion_block = start_loading[completion_index:]
completion_code = "\n".join(
    line for line in completion_block.splitlines() if not line.strip().startswith("//")
)
require(
    "sortedChapters" not in completion_code and "CDChapter" not in completion_code,
    "Core Data chapters must not be touched inside the parser completion (threading).",
)

# --- Invariant 2: fallback is applied when the media file has no chapters -----------
require(
    "[chapters count] == 0 && feedChapterFallback.count > 0" in completion_block
    and "chapters = feedChapterFallback;" in completion_block,
    "Feed chapters must be used for playback when the media file has no embedded chapters.",
)

# --- Forward button advertises the chapter skip -------------------------------------
require(
    "- (BOOL) forwardSkipJumpsToNextChapter" in playback_header,
    "forwardSkipJumpsToNextChapter must stay part of the PlaybackManager API.",
)
require(
    "_forwardSkipTargetNearChapterEndFromTime:self.time] >= 0"
    in method_body(playback_manager, "- (BOOL) forwardSkipJumpsToNextChapter"),
    "forwardSkipJumpsToNextChapter must reflect the near-chapter-end skip target.",
)

update_images = method_body(controls, "- (void)_updateSkipButtonImages")
require(
    "forwardChapterSkipActive" in update_images and "ICSkipToNextChapterImage" in update_images,
    "The forward button must switch to the next-chapter image while the skip is active.",
)
require(
    "_updateForwardChapterSkipStateIfNeeded" in method_body(controls, "- (void) updateTimeUI"),
    "updateTimeUI must refresh the forward-button chapter-skip state every tick.",
)
require(
    "forwardSkipJumpsToNextChapter" in method_body(controls, "- (void) updateControlsUI"),
    "updateControlsUI must seed the forward-button chapter-skip state.",
)
require(
    '@"forward.end"' in method_body(image_functions, "UIImage* ICSkipToNextChapterImage"),
    'ICSkipToNextChapterImage must use the SF symbol "forward.end" (see CLAUDE.md icon table).',
)

print("playback feed-chapter fallback regression checks passed")
