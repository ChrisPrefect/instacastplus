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


require(
    "remoteAnalysisJobURL(for episodeHash:" in ENGINE
    and '"\\(episodeHash)_remote_analysis_job.json"' in ENGINE,
    "A remote response ID has no episode-scoped persistent path.",
)
generated_artifacts = function_body(
    ENGINE,
    "@objc static func generatedAnalysisArtifactURLs(for episodeHash:",
)
require(
    "remoteAnalysisJobURL" in generated_artifacts,
    "Deleting generated analysis leaves its remote job manifest behind.",
)

require(
    "OpenAIBackgroundAnalysisJob" in CHAPTERS
    and "responseID" in CHAPTERS
    and "transcriptRevision" in CHAPTERS
    and "modelName" in CHAPTERS
    and "schemaName" in CHAPTERS
    and "jobKey" in CHAPTERS,
    "The persisted OpenAI background job is not bound to response, episode revision, model, schema, and prompt identity.",
)

analysis = function_body(CHAPTERS, "func analyzeEpisodeAsync(fromCues cues:")
require(
    "RemoteAnalysisJobContext" in analysis
    and "debugEpisodeHash" in analysis
    and "transcriptRevision" in analysis,
    "Full-transcript analysis does not bind the provider job to the episode and transcript revision.",
)

openai = function_body(CHAPTERS, "private func generateOpenAIAPIJSONObject(")
for token in [
    '"metadata"',
    "loadOpenAIBackgroundAnalysisJob",
    "saveOpenAIBackgroundAnalysisJob",
    "pollOpenAIBackgroundResponse",
    "activeOpenAIBackgroundEpisodeHashes.insert",
    'request.setValue(job.clientRequestID, forHTTPHeaderField: "X-Client-Request-Id")',
    "openAIAmbiguousCreateError",
]:
    require(token in openai, f"OpenAI durable analysis is missing: {token}")
require(
    openai.find("loadOpenAIBackgroundAnalysisJob") < openai.find('request.httpMethod = "POST"'),
    "An existing OpenAI response ID is not resumed before creating a new billed response.",
)
require(
    "case .active:" in openai
    and "guard let responseID = persisted.responseID" in openai
    and "pollOpenAIBackgroundResponse(job: persisted" in openai,
    "An active provider response ID is not resumed through polling.",
)
require(
    openai.find('state: .submitting') < openai.find('request.httpMethod = "POST"')
    and openai.find('saveOpenAIBackgroundAnalysisJob(job, reason: "before-create")')
    < openai.find('request.httpMethod = "POST"'),
    "The ambiguous create window is not represented on disk before the POST starts.",
)
require(
    openai.find("job.responseID = responseID")
    < openai.find('saveOpenAIBackgroundAnalysisJob(job, reason: "response-id-received")')
    and "Task.checkCancellation" not in openai[
        openai.find("job.responseID = responseID") :
        openai.find('saveOpenAIBackgroundAnalysisJob(job, reason: "response-id-received")')
    ],
    "The provider response ID is not persisted before any post-create cancellation check.",
)

background_body = function_body(CHAPTERS, "private func openAIBackgroundResponsesBody(")
require(
    'body["background"] = true' in background_body
    and 'body["store"] = true' in background_body,
    "Official OpenAI semantic analysis is not using stored Background Responses.",
)
fingerprint = function_body(CHAPTERS, "private func makeRemoteAnalysisJobContext(")
for token in [
    "JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])",
    "episodeHash",
    "transcriptRevision",
    "modelName",
    "schemaName",
    "requestData",
    "SHA256.hash",
]:
    require(token in fingerprint, f"Request fingerprint is incomplete: {token}")

poll = function_body(CHAPTERS, "private func pollOpenAIBackgroundResponse(")
for token in ['request.httpMethod = "GET"', '"queued"', '"in_progress"', '"completed"']:
    require(token in poll, f"OpenAI response polling is missing state handling: {token}")
require(
    "openAIResponseURL(responseID:" in poll
    and "openAIResponseObject" in poll,
    "A retrieved response is accepted without strict URL/ID/metadata validation.",
)
require(
    "job.state = .terminal" in poll
    and "saveOpenAIBackgroundAnalysisJob" in poll,
    "Terminal provider state is removed before the queue can durably record its retry/failure.",
)
require(
    "removeOpenAIBackgroundAnalysisJob" not in poll,
    "Polling physically deletes provider state before queue persistence, reopening a duplicate-POST crash window.",
)
require(
    'status?(NSLocalizedString("OpenAI-Analyse wartet beim Anbieter.", comment: ""))' in poll
    and 'status?(NSLocalizedString("OpenAI analysiert die Episode.", comment: ""))' in poll
    and 'status?(NSLocalizedString("OpenAI-Ergebnis wird geprüft.", comment: ""))' in poll
    and "status: status" in openai,
    "Persisted OpenAI queued/in-progress/result-validation states are not forwarded to the visible queue status.",
)
require(
    'status?(NSLocalizedString("OpenAI-Auftrag wird erstellt.", comment: ""))' in openai,
    "The visible analysis status does not distinguish durable OpenAI job creation.",
)
response_url = function_body(CHAPTERS, "private func openAIResponseURL(")
require(
    "isValidOpenAIResponseID" in response_url
    and ".appendingPathComponent(responseID" in response_url,
    "Response IDs are not strictly validated before path construction.",
)

save_analysis = function_body(CHAPTERS, "@objc func saveAnalysisResult(")
require(
    "openAIBackgroundJobKey: result.openAIBackgroundJobKey" in save_analysis
    and "openAIBackgroundResponseID: result.openAIBackgroundResponseID" in save_analysis,
    "The atomic analysis commit does not retain the exact provider identity needed for finalization.",
)
require(
    "removeOpenAIBackgroundAnalysisJob" not in save_analysis,
    "The provider manifest is removed before the queue completion snapshot is durable.",
)

rejected = function_body(CHAPTERS, "private func markOpenAIBackgroundAnalysisRejected(")
require(
    "job.state = .rejected" in rejected
    and "saveOpenAIBackgroundAnalysisJob" in rejected,
    "Completed output that fails local evidence validation can be silently resubmitted after a crash.",
)

load_job = function_body(CHAPTERS, "private func loadOpenAIBackgroundAnalysisJob(")
require(
    "beschädigt und wird nicht stillschweigend ersetzt" in load_job
    and "throw openAIBackgroundManifestError" in load_job,
    "A corrupt provider manifest is silently discarded and can trigger a duplicate POST.",
)
finalize = function_body(
    CHAPTERS,
    "func finalizeOpenAIBackgroundJobAfterPersistedAnalysis(",
)
require(
    "analysis.openAIBackgroundJobKey" in finalize
    and "analysis.openAIBackgroundResponseID" in finalize
    and "matchingJobKey: jobKey" in finalize
    and "responseID: responseID" in finalize
    and 'reason: "queue-completion-persisted"' in finalize,
    "Queue finalization can remove the wrong provider manifest or run without the committed identity.",
)

chapter_task = function_body(QUEUE, "private func startChapterGenerationTask(for item:")
require(
    "persistQueue { error in" in chapter_task
    and "error == nil" in chapter_task
    and "finalizeOpenAIBackgroundJobAfterPersistedAnalysis" in chapter_task,
    "The provider manifest is finalized before standalone analysis completion is durably queued.",
)
load_queue = function_body(QUEUE, "private func loadPersistedQueue()")
require(
    "committedAnalysisHashesToFinalize" in load_queue
    and "hasValidAnalysis(for:" in load_queue
    and "persistQueue { error in" in load_queue
    and "finalizeOpenAIBackgroundJobAfterPersistedAnalysis" in load_queue,
    "A process kill between analysis commit and queue completion can trigger a duplicate provider POST on restore.",
)

retry = function_body(QUEUE, "private func scheduleRetry(for item:")
require(
    "maximumAutomaticRemoteAnalysisReplacements" in retry
    and "terminalOpenAIBackgroundJobToken" in retry
    and "retireTerminalOpenAIBackgroundJobAfterPersistedRetry" in retry
    and "persistQueue { error in" in retry,
    "Automatic provider replacement is unbounded or retires terminal identity before retry persistence.",
)

explicit_retry = function_body(
    CHAPTERS,
    "func prepareOpenAIBackgroundJobForExplicitRetry(",
)
require(
    "job.state == .terminal" in explicit_retry
    and "job.state == .rejected" in explicit_retry,
    "An explicit queue retry cannot retire a safely finished provider job.",
)
for unsafe_state in [".active", ".submitting", ".cancellationRequested"]:
    require(
        unsafe_state not in explicit_retry,
        f"An explicit queue retry locally discards an unresolved provider job: {unsafe_state}",
    )

terminal_token = function_body(
    CHAPTERS,
    "func terminalOpenAIBackgroundJobToken(",
)
require(
    "let responseID = job.responseID" in terminal_token
    and "Self.isValidOpenAIResponseID(responseID)" in terminal_token
    and "responseID: responseID" in terminal_token,
    "A rejected create without a confirmed valid provider response ID consumes the billed replacement budget.",
)
terminal_token_type = function_body(CHAPTERS, "struct OpenAIBackgroundJobToken:")
require(
    "let responseID: String" in terminal_token_type
    and "let responseID: String?" not in terminal_token_type,
    "The terminal provider token does not encode its non-optional confirmed response-ID invariant.",
)

codex = function_body(
    CHAPTERS,
    "private func generateOpenAICodexOAuthJSONObject(modelName: String,\n                                                    token:",
)
require(
    "openAIResponsesBody" in codex,
    "Codex OAuth request construction unexpectedly disappeared.",
)
body = function_body(CHAPTERS, "private func openAIResponsesBody(")
require(
    '"store": false' in body and '"background"' not in body,
    "Private Codex OAuth requests must not inherit unsupported official-API background semantics.",
)

print("Remote analysis resume regression checks passed.")
