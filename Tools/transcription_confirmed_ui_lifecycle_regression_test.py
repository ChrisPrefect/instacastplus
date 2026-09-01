from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ENGINE = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
QUEUE = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
QUEUE_UI = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
EPISODE_UI = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
EPISODES_UI = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
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


# A publisher transcript and an app-created transcript share the canonical SRT path.
# Provenance therefore belongs to the committed SRT artifact itself and must survive
# process restarts. The final rename publishes content and origin together.
require(
    "transcriptOriginAttributeName" in ENGINE
    and "setxattr" in ENGINE
    and "getxattr" in ENGINE
    and "replaceItemAt" in ENGINE,
    "Canonical SRT files do not retain durable, atomically committed provenance.",
)
save_imported = function_body(ENGINE, "func saveImportedTranscriptCues(")
require(
    "origin: .publisher" in save_imported,
    "Publisher-provided timed cues are still indistinguishable from app-created transcripts.",
)
require(
    "@objc func hasDeletableSRT(for episodeHash: String) -> Bool" in ENGINE,
    "Objective-C menus cannot ask whether an SRT is actually app-owned and deletable.",
)
for source, label in ((EPISODE_UI, "episode detail"), (EPISODES_UI, "episode list")):
    require(
        "hasDeletableSRTFor:" in source,
        f"The {label} menu still offers transcript deletion based only on SRT existence.",
    )
    require(
        'systemImageNamed:@"trash"' in source
        and "imageWithTintColor:[UIColor systemRedColor]" in source,
        f"The {label} transcript-delete action does not use the project-standard red trash icon.",
    )


# Every status message must be readable in the queue and must also appear in the
# detailed per-episode log. updateStatusDetail already rejects identical consecutive
# polls; append only after that guard.
require(
    "ICTranscriptionQueueCell" in QUEUE_UI
    and "cell.sizeLabel.numberOfLines = 0;" in QUEUE_UI
    and "cell.sizeLabel.numberOfLines = 2;" not in QUEUE_UI,
    "Ordinary transcription statuses are still capped at two visible lines.",
)
row_height = function_body(QUEUE_UI, "- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:")
require(
    "item.status != ICTranscriptionStatusFailed" not in row_height
    and "boundingRectWithSize" in row_height,
    "Only failed queue rows get their complete status height; ordinary statuses remain fixed at 80 pt.",
)
status_update = function_body(QUEUE, "private func updateStatusDetail(for episodeHash:")
require(
    status_update.find("guard item.statusDetail != detail else { return }")
    < status_update.find("TranscriptionLogger.shared.append")
    and 'phase: "status"' in status_update,
    "Changed status details are not deduplicated into the per-episode transcription log.",
)
begin_step = function_body(QUEUE, "private func beginStep(for item:")
require(
    'phase: "status"' in begin_step
    and "if let detail, !detail.isEmpty" in begin_step,
    "The first visible detail of each queue stage is still absent from the per-episode log.",
)
require(
    'if ([phase isEqualToString:@"status"])' in QUEUE_UI,
    "Detailed status log entries have no human-readable phase label.",
)


# Entering the background first consumes UIKit's granted continuation time. The
# pipeline may checkpoint/cancel only from the actual expiration callback (or a real
# BG task expiration), not pre-emptively on didEnterBackground or at the next stage.
did_enter = QUEUE.split("UIApplication.didEnterBackgroundNotification", 1)[1].split(
    "UIApplication.willEnterForegroundNotification", 1
)[0]
require(
    "refreshBackgroundContinuation" in did_enter
    and "pausePipelineForBackgroundIfNeeded" not in did_enter,
    "didEnterBackground still pauses the pipeline immediately after requesting UIKit background time.",
)
require(
    "hasActiveUIApplicationBackgroundTime" in QUEUE,
    "Stage boundaries cannot distinguish valid UIKit background time from expiration.",
)
chapter_pause = function_body(QUEUE, "private var shouldPauseChapterOnlyForBackground:")
transcription_pause = function_body(QUEUE, "private var shouldPauseTranscriptionForBackground:")
for body, label in ((chapter_pause, "chapter"), (transcription_pause, "transcription")):
    require(
        "!hasActiveUIApplicationBackgroundTime" in body,
        f"The {label} pipeline still pauses while UIKit background time is active.",
    )
background_start = function_body(QUEUE, "private func beginBackgroundContinuationIfNeeded(reason:")
require(
    background_start.find('endBackgroundContinuationIfNeeded(reason: "background-task-expired")')
    < background_start.find('pausePipelineForBackgroundIfNeeded(reason: "background-task-expired")'),
    "The expiration handler does not revoke UIKit background ownership before checkpointing/cancelling.",
)


# The OpenAI API-key path must persist an ambiguous submit state before POST, persist
# the returned response ID before polling, and resume an active job by GET rather than
# creating a second expensive request.
openai_background = function_body(CHAPTERS, "private func generateOpenAIAPIJSONObject(")
require(
    openai_background.find('saveOpenAIBackgroundAnalysisJob(job, reason: "before-create")')
    < openai_background.find('request.httpMethod = "POST"')
    and openai_background.find('saveOpenAIBackgroundAnalysisJob(job, reason: "response-id-received")')
    < openai_background.find("pollOpenAIBackgroundResponse(job: job"),
    "The durable OpenAI path can POST without first persisting ownership or can poll before persisting the response ID.",
)
require(
    "case .active:" in openai_background
    and "pollOpenAIBackgroundResponse(job: persisted" in openai_background
    and "Ein automatischer Doppel-POST wird verhindert" in openai_background,
    "A restored OpenAI background response can be submitted a second time.",
)


# Sol and Terra are both accepted by the verified Codex endpoint. Keep Terra's stored
# identifier stable, but route both through the provider that prefers an API key and
# otherwise uses Codex OAuth.
terra_definition = ENGINE.split('identifier: "openai-gpt-5.6-terra-api-key"', 1)[1].split(
    "ICDownloadableModel(", 1
)[0]
require(
    "chapterProvider: .openAICodexOAuth" in terra_definition
    and 'remoteModelName: "gpt-5.6-terra"' in terra_definition,
    "Terra still requires an API key even though the same verified Codex OAuth route supports it.",
)
codex_route = function_body(CHAPTERS, "private func generateRemoteJSONObject(").split(
    "case .openAICodexOAuth:", 1
)[1].split("case .anthropicAPI:", 1)[0]
require(
    "openAIAPIKey()" in codex_route
    and "generateOpenAIAPIJSONObject" in codex_route
    and "generateOpenAICodexOAuthJSONObject" in codex_route,
    "The shared Sol/Terra route does not prefer the API key while retaining Codex OAuth.",
)


print("confirmed transcription UI/lifecycle regressions: ok")
