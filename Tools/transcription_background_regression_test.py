from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
engine_source = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
backend_source = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
controller_source = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
settings_source = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
app_delegate_source = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
cell_source = (ROOT / "Classes" / "DownloadsTableViewCell.m").read_text()
entitlements_source = (ROOT / "Instacast.entitlements").read_text()


require(
    "static func isBackgroundGPUExecutionError(_ error: Error) -> Bool" in engine_source,
    "Core ML background-GPU errors are not classified explicitly.",
)
require(
    "if !wasCancelled && !Self.isBackgroundGPUExecutionError(error)" in engine_source,
    "Background-GPU errors still increment the checkpoint failure counter.",
)
require(
    "Auto-downgraded to small model" not in engine_source
    and "Falling back to Apple engine" not in engine_source
    and 'UserDefaults.standard.set("openai_whisper-small_216MB"' not in engine_source,
    "Transcription still silently changes model/engine after failures.",
)
require(
    "refreshBackgroundContinuation(reason: \"applicationDidEnterBackground\")" in queue_source
    and "pausePipelineForBackgroundIfNeeded(reason: \"applicationDidEnterBackground\")" in queue_source
    and "!hasActiveWhisperKitBackgroundExecution" in queue_source.split("private var shouldPauseWhisperKitForBackground", 1)[1].split("@objc(activateBackgroundExecutionPathWithPath:detail:)", 1)[0]
    and "backgroundContinuationTask == .invalid" not in queue_source.split("private var shouldPauseWhisperKitForBackground", 1)[1].split("@objc(activateBackgroundExecutionPathWithPath:detail:)", 1)[0],
    "WhisperKit still treats an ordinary UIApplication background window as permission to submit GPU work.",
)
require(
    "TranscriptionEngine.isBackgroundGPUExecutionError(error)" in queue_source
    and "finishBackgroundPause" in queue_source,
    "Queue does not turn the known background-GPU error into a resumable pause.",
)
background_pause_body = queue_source.split(
    "private func finishBackgroundPause(for item: ICTranscriptionQueueItem", 1
)[1].split("// MARK: - Processing", 1)[0]
require(
    "scheduleRetry(for: item" not in background_pause_body
    and "item.status = .queued" in background_pause_body
    and "item.nextRetryAt = nil" in background_pause_body
    and "item.error = nil" in background_pause_body
    and "scheduleAutomaticBackgroundProcessing(earliestBeginDate: nil)" in background_pause_body,
    "An expected app-background pause is still treated as an error with a delayed retry instead of an immediately resumable queued state.",
)
require(
    queue_source.count("guard persistCheckpointBeforeInterruption(for: item, reason: reason) else") >= 2
    and "guard engine.persistCurrentCheckpointForInterruption() else" in queue_source,
    "Background pause/profile transitions still cancel transcription before flushing the latest synchronized cue snapshot.",
)
profile_transition_body = queue_source.split(
    "private func beginWhisperKitComputeProfileTransitionIfNeeded", 1
)[1].split("@discardableResult\n    private func pauseWhisperKitForBackgroundIfNeeded", 1)[0]
require(
    "item.progress = 0" not in profile_transition_body,
    "Switching to the granted background compute profile still resets visible transcription progress to zero.",
)
require(
    "isProcessing || chapterTask != nil || computeProfileTransitionTask != nil || !pendingDownloadHashes.isEmpty" in queue_source
    and "UIApplication.shared.applicationState == .background" in queue_source
    and "engine.engineType != .whisperKit" not in queue_source.split("private func refreshBackgroundContinuation", 1)[1].split("private func beginBackgroundContinuationIfNeeded", 1)[0],
    "Short background continuation does not cover downloads, music analysis, WhisperKit work, and chapter generation uniformly.",
)
require(
    "@objc func retry(episodeHash: String)" in queue_source
    and "resetCheckpointFailureCounter" in engine_source
    and "retryWithEpisodeHash" in controller_source,
    "Failed transcription rows cannot be restarted cleanly.",
)
require(
    "shouldPreserveTranscriptCheckpoint" in queue_source
    and "if !shouldPreserveTranscriptCheckpoint {" in queue_source
    and "cleanupBrokenArtifacts(for: item)" in queue_source.split("shouldPreserveTranscriptCheckpoint", 1)[1],
    "Retry after a killed transcription still deletes the existing checkpoint instead of resuming it.",
)
require(
    "currentTranscriptionRunID" in engine_source
    and "let transcriptionRunID = UUID()" in engine_source
    and "currentTranscriptionRunID = transcriptionRunID" in engine_source
    and "guard self.currentTranscriptionRunID == transcriptionRunID" in engine_source
    and "completion(allCues, nil)" not in engine_source,
    "TranscriptionEngine can still invoke the same completion twice after cancel/resume races.",
)
require(
    "segmentCallback: liveSegmentCallback" in backend_source
    and "deliveredSegmentKeys" in backend_source,
    "WhisperKit segments are still only delivered after the full transcription returns.",
)
require(
    "progress(p)" not in backend_source.split("func deliverIfNeeded", 1)[1].split("nonisolated(unsafe) let liveSegmentCallback", 1)[0],
    "WhisperKit segment delivery still reports duplicate progress through both segmentCallback and progress.",
)
require(
    "modelLoadTask" in backend_source
    and "if let modelLoadTask" in backend_source
    and "modelLoadGeneration" in backend_source,
    "Concurrent resume attempts can still start multiple WhisperKit/Core ML model loads after a stopped transcription.",
)
model_load_block = queue_source.split("// Step 2: Pre-load WhisperKit model", 1)[1].split("guard await MainActor.run", 1)[0]
require(
    "try await WhisperKitBackend.shared.prepareModel(statusUpdate: detailUpdater)" in model_load_block
    and "Task.detached" not in model_load_block,
    "Model preparation is still launched through an untracked detached task, so pause/resume cancellation can leave an orphaned Core ML load running.",
)
release_model_body = backend_source.split("func releaseModel()", 1)[1].split("// MARK: - Delete", 1)[0]
require(
    "invalidateModelLoadTask()" in release_model_body
    and "catch is CancellationError" in backend_source,
    "Cancelling an idle queue can still leave an in-flight Core ML model load running and later installing/logging as ready.",
)
require(
    "prepareDownloadedModelForAllComputeProfiles" in backend_source
    and "prewarm: false" in backend_source
    and "computeProfilePreparationMarkerName" in backend_source
    and "removeOriginalModelSources" in backend_source
    and "Core ML bereitet das Modell einmalig für dieses Rechenprofil vor." in backend_source,
    "Model download/load does not enforce one-time per-profile preparation and raw-source cleanup.",
)
require(
    "backgroundControlsAvailable" in controller_source
    and "TranscriptionBackgroundTaskRequested" in controller_source
    and "grantedBackgroundExecutionPath" in queue_source
    and "UserDefaults" not in queue_source.split("private var activeBackgroundExecutionPath", 1)[1].split("private var hasActiveWhisperKitBackgroundExecution", 1)[0],
    "A submitted background request is still confused with a process-local system grant.",
)
require(
    "_updateToolbarItemsAnimated" in controller_source
    and "[self setToolbarItems:@[flexSpace, self.cancelItem] animated:animated];" in controller_source,
    "Unavailable background transcription is still shown as a disabled toolbar button.",
)
require(
    "BGContinuedProcessingTaskRequest" in controller_source
    and "BGContinuedProcessingTaskRequestResourcesGPU" in controller_source
    and "BGContinuedProcessingTaskRequestResourcesDefault" in controller_source
    and '"continued-cpu"' in controller_source
    and "supportedResources" in controller_source
    and "activateBackgroundExecutionPathWithPath" in app_delegate_source,
    "WhisperKit background does not select a supported iOS 26 continued GPU or CPU/ANE path.",
)
require(
    "- (BOOL)_shouldUseContinuedBackgroundPath {\n    if (![self _isWhisperKitEngine]) return NO;\n    if (@available(iOS 26.0, *)) return YES;\n    return NO;\n}" in controller_source
    and "- (BOOL)backgroundControlsAvailable {\n    return YES;\n}" in controller_source,
    "WhisperKit background UI still hides the CPU/ANE continued path when GPU background support is unavailable.",
)
require(
    "BGContinuedProcessingTask" in app_delegate_source
    and "progress.completedUnitCount" in app_delegate_source
    and "ICTranscriptionActiveContinuedPath" in app_delegate_source
    and "continued-cpu" in app_delegate_source
    and "continued-gpu" in app_delegate_source,
    "The iOS 26 continued-processing task does not preserve, monitor, and log the selected CPU/GPU path.",
)
require(
    "com.apple.developer.background-tasks.continued-processing.gpu" in entitlements_source,
    "Background GPU Access entitlement is missing.",
)
require(
    "CGRect bounds = self.contentView.bounds;" in cell_source
    and "CGFloat textLeft = CGRectGetMaxX(imageViewRect) + (showsPlayButton ? 25 : 10);" in cell_source
    and "rightContentAccessoryWidth + 5" in cell_source
    and "self.timeLabel.frame = CGRectMake(CGRectGetMaxX(bounds) - rightContentAccessoryWidth" in cell_source
    and "accessoryReservedWidth" not in cell_source,
    "Download/transcription cell layout still double-reserves accessory space or keeps elapsed time on the status text row.",
)
require(
    "Modelle werden bei Bedarf heruntergeladen und danach vorbereitet." not in settings_source
    and "Geladene Modelle kannst du per Swipe nach links löschen." in settings_source
    and "Core ML" not in settings_source
    and "GPU" not in settings_source,
    "Model settings copy should stay short, user-centered, and avoid redundant main-page download hints.",
)
require(
    "willBeginEditingRowAtIndexPath" in controller_source
    and "didEndEditingRowAtIndexPath" in controller_source
    and "swipeInteractionActive" in controller_source
    and "if (self.swipeInteractionActive) return;" in controller_source,
    "Swipe-to-delete still allows progress reloads during the swipe gesture.",
)
require(
    "standaloneIntroOutroMusicChapters" in chapter_source
    and "Kapitel aus Musikgrenzen ergänzt" in chapter_source,
    "Detected intro/outro music segments are not converted into structural chapter boundaries.",
)
require(
    "let chapterOnly: Bool?" in queue_source
    and "item.chapterOnly || (item.status == .generatingChapters && engine.hasSRT(for: item.episodeHash))" in queue_source
    and "item.chapterOnly = true" in queue_source
    and "if candidate.chapterOnly {" in queue_source
    and "startChapterGenerationTask(for: candidate" in queue_source,
    "Chapter-only and in-progress chapter jobs are not persisted and resumed after app termination.",
)
require(
    "previousSessionEndedUnexpectedly" in engine_source
    and "TranscriptionQueue.crashGuardKey" in queue_source
    and "armCrashGuard(for: item)" in queue_source.split("private func startChapterGenerationTask", 1)[1].split("chapterTask = Task", 1)[0]
    and "ICDiagnosticLogger.shared.previousSessionEndedUnexpectedly" in queue_source
    and "crashGuardProtectedStatuses" in queue_source
    and "crashGuardEpisodeHashKey" in queue_source
    and "requiresExplicitRetryAfterCrash" in queue_source,
    "Crash guard still treats an app kill during an active transcription/chapter run as expected lifecycle and silently auto-resumes.",
)
require(
    "let interruptedMessage = NSLocalizedString(\"Unterbrochen. Tippe zum Fortsetzen.\"" in queue_source
    and "alreadyMarkedInterrupted" in queue_source
    and "if !alreadyMarkedInterrupted" in queue_source
    and "didMarkInterruptedItem" in queue_source
    and "item.requiresExplicitRetryAfterCrash = true" in queue_source
    and "persistQueue()" in queue_source.split("if didMarkInterruptedItem", 1)[1].split("postQueueChangeNotification()", 1)[0],
    "Crash guard still appends duplicate interruption log entries when resumeIfNeeded is invoked more than once after an app kill.",
)
require(
    "canAutoResumeRemoteChapterJobAfterUnexpectedTermination" in queue_source
    and "selectedModel(for: .textToChapters).usesRemoteChapterService" in queue_source
    and "autoResumableRemoteChapterItems" in queue_source
    and "Crash-Guard: Cloud-Kapiteljob wird automatisch fortgesetzt" in queue_source,
    "Crash guard still blocks cloud-only chapter generation after an app kill even though no local model load can crash-loop.",
)
chapter_task_source = queue_source.split("private func startChapterGenerationTask", 1)[1].split("/// Parse SRT file", 1)[0]
chapter_cue_load_failure_block = chapter_task_source.split(
    "cues = try await self.loadCuesForChapterGeneration(episodeHash: episodeHash)", 1
)[1].split("// Load cached music timeline", 1)[0]
chapter_finished_block = chapter_task_source.split('self.refreshBackgroundContinuation(reason: "chapter-task-finished")', 1)[1].split("}", 1)[0]
require(
    "self.processNext()" in chapter_cue_load_failure_block
    and chapter_cue_load_failure_block.index("self.processNext()")
    < chapter_cue_load_failure_block.index('self.releaseModelIfIdle(reason: "chapter-task-transcript-import-finished")'),
    "A chapter-only job with an unreadable transcript still leaves later queued chapter jobs stuck.",
)
require(
    "self.processNext()" in chapter_finished_block
    and chapter_finished_block.index("self.processNext()") < chapter_finished_block.index('self.releaseModelIfIdle(reason: "chapter-task-finished")'),
    "Completed chapter-only jobs still do not continue the queue, so only the first queued transcript gets chapters.",
)
