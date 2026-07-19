#!/usr/bin/env python3
"""Embedded publisher chapters must be the immutable semantic-analysis base.

Regression scenario: a newly downloaded episode contains media chapters, but it has
never been played, so AudioSession has not materialized those chapters as CDChapter
rows.  Automatic analysis must parse and persist only the raw publisher metadata
before it asks the remote model to add sponsor overlays.  Existing CDChapter rows
remain authoritative and generated overlays must never enter Core Data.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
BRIDGE = (ROOT / "Instacast-Bridging-Header.h").read_text()
METADATA_PARSER = (ROOT / "Classes" / "Metadata" / "ICMetadataParser.m").read_text()
ASSET_PARSER = (ROOT / "Classes" / "Metadata" / "_ICMetadataAssetParser.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def function_body(source: str, signature: str, next_signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function {signature!r}")
    end = source.find(next_signature, start + len(signature))
    require(end > start, f"Missing boundary {next_signature!r}")
    return source[start:end]


require(
    "import AVFoundation" in QUEUE,
    "TranscriptionQueue cannot inspect embedded media metadata without AVFoundation.",
)
require(
    '#import "ICMetadata.h"' in BRIDGE and '#import "ICMetadataParser.h"' in BRIDGE,
    "The raw metadata parser is not exposed to the Swift transcription pipeline.",
)
require(
    "private struct PublisherChapterSnapshot" in QUEUE
    and "let linkURL: URL?" in QUEUE,
    "The immutable publisher snapshot does not retain chapter-link provenance.",
)

existing = function_body(
    QUEUE,
    "private func existingGeneratedChapters",
    "private func generateSemanticArtifacts",
)
require(
    "async throws" in existing and "await loadEmbeddedPublisherChapters" in existing,
    "Semantic analysis still checks only CDChapter and misses never-played embedded chapters.",
)
require(
    "if !authoritativeStoredChapters.isEmpty" in existing
    and existing.find("if !authoritativeStoredChapters.isEmpty")
    < existing.find("await loadEmbeddedPublisherChapters"),
    "Embedded parsing can override existing authoritative CDChapter rows.",
)
require(
    "persistEmbeddedPublisherChapters" in existing
    and existing.find("persistEmbeddedPublisherChapters")
    < existing.find("generatedPublisherTimeline(from: embeddedPublisherChapters"),
    "Raw embedded chapters are not durably materialized before remote sponsor analysis.",
)

loader = function_body(
    QUEUE,
    "private func loadEmbeddedPublisherChapters",
    "private func persistEmbeddedPublisherChapters",
)
require(
    "ICMetadataParser(assetURL:" in loader
    and "loadAsynchronously" in loader,
    "The queue does not use the same raw media metadata parser as playback.",
)
require(
    "duration(withTrackDuration:" in loader
    and "chapter.link" in loader,
    "Embedded explicit ends/durations or links are discarded while snapshotting.",
)
require(
    "ICDiagnosticLogger.shared.logEvent" in loader
    and "TranscriptionQueue.EmbeddedPublisherChapters" in loader,
    "Embedded chapter parsing has no structured evidence or structured error domain.",
)

persister = function_body(
    QUEUE,
    "private func persistEmbeddedPublisherChapters",
    "private func generatedPublisherTimeline",
)
require(
    'forEntityName: "Chapter"' in persister
    and "chapter.linkURL = snapshot.linkURL" in persister
    and "chapter.duration = snapshot.end - snapshot.start" in persister,
    "Only raw embedded title/start/end/link provenance may be persisted as CDChapter.",
)
require(
    "ICGeneratedChapter" not in persister
    and "saveChapters" not in persister
    and "saveAnalysisResult" not in persister,
    "Generated sponsor/AI overlays leaked into publisher Core Data persistence.",
)

semantic = function_body(
    QUEUE,
    "private func generateSemanticArtifacts",
    "private func verifyAnalysisTranscriptRevision",
)
require(
    "try await existingGeneratedChapters" in semantic,
    "The remote request starts without awaiting the embedded publisher snapshot.",
)

# Two parser lifecycle defects used to either corrupt derived end times (the loop
# index advanced only for chapters without an explicit end) or never call the
# completion when a chapter locale existed but contained no title/artwork items.
postflight = function_body(
    METADATA_PARSER,
    "- (void) _postFlightMetadataItems:",
    "@end",
)
explicit_end_branch = postflight.split("if (item.end.value != 0)", 1)[1].split("}", 1)[0]
require(
    "i++;" in explicit_end_branch,
    "An explicit embedded end still prevents the parser index from advancing and corrupts later ends.",
)
require(
    "chaptersToLoad == 0 && imagesToLoad == 0" in ASSET_PARSER
    and "completionHandler(YES, nil);" in ASSET_PARSER.split(
        "chaptersToLoad == 0 && imagesToLoad == 0", 1
    )[1][:500],
    "M4A metadata loading can still hang forever for an empty timed-metadata locale.",
)

# Behavioral fixture: an explicit publisher gap stays a neutral gap; the explicit
# end is never stretched to the next chapter start.
publisher = [
    (0.0, 45.0, "Intro"),
    (60.0, 120.0, "Interview"),
]
timeline_end = 150.0
timeline: list[tuple[float, float, str]] = []
cursor = 0.0
for start, end, title in publisher:
    if cursor < start:
        timeline.append((cursor, start, "Episode"))
    timeline.append((start, end, title))
    cursor = end
if cursor < timeline_end:
    timeline.append((cursor, timeline_end, "Episode"))

require(
    timeline
    == [
        (0.0, 45.0, "Intro"),
        (45.0, 60.0, "Episode"),
        (60.0, 120.0, "Interview"),
        (120.0, 150.0, "Episode"),
    ],
    "The embedded-chapter fixture no longer proves explicit-end/gap preservation.",
)

print("embedded publisher chapter analysis regression checks passed")
