from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
subscription_source = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
ipad_plist_source = (ROOT / "Resources-iPad" / "Instacast HD-Info.plist").read_text()


require(
    "scheduleAutomaticProcessingForEpisodes:episodes" in subscription_source
    and "@objc(scheduleAutomaticProcessingForEpisodes:)" in queue_source
    and "automaticProcessingDecision" in queue_source,
    "Newly discovered episodes are not connected to the transcription queue.",
)
require(
    "private func automaticProcessingDecision(episodes: [CDEpisode])" in queue_source
    and "episodesByHash[episodeHash] = episode" in queue_source
    and "for episodeHash in episodesByHash.keys.sorted()" in queue_source,
    "Automatic scheduling discards the delivered episode batch and rescans the full subscription graph.",
)
automatic_batch = queue_source.split(
    "private func automaticProcessingDecision(episodes:", 1
)[1].split("@objc(scheduleAutomaticProcessingForEpisodes:)", 1)[0]
require(
    "findEpisodes(" not in automatic_batch,
    "Automatic scheduling still performs a main-actor full-feed lookup for an already delivered episode batch.",
)
require(
    "startImmediately: false" in automatic_batch
    and "persistImmediately: false" in automatic_batch
    and "didEnqueueAny" in automatic_batch
    and "persistQueue { error in" in automatic_batch
    and "guard error == nil" in automatic_batch
    and "scheduleAutomaticBackgroundProcessing" in automatic_batch
    and "self.processNext()" in automatic_batch,
    "Automatic discovery still performs one queue write/start per episode or starts work before the batch is durable.",
)
require(
    "kFeedPropertyAutoTranscribe" in queue_source
    and "kFeedPropertyAutoChapters" in queue_source
    and "kTranscriptionAutoDefault" in queue_source
    and "kChapterAutoDefault" in queue_source,
    "Automatic processing does not resolve the existing global and per-feed settings.",
)
require(
    "let automaticallyScheduled: Bool" in queue_source
    and "let shouldGenerateAnalysis: Bool" in queue_source
    and "let retryAttempt: Int?" in queue_source
    and "let nextRetryAt: Date?" in queue_source,
    "Automatic intent, analysis intent, and retry progress are not persisted with queue jobs.",
)
require(
    "scheduleAutomaticBackgroundProcessing" in queue_source
    and "BGProcessingTaskRequest" in queue_source
    and "earliestBeginDate" in queue_source,
    "Automatically queued work does not submit a resumable BGProcessing task.",
)
require(
    "scheduleRetry" in queue_source
    and "isTransientPipelineError" in queue_source
    and "retryAttempt" in queue_source
    and "nextRetryAt" in queue_source,
    "Transient pipeline failures still become terminal instead of persisted retries.",
)
require(
    "recoverOrphanedAutomaticCheckpoints" in queue_source
    and 'let checkpointSuffix = "_checkpoint.json"' in queue_source
    and "engine.hasCheckpoint(for: episodeHash)" in queue_source
    and "!engine.hasSRT(for: episodeHash)" in queue_source
    and "automaticProcessingDecision(for: episode)" in queue_source
    and '"orphan-checkpoint-recovery"' in queue_source,
    "A persisted transcription checkpoint is still lost when its queue file entry is missing.",
)
load_persisted = queue_source.split("private func loadPersistedQueue()", 1)[1]
require(
    "pItem.shouldGenerateAnalysis" in load_persisted
    and "item.chapterOnly = true" in load_persisted,
    "A restored job with a finished SRT can still lose its pending semantic-analysis stage.",
)
automatic_resume_block = queue_source.split(
    "private func canAutoResumeRemoteChapterJobAfterUnexpectedTermination", 1
)[1].split("override init()", 1)[0]
require(
    "guard item.automaticallyScheduled else { return false }" in automatic_resume_block
    and "return true" in automatic_resume_block,
    "An automatic job killed before its first checkpoint still requires a manual retry.",
)
require(
    "Automatische Verarbeitung geplant" in queue_source
    and "automatic-transcription-decision" in queue_source,
    "Automatic scheduling decisions are not recorded in episode and diagnostic logs.",
)
require(
    'setBool:YES forKey:kTranscriptionAutoDefault' not in queue_source
    and 'setBool:YES forKey:kChapterAutoDefault' not in queue_source
    and 'set(true, forKey: kTranscriptionAutoDefault)' not in queue_source
    and 'set(true, forKey: kChapterAutoDefault)' not in queue_source,
    "The implementation silently enables automatic processing instead of respecting setup.",
)
require(
    "BGTaskSchedulerPermittedIdentifiers" in ipad_plist_source
    and "com.iteconomy.instacastplus.transcription.processing" in ipad_plist_source
    and "<string>processing</string>" in ipad_plist_source,
    "The iPad target cannot receive the automatic transcription BGProcessing task.",
)
