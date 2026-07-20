"""Regression checks for the Bit-Rauschen transcription failures reported 20 July 2026."""

import json
import os
from pathlib import Path
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
BACKEND = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
QUEUE_UI = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
EPISODES_UI = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise SystemExit(f"Unterminated function: {signature}")


# A sponsor read from 90-150 crosses the publisher boundary at 120. Overlaying
# it produces two pieces, but the player chapter list must contain one sponsor
# chapter spanning the whole read. Different adjacent sponsor titles stay split.
overlay = function_body(CHAPTERS, "@objc func chaptersByOverlayingSponsors(")
coalescer = function_body(CHAPTERS, "private static func coalescedSponsorOverlayChapters(")
require(
    "coalescedSponsorOverlayChapters(result)" in overlay
    and "previous.isSponsor" in coalescer
    and "chapter.isSponsor" in coalescer
    and "previous.title == chapter.title" in coalescer
    and "previous.end" in coalescer
    and "chapter.start" in coalescer
    and "Sponsor overlay boundary fragments coalesced" in coalescer,
    "A sponsor read crossing a publisher chapter boundary is still emitted as duplicate adjacent sponsor chapters.",
)


# Official Bit-Rauschen 2026 episode transcript fixture. The public Podigee
# JSON/VTT contains 741 timed cues, of which exactly one cue has zero duration:
# 508.56 -> 508.56. One malformed cue must not erase the other 740 real cues.
# Source: https://main.podigee-cdn.net/uploads/u13959/70aab8c0-e635-4455-bed1-9ec85af49d89.json
bit_rauschen_fixture = [
    (485.919, 492.46, "Und wenn ich das dann da hoch rechne, dann komme ich ungefähr so auf Eins Komma zwei bis eins Komma sechs Terabyte Sekunde."),
    (493.06, 508.32, "Also so ein dicker Server Prozess Server mit zwei Prozessoren und wirklich alle Rahmenkanäle bestückt kommt auf ungefähr dasselbe was ein so ein winziger HBM Stack alleine kann, also in der Größenordnung von eins Komma"),
    (508.56, 508.56, "x"),
    (508.86, 509.76, "Terabyte Sekunde."),
    (509.979, 512.799, "Das ist ja schon mal eine ganz schöne Speicherkompression."),
]
usable_fixture = [cue for cue in bit_rauschen_fixture if cue[2].strip() and cue[1] > cue[0]]
require(len(usable_fixture) == 4, "The Bit-Rauschen malformed-cue fixture is invalid.")

if os.environ.get("RUN_LIVE_BIT_RAUSCHEN_REFERENCE_TEST") == "1":
    transcript_url = (
        "https://main.podigee-cdn.net/uploads/u13959/"
        "70aab8c0-e635-4455-bed1-9ec85af49d89.json"
    )
    with urlopen(transcript_url, timeout=30) as response:
        live_cues = json.load(response)
    live_valid = [
        cue
        for cue in live_cues
        if isinstance(cue.get("start"), (int, float))
        and isinstance(cue.get("end"), (int, float))
        and cue["end"] > cue["start"]
        and str(cue.get("text", "")).strip()
    ]
    live_invalid = [cue for cue in live_cues if cue not in live_valid]
    require(len(live_cues) == 741, "The live Bit-Rauschen reference cue count changed.")
    require(len(live_valid) == 740, "The live Bit-Rauschen valid cue count changed.")
    require(
        live_invalid == [{"start": 508.56, "end": 508.56, "text": "x"}],
        "The live Bit-Rauschen malformed cue no longer matches the regression fixture.",
    )
    require(
        max(cue["end"] for cue in live_valid) == 4302.1,
        "The live Bit-Rauschen transcript timeline end changed.",
    )
normalizer = function_body(QUEUE, "private func normalizeTranscriptCues(")
require(
    "rejectedCueCount" in normalizer
    and "continue" in normalizer
    and "Podcast transcript cues normalized" in normalizer
    and "return []" not in normalizer.split("for cue in sorted", 1)[1].split("return normalized", 1)[0],
    "One malformed external transcript cue still rejects the complete timed transcript.",
)


# Whisper segment boundaries are model-internal and may contain a sentence plus
# the first word of the next speaker. Final persisted cues must be aligned to
# sentence endings, carrying an unfinished suffix into the following section.
post_process = function_body(ENGINE, "private func postProcessCues(")
sentence_alignment = function_body(ENGINE, "private func sentenceAlignedTranscriptCues(")
require(
    "sentenceAlignedTranscriptCues(timelineCues)" in post_process
    and "NLTokenizer(unit: .sentence)" in sentence_alignment
    and "isCompleteSentence" in sentence_alignment
    and "pendingText" in sentence_alignment,
    "Transcript sections are still based on arbitrary Whisper segment boundaries instead of complete sentences.",
)


# The crash log ends during a single 1,800-second inference, and the next launch
# records repeated memory warnings around 3 GB. Bound each committed Whisper
# inference/checkpoint slice to five minutes; the full episode still continues
# slice by slice with the existing persisted overlap/checkpoint mechanism.
require(
    "maxTranscriptionSliceDuration: Double = 5 * 60" in BACKEND,
    "Whisper still feeds 30 minutes into one inference and exceeds the measured memory budget.",
)


# An explicit manual transcription request replaces a terminal failed row for
# that episode before duplicate rejection. Active work must remain protected.
enqueue = function_body(QUEUE, "private func enqueueJob(")
require(
    "replaceFailedManualItem" in enqueue
    and "!automaticallyScheduled" in enqueue
    and "!chapterOnly" in enqueue
    and "item.status == .failed" in enqueue
    and enqueue.find("replaceFailedManualItem") < enqueue.find("already in queue"),
    "Manual transcription is still blocked by the old failed chapter-generation row.",
)
transcribe_action = function_body(EPISODES_UI, "- (void) _transcribeEpisode:")
require(
    "enqueueWithEpisodeHash" in transcribe_action
    and "_showTranscriptionToast" in transcribe_action,
    "A successful context-menu transcription request no longer offers the transcription-queue overlay.",
)


# Chapter-only runs need the same per-episode log lifecycle as transcription,
# including the exact external transcript error. Failed rows expand to the
# complete error text instead of silently clipping it at two lines.
generate = function_body(QUEUE, "@objc func generateChapters(")
chapter_task = function_body(QUEUE, "private func startChapterGenerationTask(")
require(
    "TranscriptionLogger.shared.resetLog" in generate
    and 'phase: "queued"' in generate,
    "Chapter-only jobs still start with an empty per-episode log.",
)
require(
    'phase: "error"' in chapter_task
    and "Podcast-Transkript konnte nicht verwendet werden" in chapter_task
    and "detailedErrorMessage" in chapter_task,
    "External transcript validation failures are still absent from the episode log.",
)
require(
    "cell.showsErrorStatus = item.status == ICTranscriptionStatusFailed" in QUEUE_UI
    and "heightForRowAtIndexPath" in QUEUE_UI
    and "boundingRectWithSize" in QUEUE_UI,
    "Failed transcription rows still truncate the actual error text.",
)


print("User-reported transcription pipeline regression checks passed.")
