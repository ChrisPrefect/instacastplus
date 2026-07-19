from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHAPTERS = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


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


resume = function_body(
    CHAPTERS,
    "func resumePendingOpenAIBackgroundCancellations(",
)
require(
    'let suffix = "_remote_analysis_job.json"' in resume
    and "hasSuffix(suffix)" in resume
    and "loadOpenAIBackgroundAnalysisJob" in resume
    and ".cancellationRequested" in resume,
    "Persisted cancellation manifests are not discovered and validated after relaunch.",
)
require(
    "resumePendingOpenAIBackgroundCancellation(for:" in resume,
    "Cancellation reconciliation is not idempotently deduplicated through provider completion.",
)

resume_one = function_body(
    CHAPTERS,
    "private func resumePendingOpenAIBackgroundCancellation(for episodeHash:",
)
require(
    "cancelAndRemoveOpenAIBackgroundAnalysisJob" in resume_one
    and "activeOpenAICancellationEpisodeHashes.insert" in resume_one,
    "Cancellation reconciliation is not idempotently deduplicated through provider completion.",
)

queue_init = function_body(QUEUE, "override init()")
require(
    "resumePendingOpenAIBackgroundCancellations" in queue_init,
    "App relaunch does not resume durable provider cancellation requests.",
)

cancel = function_body(CHAPTERS, "func cancelOpenAIBackgroundAnalysis(")
require(
    "job.state = .cancellationRequested" in cancel
    and "saveOpenAIBackgroundAnalysisJob" in cancel,
    "Local deletion still removes its durable cancellation intent before provider cancellation.",
)

cancel_and_remove = function_body(
    CHAPTERS,
    "private func cancelAndRemoveOpenAIBackgroundAnalysisJob(",
)
require(
    "reconcileRejectedOpenAIBackgroundCancellation" in cancel_and_remove,
    "A rejected cancel request is not reconciled against the exact stored response before local deletion.",
)

reconcile = function_body(
    CHAPTERS,
    "private func reconcileRejectedOpenAIBackgroundCancellation(",
)
for token in [
    'request.httpMethod = "GET"',
    "openAIResponseURL(responseID:",
    "openAIResponseObject(object, matchesResponseID: responseID, jobKey: job.jobKey)",
    "isTerminalOpenAIResponseStatus",
    "statusCode == 404",
    "removeOpenAIBackgroundAnalysisJob",
]:
    require(token in reconcile, f"Rejected cancellation reconciliation is missing: {token}")
require(
    reconcile.find("openAIResponseObject(object, matchesResponseID: responseID, jobKey: job.jobKey)")
    < reconcile.find("isTerminalOpenAIResponseStatus"),
    "A terminal GET result can remove the tombstone before exact response-ID/job-key metadata validation.",
)
require(
    "queued" in reconcile and "in_progress" in reconcile,
    "A rejected cancel can discard a provider job that GET still reports as active.",
)

job_manifest = function_body(CHAPTERS, "private struct OpenAIBackgroundAnalysisJob:")
require(
    "cancellationRetryAttempt" in job_manifest
    and "cancellationNextRetryAt" in job_manifest,
    "Cancellation retry progress is not persisted with the tombstone.",
)

retry_failure = function_body(
    CHAPTERS,
    "private func persistAndScheduleOpenAIBackgroundCancellationRetry(",
)
require(
    "loadOpenAIBackgroundAnalysisJob" in retry_failure
    and "current.jobKey == job.jobKey" in retry_failure
    and "current.responseID == job.responseID" in retry_failure
    and "current.state == .cancellationRequested" in retry_failure
    and "saveOpenAIBackgroundAnalysisJob" in retry_failure
    and "scheduleOpenAIBackgroundCancellationRetry" in retry_failure,
    "A transient cancellation failure is not durably tied to the exact cancellation tombstone and rescheduled.",
)

schedule_retry = function_body(
    CHAPTERS,
    "private func scheduleOpenAIBackgroundCancellationRetry(",
)
require(
    "openAICancellationRetryTasks" in schedule_retry
    and "Task.sleep" in schedule_retry
    and "resumePendingOpenAIBackgroundCancellation" in schedule_retry,
    "Cancellation retries still run only once at singleton initialization.",
)

schedule_background = function_body(
    QUEUE,
    "private func scheduleAutomaticBackgroundProcessing(earliestBeginDate:",
)
require(
    "hasPendingOpenAIBackgroundCancellationWork" in schedule_background
    and "earliestAutomaticBackgroundWorkDate" in schedule_background
    and "request.requiresNetworkConnectivity = hasCancellationWork" in schedule_background,
    "A persisted cancellation retry cannot request the existing network BGProcessing lifecycle when the episode queue is empty.",
)

resume_queue = function_body(QUEUE, "@objc func resumeIfNeeded()")
require(
    "resumePendingOpenAIBackgroundCancellations" in resume_queue
    and resume_queue.find("resumePendingOpenAIBackgroundCancellations")
    < resume_queue.find("guard !items.isEmpty"),
    "A delivered BGProcessing grant with an empty episode queue does not resume cancellation reconciliation.",
)

for handler in [
    "- (void)_handleTranscriptionProcessingTask:",
    "- (void)_handleTranscriptionContinuedProcessingTask:",
]:
    body = function_body(APP_DELEGATE, handler)
    require(
        "ICOpenAIBackgroundCancellationWorkDidChangeNotification" in body
        and "hasActiveOpenAIBackgroundCancellationWork" in body,
        f"{handler} can release its system grant while provider cancellation reconciliation is active.",
    )

print("Remote cancellation reconciliation regression checks passed.")
