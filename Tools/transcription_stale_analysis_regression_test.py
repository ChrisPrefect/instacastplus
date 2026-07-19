from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


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
    raise SystemExit(f"Unterminated body: {signature}")


write_srt = function_body(ENGINE, "private func writeSRT(")
require(
    "invalidateAnalysisCache" in write_srt,
    "Committing a replacement SRT does not invalidate cached chapters and summary.",
)
require(
    "func persistedTranscriptCues(" in ENGINE,
    "The saved SRT cannot be reread for revision validation.",
)

validator = function_body(CHAPTERS, "private func validateAnalysisTranscriptRevision(")
require(
    "persistedTranscriptCues" in validator
    and "transcriptRevision(for:" in validator
    and "file.transcriptRevision" in validator,
    "Persisted analysis is not compared with the exact saved transcript revision.",
)

for signature in [
    "@objc func loadSummary(for episodeHash:",
    "@objc func loadChapters(for episodeHash:",
    "func finalizeOpenAIBackgroundJobAfterPersistedAnalysis(for episodeHash:",
]:
    body = function_body(CHAPTERS, signature)
    require(
        "validateAnalysisTranscriptRevision" in body,
        f"Stale analysis can escape revision validation in {signature}",
    )

require(
    "func hasValidAnalysis(for episodeHash:" in CHAPTERS,
    "Queue reconciliation has no revision-aware analysis validity check.",
)
restore = function_body(QUEUE, "private func loadPersistedQueue(")
require(
    "hasValidAnalysis(for:" in restore,
    "Queue restore still treats mere analysis-file existence as a completed semantic result.",
)

print("Stale analysis revision regression checks passed.")
