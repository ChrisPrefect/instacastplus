#!/usr/bin/env python3
"""Pin the documented server-transcription contract at the iOS boundary."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ServerTranscriptionManager.swift").read_text()
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated declaration: {signature}")


# A ready response is useful only when the descriptor contract itself is enforced.
artifact_definition = MANAGER.split("private struct ICServerArtifact", 1)[1].split(
    "private struct ICServerError", 1
)[0]
require(
    "let contentType: String" in artifact_definition
    and "let byteSize: Int" in artifact_definition
    and "let sha256: String" in artifact_definition,
    "Required artifact content type, byte size, and non-null SHA-256 are not decoded.",
)

download = body(MANAGER, "private func download(")
require(
    "data.count == artifact.byteSize" in download
    and 'value(forHTTPHeaderField: "Content-Type")' in download
    and "artifact.contentType" in download,
    "Artifact bytes and response content type are not checked against the descriptor.",
)

# All payloads must be decoded and cross-validated before the transcript is persisted.
artifact_import = body(MANAGER, "private func importArtifacts(")
for marker in (
    "validateServerSRTData",
    "validateServerArtifacts",
    "makeServerAnalysis",
    "saveValidatedServerSRTData",
    "saveAnalysisResult",
):
    require(marker in artifact_import, f"Server import is missing the {marker} stage.")
require(
    artifact_import.index("validateServerArtifacts")
    < artifact_import.index("saveValidatedServerSRTData")
    and artifact_import.index("makeServerAnalysis")
    < artifact_import.index("saveValidatedServerSRTData"),
    "The SRT is persisted before the JSON artifacts and combined analysis are valid.",
)
artifact_validation = body(MANAGER, "private func validateServerArtifacts(")
require(
    "chapter.start >= 0" in artifact_validation,
    "Server artifact validation accepts a negative chapter start near zero.",
)

# The API promises exact canonical cue boundaries. The client must reject deviations,
# not silently expand an imprecise interval into neighbouring editorial content.
server_analysis = body(CHAPTERS, "func makeServerAnalysis(")
require(
    "sameCanonicalMillisecond($0.start, segment.start)" in server_analysis
    and "sameCanonicalMillisecond($0.end, segment.end)" in server_analysis
    and "$0.end > segment.start" not in server_analysis
    and "$0.start < segment.end" not in server_analysis,
    "Server sponsor bounds are not matched at exact canonical SRT-millisecond resolution.",
)

# Polling is a wait state of the same live server run. It must preserve the last phase,
# progress, and elapsed-time baseline instead of presenting the item as newly queued.
apply_response = body(MANAGER, "private func apply(")
require(
    'case "queued", "running":' in apply_response
    and "schedulePoll(item" in apply_response,
    "Running server responses are not scheduled for their next poll explicitly.",
)
schedule_poll = body(MANAGER, "private func schedulePoll(")
require(
    "item.status = .queued" not in schedule_poll
    and "item.progress =" not in schedule_poll
    and "item.statusDetail =" not in schedule_poll,
    "Scheduling a poll still destroys the visible server phase or progress.",
)
request_error_handling = body(MANAGER, "private func handle(error:")
require(
    "isTransient(error)" in request_error_handling,
    "Malformed or contract-invalid API responses are retried forever as if they were temporary network failures.",
)
millisecond_comparison = body(MANAGER, "private func sameMillisecond(")
require(
    "1_000_000" in millisecond_comparison
    and "< 1_000" in millisecond_comparison,
    "Duration comparison either rejects sub-millisecond representation differences or accepts adjacent milliseconds.",
)
process_next = body(MANAGER, "private func processNext()")
require(
    "$0.status == .queued || $0.status == .transcribing" in process_next,
    "A live server item cannot resume polling while retaining its visible running status.",
)
require(
    "queuePersistenceError == nil" in process_next,
    "The manager starts another server item even though its current resume state is not durable.",
)
deferred_advance = process_next.split("defer {", 1)[1].split("}", 1)[0]
require(
    deferred_advance.index("processNext()") < deferred_advance.index("postQueueChange()"),
    "BGProcessing observes a false idle window before the next due server item starts.",
)

persisted_item = MANAGER.split("struct Item: Codable", 1)[1].split("\n    }", 1)[0]
for field in ("progress", "statusDetail", "statusStartedAt"):
    require(field in persisted_item, f"Server queue persistence loses {field} across relaunch.")

# An explicit retry must submit again. Polling the same terminal server ID forever
# can never create a new run.
manual_retry = body(MANAGER, "@objc func retryEpisodeHash")
require(
    "serverIDByItem.removeValue" in manual_retry,
    "Manual retry keeps the terminal server episode ID and can only refetch its failure.",
)

# Automatic BGProcessing must keep pending remote work scheduled and must not finish
# while the manager's URLSession request/import is still active.
require(
    "hasPendingAutomaticItems" in QUEUE,
    "Pending remote polls are not part of automatic BGProcessing scheduling.",
)
require(
    APP_DELEGATE.count("![ServerTranscriptionManager shared].isProcessing") >= 6,
    "A BGProcessing or Continued Processing grant can complete while a server poll or artifact import is still active.",
)

# Publisher chapters remain the preferred base. Existing Sponsor:-prefixed publisher
# chapters must carry sponsor metadata so overlay coalescing cannot duplicate them.
publisher_chapters = body(MANAGER, "private func publisherChapters(")
require(
    'hasPrefix("Sponsor: ")' in publisher_chapters,
    "Sponsor:-prefixed publisher chapters are imported as ordinary content.",
)
require(
    "let end = nextStart" in publisher_chapters
    and "chapter.duration > 0 ?" not in publisher_chapters,
    "Partial publisher chapter durations can clip later sponsor overlays out of the episode.",
)
require(
    "leadingFallback" in publisher_chapters,
    "Sponsors before the first partial publisher chapter are clipped out of the episode.",
)

# The server contract requires canonical HH:MM:SS,mmm timestamps. Local parsing may
# remain backward-compatible, but server imports must reject alternate punctuation
# and variable-width fields before persisting the exact bytes.
server_srt_validation = body(ENGINE, "func validateServerSRTData(")
require(
    "parsePersistedSRTDetailed(content, requiresCanonicalTimeLines: true)" in server_srt_validation,
    "Server SRT validation does not restrict canonical formatting to actual cue time lines.",
)

# Server queue durability participates in the BG task's success result just like
# the local queue. Losing a server ID or retry time must never be reported as success.
require(
    "queuePersistenceError" in MANAGER
    and "retryQueuePersistenceAfterFailure" in MANAGER
    and "serverQueuePersistenceError" in APP_DELEGATE,
    "Server queue persistence failures are swallowed by BG task completion.",
)
persistence_retry = body(MANAGER, "@objc func retryQueuePersistenceAfterFailure")
require(
    persistence_retry.index("processNext()") < persistence_retry.index("postQueueChange()"),
    "A successful persistence retry publishes an idle queue before resuming its pending work.",
)

print("Server transcription client-contract regression checks passed.")
