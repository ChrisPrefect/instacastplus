#!/usr/bin/env python3
"""Regression contract for non-durable remote analysis lifecycle ownership."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()


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


# UIKit expiration must release the execution grant, but it must not cancel an
# already submitted one-shot request. Cancellation would discard its only result
# identity and a later retry could issue the same expensive POST again.
expiration = function_body(QUEUE, "private func beginBackgroundContinuationIfNeeded(reason:")
preserve_check = expiration.find("hasInProcessNonDurableRemoteChapterRequest")
pause_call = expiration.find('pausePipelineForBackgroundIfNeeded(reason: "background-task-expired")')
require(
    preserve_check >= 0 and preserve_check < pause_call,
    "UIKit background-time expiration still cancels an in-process non-durable remote chapter request.",
)
active_request = function_body(
    QUEUE,
    "private var hasInProcessNonDurableRemoteChapterRequest:",
)
require(
    ".generatingChapters" in active_request
    and "hasActiveNonDurableRemoteAnalysis" in active_request,
    "The expiration exception is not bound to ChapterGenerator's active one-shot request identity.",
)

analysis = function_body(CHAPTERS, "func analyzeEpisodeAsync(fromCues cues:")
require(
    "activeNonDurableRemoteAnalysisEpisodeHashes.insert" in analysis
    and "activeNonDurableRemoteAnalysisEpisodeHashes.remove" in analysis
    and "defer" in analysis
    and analysis.find("activeNonDurableRemoteAnalysisEpisodeHashes.insert")
    < analysis.find("generateRemoteJSONObject"),
    "ChapterGenerator does not track the exact lifetime of a non-durable remote analysis request.",
)
active_identity = function_body(
    CHAPTERS,
    "func hasActiveNonDurableRemoteAnalysis(for episodeHash:",
)
require(
    "activeNonDurableRemoteAnalysisEpisodeHashes.contains(episodeHash)" in active_identity,
    "The queue cannot confirm that the non-durable request is still alive in this process.",
)


# Process death is different: only a persisted official OpenAI response identity
# can be polled safely. A remote-model selection alone says nothing about whether
# retrying would create a second one-shot provider request.
crash_resume = function_body(
    QUEUE,
    "private func canAutoResumeRemoteChapterJobAfterUnexpectedTermination(",
)
require(
    "hasPersistedDurableRemoteAnalysisIdentity" in crash_resume,
    "Crash recovery still treats every remote chapter provider as automatically resumable.",
)
remote_chapter_stage = crash_resume.find("item.chapterOnly || item.status == .generatingChapters")
automatic_resume = crash_resume.find("guard item.automaticallyScheduled else { return false }")
require(
    remote_chapter_stage >= 0
    and remote_chapter_stage < automatic_resume
    and "selectedModel.usesRemoteChapterService" in crash_resume[remote_chapter_stage:automatic_resume]
    and "hasPersistedDurableRemoteAnalysisIdentity" in crash_resume[remote_chapter_stage:automatic_resume],
    "An automatic full-pipeline item killed during remote chapter generation can still issue a duplicate one-shot POST.",
)
require(
    automatic_resume >= 0 and "return true" in crash_resume[automatic_resume:],
    "Local chapter models or automatic work before the chapter stage no longer resume after interruption.",
)
durable_identity = function_body(
    CHAPTERS,
    "func hasPersistedDurableRemoteAnalysisIdentity(for episodeHash:",
)
for token in [
    "loadOpenAIBackgroundAnalysisJob",
    "ICRemoteChapterCredentialStore.hasOpenAIAPIKey()",
    "job.modelName",
    "job.responseID",
    "Self.isValidOpenAIResponseID",
]:
    require(token in durable_identity, f"Durable remote identity check is incomplete: {token}")

# Keep the existing official API-key path durable: ownership is written before
# POST and the confirmed response ID is written before polling.
openai_background = function_body(CHAPTERS, "private func generateOpenAIAPIJSONObject(")
require(
    openai_background.find('saveOpenAIBackgroundAnalysisJob(job, reason: "before-create")')
    < openai_background.find('request.httpMethod = "POST"')
    and openai_background.find('saveOpenAIBackgroundAnalysisJob(job, reason: "response-id-received")')
    < openai_background.find("pollOpenAIBackgroundResponse(job: job"),
    "The official OpenAI API-key response-ID resume contract regressed.",
)


print("non-durable remote lifecycle regression checks passed")
