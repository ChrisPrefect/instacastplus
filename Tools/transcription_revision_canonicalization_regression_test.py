#!/usr/bin/env python3
"""The paid analysis must use the exact cue timeline committed to SRT."""

import hashlib
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def swift_revision(cues: list[tuple[float, float, str]]) -> str:
    data = bytearray(b"instacast-transcript-revision-v1")
    data.extend(struct.pack(">Q", len(cues)))
    for start, end, text in cues:
        data.extend(struct.pack(">d", start))
        data.extend(struct.pack(">d", end))
        encoded = text.encode()
        data.extend(struct.pack(">Q", len(encoded)))
        data.extend(encoded)
    return hashlib.sha256(data).hexdigest()


def float32(value: float) -> float:
    return struct.unpack(">f", struct.pack(">f", value))[0]


def srt_roundtrip_milliseconds(value: float) -> float:
    # Production formatSRTTime truncates the positive fractional part to ms.
    return int(value * 1000) / 1000


in_memory = [(float32(1.23), float32(4.56), "Canonical cue")]
persisted = [
    (
        srt_roundtrip_milliseconds(in_memory[0][0]),
        srt_roundtrip_milliseconds(in_memory[0][1]),
        in_memory[0][2],
    )
]
require(
    swift_revision(in_memory) != swift_revision(persisted),
    "The regression fixture no longer proves the Float32-to-SRT revision mismatch.",
)
require(
    swift_revision(persisted) == swift_revision(list(persisted)),
    "The persisted SRT timeline is not revision-stable.",
)

pipeline = QUEUE.split("// Step 4: semantic episode analysis", 1)[1].split("// Done!", 1)[0]
require(
    "persistedTranscriptCues = try await self.loadCuesForChapterGeneration" in pipeline
    and "from: persistedTranscriptCues" in pipeline,
    "Full-pipeline analysis still hashes in-memory Float cues instead of the committed SRT cues.",
)
require(
    pipeline.find("persistedTranscriptCues = try await self.loadCuesForChapterGeneration")
    < pipeline.find("generateSemanticArtifacts"),
    "The paid semantic request starts before the canonical SRT timeline is reloaded.",
)

print("Transcript revision canonicalization regression checks passed.")
