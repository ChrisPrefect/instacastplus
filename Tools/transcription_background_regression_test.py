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
    and "pauseWhisperKitForBackgroundIfNeeded(reason: \"background-task-expired\")" in queue_source
    and "backgroundContinuationTask == .invalid" in queue_source.split("private var shouldPauseWhisperKitForBackground", 1)[1].split("@objc(activateBackgroundExecutionPathWithPath:detail:)", 1)[0],
    "WhisperKit still pauses immediately on background instead of using the short UIApplication background window first.",
)
require(
    "TranscriptionEngine.isBackgroundGPUExecutionError(error)" in queue_source
    and "finishBackgroundPause" in queue_source,
    "Queue does not turn the known background-GPU error into a resumable pause.",
)
require(
    "isProcessing || chapterTask != nil || !pendingDownloadHashes.isEmpty" in queue_source
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
    "prewarm: true" in backend_source
    and "removeOriginalModelSources" in backend_source
    and "Spracherkennungsmodell wird kompiliert." in backend_source,
    "Model download/load does not enforce post-download prewarm and raw-source cleanup.",
)
require(
    "backgroundControlsAvailable" in controller_source
    and "TranscriptionBackgroundTaskActive" in queue_source
    and "UserDefaults.standard.set(false, forKey: TranscriptionQueue.backgroundTaskEnabledKey)" in queue_source,
    "Background button state still persists across fresh WhisperKit runs.",
)
require(
    "_updateToolbarItemsAnimated" in controller_source
    and "[self setToolbarItems:@[flexSpace, self.cancelItem] animated:animated];" in controller_source,
    "Unavailable background transcription is still shown as a disabled toolbar button.",
)
require(
    "BGContinuedProcessingTaskRequest" in controller_source
    and "BGContinuedProcessingTaskRequestResourcesGPU" in controller_source
    and "supportedResources" in controller_source
    and "Hintergrundpfad aktiviert" in controller_source,
    "WhisperKit background still does not submit the iOS 26 continued-processing GPU path transparently.",
)
require(
    "- (BOOL)_shouldUseContinuedGPUBackgroundPath {\n    if (![self _isWhisperKitEngine]) return NO;\n    return [TranscriptionQueue supportsContinuedGPUBackgroundProcessing];\n}" in controller_source
    and "- (BOOL)backgroundControlsAvailable {\n    if (![self _isWhisperKitEngine]) return YES;\n    return [TranscriptionQueue supportsContinuedGPUBackgroundProcessing];\n}" in controller_source,
    "WhisperKit background UI can still submit BGContinuedProcessingTask when the device reports no GPU background support.",
)
require(
    "BGContinuedProcessingTask" in app_delegate_source
    and "progress.completedUnitCount" in app_delegate_source
    and "continued-gpu" in app_delegate_source,
    "The iOS 26 continued-processing task is not registered, monitored, and logged.",
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
    and "UserDefaults.standard.set(true, forKey: TranscriptionQueue.crashGuardKey)" in queue_source.split("private func startChapterGenerationTask", 1)[1].split("chapterTask = Task", 1)[0]
    and "ICDiagnosticLogger.shared.previousSessionEndedUnexpectedly" in queue_source
    and "crashGuardProtectedStatuses" in queue_source
    and "previousEndedUnexpectedly || hasCrashGuardProtectedItems" in queue_source,
    "Crash guard still treats an app kill during an active transcription/chapter run as expected lifecycle and silently auto-resumes.",
)
require(
    "let interruptedMessage = NSLocalizedString(\"Unterbrochen. Tippe zum Fortsetzen.\"" in queue_source
    and "alreadyMarkedInterrupted" in queue_source
    and "if !alreadyMarkedInterrupted" in queue_source
    and "didMarkInterruptedItem" in queue_source
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
chapter_no_cues_block = chapter_task_source.split("guard !cues.isEmpty else {", 1)[1].split("return", 1)[0]
chapter_finished_block = chapter_task_source.split('self.refreshBackgroundContinuation(reason: "chapter-task-finished")', 1)[1].split("}", 1)[0]
require(
    "self.processNext()" in chapter_no_cues_block
    and chapter_no_cues_block.index("self.processNext()") < chapter_no_cues_block.index('self.releaseModelIfIdle(reason: "chapter-task-no-cues")'),
    "A chapter-only job with an unreadable transcript still leaves later queued chapter jobs stuck.",
)
require(
    "self.processNext()" in chapter_finished_block
    and chapter_finished_block.index("self.processNext()") < chapter_finished_block.index('self.releaseModelIfIdle(reason: "chapter-task-finished")'),
    "Completed chapter-only jobs still do not continue the queue, so only the first queued transcript gets chapters.",
)
