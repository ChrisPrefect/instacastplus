"""Whisper slice boundaries must commit a strict, non-overlapping SRT timeline."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
BACKEND = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def function_body(source: str, signature: str, next_signature: str) -> str:
    start = source.find(signature)
    end = source.find(next_signature, start + len(signature)) if start != -1 else -1
    require(start != -1 and end != -1, f"Could not locate {signature!r}.")
    return source[start:end]


def normalize_fixture(cues: list[tuple[float, float, str]]) -> list[tuple[float, float, str]]:
    """Executable contract mirrored by the Swift timeline normalizer."""
    normalized: list[tuple[float, float, str]] = []
    for start, end, text in sorted(cues, key=lambda cue: (cue[0], cue[1])):
        if not normalized or start >= normalized[-1][1]:
            normalized.append((start, end, text))
            continue

        previous_start, previous_end, previous_text = normalized[-1]
        if text == previous_text:
            normalized[-1] = (previous_start, max(previous_end, end), previous_text)
        elif end <= previous_end:
            normalized[-1] = (
                previous_start,
                previous_end,
                f"{previous_text} {text}",
            )
        else:
            normalized.append((previous_end, end, text))
    return normalized


# The first 30-minute Whisper slice owns a cue through 1800s. The next slice
# reloads five seconds of context and may return a distinct cue beginning at
# 1799.6s. Its text must survive, but the shared 0.4s cannot be persisted twice.
fixture = [
    (1798.0, 1800.0, "Text vor der Slice-Grenze."),
    (1799.6, 1802.0, "Text nach der Slice-Grenze."),
]
normalized_fixture = normalize_fixture(fixture)
require(
    "transcriptionSliceOverlap: Double = 5" in BACKEND
    and "sliceStart - WhisperKitBackend.transcriptionSliceOverlap" in BACKEND
    and "sliceStart - 0.5" in BACKEND,
    "The regression fixture is no longer tied to WhisperKit's overlapping long-audio slices.",
)
require(
    normalized_fixture
    == [
        (1798.0, 1800.0, "Text vor der Slice-Grenze."),
        (1800.0, 1802.0, "Text nach der Slice-Grenze."),
    ],
    "The synthetic Whisper slice fixture no longer proves deterministic overlap clipping.",
)
require(
    [cue[2] for cue in normalized_fixture] == [cue[2] for cue in fixture],
    "Whisper overlap normalization loses distinct transcript text.",
)
require(
    all(
        current[0] >= previous[1] and current[1] > current[0]
        for previous, current in zip(normalized_fixture, normalized_fixture[1:])
    ),
    "Whisper overlap normalization does not produce a strict monotonic timeline.",
)

post_process = function_body(
    ENGINE,
    "private func postProcessCues(",
    "private func cleanedTranscriptText(",
)
normalizer = function_body(
    ENGINE,
    "private func normalizedTranscriptTimelineCues(",
    "private func postProcessCues(",
)

require(
    "let timelineCues = normalizedTranscriptTimelineCues(cues)" in post_process
    and "for cue in timelineCues" in post_process,
    "Final transcript post-processing still persists raw overlapping Whisper cues.",
)
require(
    "cues.enumerated().compactMap" in normalizer
    and ".sorted" in normalizer
    and "lhs.cue.start" in normalizer
    and "lhs.cue.end" in normalizer
    and "lhs.offset" in normalizer,
    "Transcript cues are not deterministically ordered by their real time boundaries.",
)
require(
    "cue.start < previous.end" in normalizer
    and "normalizedStart = previous.end" in normalizer
    and "normalizedStart < cue.end" in normalizer,
    "Partially overlapping cues are not clipped to the preceding real cue boundary.",
)
require(
    "cue.end <= previous.end" in normalizer
    and "previous.text + \" \" + cue.text" in normalizer,
    "Distinct text from a fully covered Whisper overlap is discarded instead of retained.",
)
require(
    "cue.text == previous.text" in normalizer
    and "max(previous.end, cue.end)" in normalizer,
    "Exact overlap duplicates are not coalesced without repeating their text.",
)
require(
    "Transcript cue timeline normalized" in normalizer
    and "overlapClipped" in normalizer
    and "overlapCoalesced" in normalizer,
    "Overlap repair is not visible in transcription DebugLogs.",
)

print("Whisper overlap normalization regression checks passed.")
