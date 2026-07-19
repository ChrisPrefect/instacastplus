#!/usr/bin/env python3
"""Pins automatic intent/model revalidation at both paid-work boundaries."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


require(
    "private func revalidatedAutomaticRuntimeIntent" in QUEUE
    and "automaticProcessingDecision(for: episode)" in QUEUE,
    "Automatic queue items do not re-read their current Core Data feed/subscription intent.",
)

runtime_intent = QUEUE.split("private func revalidatedAutomaticRuntimeIntent", 1)[1].split(
    "private func", 1
)[0]
require(
    "ICDownloadableModelStore.selectedChapterModelCanGenerate()" in runtime_intent
    and "ICDownloadableModelStore.selectedChapterModelUnavailableReason()" in runtime_intent
    and "supportsReliableAutomaticAnalysis" not in runtime_intent
    and "hasOpenAIAPIKey" not in runtime_intent,
    "Runtime automatic analysis does not revalidate the user's currently selected provider and credentials.",
)

process_next = QUEUE.split("private func processNext()", 1)[1].split(
    "guard let item = item, let audioURL", 1
)[0]
require(
    "revalidateAutomaticCandidateBeforeStart(candidate)" in process_next,
    "A persisted automatic candidate can start without revalidating current settings.",
)
require(
    "candidate.shouldGenerateAnalysis = runtimeIntent.analyze" in process_next
    and "candidate.chapterOnly" in process_next
    and "runtimeIntent.transcribe || runtimeIntent.analyze" in process_next,
    "Candidate revalidation does not update full-job analysis intent or reject stale chapter-only/no-op jobs.",
)

semantic_request = QUEUE.split("private func generateSemanticArtifacts", 1)[1].split(
    "private func verifyAnalysisTranscriptRevision", 1
)[0]
existing_position = semantic_request.index("existingGeneratedChapters(")
revalidation_position = semantic_request.index("revalidateAutomaticAnalysisImmediatelyBeforeRequest")
request_position = semantic_request.index("chapterGen.analyzeEpisodeAsync(")
require(
    existing_position < revalidation_position < request_position,
    "Automatic intent is not revalidated immediately after preparation and before the paid semantic request.",
)
require(
    "automaticItem: item" in QUEUE,
    "Automatic full and chapter-only jobs do not carry their runtime identity to the paid-request gate.",
)

print("Automatic runtime intent revalidation regression checks passed.")
