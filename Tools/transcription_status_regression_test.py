from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
engine_source = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
backend_source = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
audio_source = (ROOT / "Classes" / "AudioAnalyzer.swift").read_text()
controller_source = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
main_source = (ROOT / "Classes" / "MainViewController_4.m").read_text()
playback_source = (ROOT / "Classes" / "PlaybackManager.m").read_text()
settings_source = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
app_delegate_source = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
scene_delegate_source = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
episode_controller_source = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
episodes_controller_source = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
cache_manager_source = (ROOT / "Classes" / "CacheManager.m").read_text()
player_info_source = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
episode_model_source = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()
bundle_source = (ROOT / "VemedioKit" / "NSBundle+VMFoundation.m").read_text()
de_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
en_strings = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()

cleanup_start = queue_source.find("private func cleanupBrokenArtifacts(episodeHash: String, chapterOnly: Bool)")
cleanup_end = queue_source.find("/// Number of items currently queued", cleanup_start)
cleanup_body = queue_source[cleanup_start:cleanup_end]

require(
    "ICTranscriptionInternalStatusDetailNotification" in queue_source,
    "Transcription queue no longer has an internal status-detail notification bridge.",
)
require(
    "@objc var statusDetail: String?" in queue_source and "@objc var statusStartedAt: Date?" in queue_source,
    "Queue items no longer persist detail text and step start times for UI status reporting.",
)
require(
    "@objc var completedAt: Date?" in queue_source
    and "private static let completedItemRetentionInterval: TimeInterval = 30 * 60" in queue_source
    and "scheduleCompletedItemPrune" in queue_source
    and ".now() + Self.completedItemRetentionInterval" in queue_source,
    "Completed transcription items must stay visible for 30 minutes before being pruned.",
)
require(
    "completedAt: Date?" in queue_source
    and "statusRawValue: Int" in queue_source
    and "Date().timeIntervalSince(completedAt) < Self.completedItemRetentionInterval" in queue_source,
    "Completed queue items must persist as completed rows for the 30-minute retention window without being restarted.",
)
require(
    "item.chapterOnly = pItem.chapterOnly == true" in queue_source,
    "Completed chapter-only queue rows lose their chapterOnly flag after app restart, which makes remote/UI inspection misleading.",
)
require(
    "pItem.statusRawValue == ICTranscriptionStatus.failed.rawValue" in queue_source
    and "item.status = .failed" in queue_source
    and "item.error = pItem.error" in queue_source
    and "item.completedAt = nil" in queue_source,
    "Failed queue rows are not persisted/restored for retry after app restart, or retry does not clear their retained timestamp.",
)
require(
    "items.removeAll { $0.status == .completed }" not in queue_source,
    "Completed queue items are still removed immediately.",
)
require(
    "@objc var hasVisibleItems: Bool" in queue_source
    and "@objc var activeItemCount: Int" in queue_source
    and "[TranscriptionQueue shared].hasVisibleItems" in main_source
    and "activeItemCount" in main_source,
    "The sidebar transcription entry must only be visible while the queue has active or recently completed items.",
)
require(
    "chapterGenerationError" in queue_source
    and "Transkription abgeschlossen, Kapitel fehlgeschlagen." in queue_source
    and "item.status = .failed" in queue_source,
    "Auto chapter-generation failures after a successful transcription must not be hidden behind a completed queue row.",
)
require(
    "applicationWillEnterForeground" in queue_source
    and "self?.resumeIfNeeded()" in queue_source,
    "Foreground/unlock must resume queued transcription work instead of only refreshing background state.",
)
scene_active_start = scene_delegate_source.find("- (void)sceneDidBecomeActive:")
scene_active_end = scene_delegate_source.find("- (void)sceneWillResignActive:", scene_active_start)
scene_active_block = scene_delegate_source[scene_active_start:scene_active_end]
require(
    'recordLifecycle:@"sceneDidBecomeActive"' in scene_active_block
    and "[[TranscriptionQueue shared] resumeIfNeeded];" in scene_active_block,
    "Foreground resume must also run when the scene becomes active, after applicationState leaves background.",
)
require(
    "dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))" not in scene_delegate_source
    and "dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC))" not in scene_delegate_source
    and "Resume transcription queue after the initial scene setup has yielded once." in scene_delegate_source,
    "Transcription resume is still delayed for several seconds after launch or foregrounding.",
)
require(
    "private func beginStep(for item: ICTranscriptionQueueItem," in queue_source,
    "Transcription queue is missing the shared step-transition helper.",
)
require(
    "static func detailedErrorMessage(for error: Error) -> String {" in queue_source,
    "Transcription queue no longer builds detailed user-visible error messages.",
)
resume_guard_index = queue_source.find("guard !isProcessing else {")
crash_guard_index = queue_source.find("if UserDefaults.standard.bool(forKey: TranscriptionQueue.crashGuardKey) {")
require(
    resume_guard_index != -1 and crash_guard_index != -1 and resume_guard_index < crash_guard_index,
    "Foreground resume now checks the crash guard before noticing a still-running transcription, so backgrounding the app can falsely mark an active run as crashed.",
)
require(
    "UIApplication.shared.beginBackgroundTask(withName: \"InstacastPlus.TranscriptionQueue\")" in queue_source and
    "UIApplication-Hintergrundtask gestartet" in queue_source and
    "UIApplication-Hintergrundtask beendet" in queue_source,
    "Background transcription no longer keeps the current run alive with a real UIApplication background task.",
)
require(
    "Whisper-Modell wegen Idle-Queue freigegeben" in queue_source and
    "releaseModelIfIdle(reason: \"queue-idle\")" in queue_source,
    "The transcription queue no longer releases the in-memory Whisper model when it becomes idle, so opening playback right after a run can regress into memory-driven crashes.",
)

require(
    "statusDetail: @escaping @Sendable (String) -> Void," in engine_source,
    "Transcription engine no longer accepts a status-detail callback.",
)
require(
    "@objc class ICDiagnosticLogger: NSObject" in engine_source and
    'appendingPathComponent("Transcripts", isDirectory: true)' in engine_source,
    "The central diagnostic logger or the Files-app-visible transcript directory is missing from the transcription engine.",
)
require(
    "@objc func logFileEvent(_ category: String, message: String, path: String, metadata: NSDictionary?)" in engine_source and
    "@objc func logDirectoryEvent(_ category: String, message: String, path: String, metadata: NSDictionary?)" in engine_source,
    "The diagnostic logger no longer exposes reusable file/directory snapshot logging for player-side read/write/delete paths.",
)
require(
    "@objc class ICTranscriptionPaths: NSObject" in engine_source and
    "@objc static func transcriptCacheDirectory() -> URL" in engine_source and
    "@objc static func srtURL(for episodeHash: String) -> URL" in engine_source,
    "Transcription file paths are no longer exposed through a non-MainActor helper, so background/file-loader code can regress into blocking on TranscriptionEngine.shared.",
)
require(
    'stringByAppendingPathComponent:@"Logs"' in bundle_source and
    'appendingPathComponent("Data")' not in bundle_source,
    "Logs are no longer written to an app-visible Logs folder under the Files app root.",
)
require(
    "private func initialStatusDetail(for engine: ICTranscriptionEngineType," in engine_source,
    "Transcription engine is missing the initial detailed-status formatter.",
)
require(
    "statusUpdate: statusDetail" in engine_source,
    "Whisper backend status updates are no longer forwarded through the engine.",
)

require(
    "private nonisolated static func userVisibleStatus(fromWhisperLog message: String) -> String?" in backend_source,
    "Whisper backend no longer translates backend logs into user-visible status text.",
)
require(
    "statusUpdate: @escaping @Sendable (String) -> Void = { _ in }" in backend_source,
    "Whisper backend entry points no longer accept status callbacks.",
)

require(
    "status: ((String) -> Void)? = nil," in chapter_source,
    "Chapter generator no longer exposes detailed status callbacks.",
)
require(
    "func generateChaptersAsync(fromCues cues: [ICTranscriptCue]," in chapter_source,
    "Chapter generator no longer exposes a structured async API, so queue cancellation cannot propagate into LLM work.",
)
require(
    "semanticArtifacts = try await self.generateSemanticArtifacts(" in queue_source,
    "Transcription queue is no longer awaiting semantic analysis directly, so cancel/remove can leave stale model work running.",
)
require(
    "item.chapterOnly = true\n        items.append(item)\n        persistQueue()\n        postQueueChangeNotification()\n\n        if !isProcessing && chapterTask == nil {\n            processNext()\n        }" in queue_source,
    "Chapter-only debug/UI jobs must stay queued behind an active transcription instead of starting a second model task concurrently.",
)
require(
    "Verarbeitung im Hintergrund pausiert. Wird mit verfügbarer Rechenzeit automatisch fortgesetzt." in queue_source,
    "Background-paused jobs still tell users to tap even though foreground resume should restart them automatically.",
)
require(
    "func analyzeAsync(audioURL: URL, episodeHash: String) async throws -> [ICAudioSegment]" in audio_source and
    "unsafeAnalyzer.cancelAnalysis()" in audio_source and
    "try await self.analyzer.analyzeAsync(audioURL: audioURL, episodeHash: episodeHash)" in queue_source,
    "Audio analysis is no longer directly awaited/cancellable, so cancelling the queue can leave SoundAnalysis running.",
)
require(
    "if didCancelCurrent {\n            analyzer.cancelAnalysis()" in queue_source,
    "Removing a queued item can again cancel the active audio analysis for another episode.",
)
require(
    "Pass 1/2: Themenwechsel in Kontextfenster %d von %d werden extrahiert." in chapter_source and
    "Pass 2/2: Kapitelmodell erstellt die finale JSON-Struktur. Das kann mehrere Minuten dauern." in chapter_source,
    "Chapter generator lost the detailed multi-pass progress messages.",
)
require(
    "markersFittingFinalPrompt(markers:" in chapter_source and
    "promptFitsContext(_ prompt: String" in chapter_source and
    "buildMarkerConsolidationPrompt(markers:" in chapter_source and
    "groups.replaceSubrange(groupIndex...groupIndex" in chapter_source,
    "Chapter generator no longer hierarchically reduces topic markers before the final prompt, so 2h+ podcasts can exceed the Apple model context window.",
)
require(
    "Kapitelerkennung fehlgeschlagen — die Folge ist zu lang für eine verlässliche Kapitelstruktur." in chapter_source,
    "Long-podcast chapter generation no longer fails explicitly when markers cannot be reduced safely.",
)
require(
    "private static func normalizedChapters(_ chapters: [ICGeneratedChapter]," in chapter_source and
    "forceContinuousBoundaries: existingChapters == nil" in chapter_source,
    "Chapter generator no longer normalizes final LLM chapter boundaries before saving.",
)
require(
    "SRT geschrieben" in engine_source and
    "Checkpoint geladen" in engine_source and
    "Checkpoint entfernt" in engine_source,
    "Transcription engine lost detailed file-level diagnostics for SRT/checkpoint write-read-delete operations.",
)
require(
    "Kapiteldatei geschrieben" in chapter_source and
    "Kapiteldatei geladen" in chapter_source and
    "Atomare Episodenanalyse geschrieben" in chapter_source and
    "KI-Zusammenfassung aus Episodenanalyse geladen" in chapter_source and
    "Generiertes Analyseartefakt entfernt" in chapter_source,
    "Chapter generator no longer logs chapter/analysis file writes, reads, and deletes with file snapshots.",
)
require(
    "Musik-Timeline geschrieben" in audio_source and
    "Musik-Timeline geladen" in audio_source,
    "Audio analyzer no longer logs music timeline cache writes/reads with file snapshots.",
)
require(
    "Transcript-Cache gespeichert" in player_info_source and
    "Transcript-Cache geladen" in player_info_source and
    "Transcript-HTTP-Antwort erhalten" in player_info_source,
    "Player transcript loading no longer logs cache/network read paths, making on-device playback failures opaque again.",
)
require(
    "[[TranscriptionEngine shared] transcriptCacheDirectory]" not in player_info_source and
    "[[TranscriptionEngine shared] srtURLFor:" not in player_info_source and
    "[[[TranscriptionEngine shared] transcriptCacheDirectory] path]" not in cache_manager_source and
    "[[[TranscriptionEngine shared] transcriptCacheDirectory] path]" not in episode_model_source,
    "ObjC hot paths still fetch transcript file paths through the MainActor-bound TranscriptionEngine singleton, which can stall startup/playback when background loaders or UI lists hit those paths.",
)
require(
    "Generierte Kapitel für Playback geladen" in playback_source and
    "Eingebettete Medien-Kapitel für Playback geladen" in playback_source,
    "Playback manager no longer logs whether playback used generated chapters or embedded media chapters.",
)
require(
    "removeGeneratedChapters(for episode: CDEpisode)" in chapter_source,
    "Generated chapter deletion no longer has a single owner-aware path.",
)
require(
    "func saveChaptersThrowing(_ chapters: [ICGeneratedChapter], for episodeHash: String) throws" in chapter_source and
    "try chapterGen.saveChaptersThrowing(chapters, for: episodeHash)" in queue_source and
    "try await self.saveSemanticArtifacts(semanticArtifacts, for: episodeHash)" in queue_source,
    "Chapter persistence errors are being swallowed again instead of being surfaced to the queue/log.",
)
require(
    "removeChaptersJSON(for: episodeHash)" not in engine_source,
    "Deleting a transcript should not silently delete generated chapters; the UI has a separate chapter deletion action.",
)
require(
    "TranscriptionLogger.shared.clearLog(episodeHash: episodeHash)" in engine_source,
    "Deleting a generated transcript no longer clears its stale process log.",
)
require(
    "ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: \"transcript-removed\")" in engine_source and
    "ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: \"chapters-saved\")" in chapter_source and
    "ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: \"chapters-removed\")" in chapter_source,
    "Transcript/chapter save-delete paths no longer emit artifact snapshots into the device diagnostics log.",
)
require(
    "[[ICDiagnosticLogger shared] start];" in app_delegate_source and
    'recordLifecycle:@"applicationDidFinishLaunching"' in app_delegate_source and
    'recordLifecycle:@"sceneDidBecomeActive"' in scene_delegate_source and
    'recordLifecycle:@"sceneDidEnterBackground"' in scene_delegate_source,
    "App/scene lifecycle is no longer connected to the device diagnostics log.",
)
require(
    'return [ICTranscriptionPaths transcriptCacheDirectory];' in player_info_source and
    'return [[ICTranscriptionPaths transcriptCacheDirectory] path];' in cache_manager_source and
    '[[ICTranscriptionPaths transcriptCacheDirectory] path]' in episode_model_source,
    "Some transcript cache code paths still bypass the shared Files-app-visible transcript directory.",
)
require(
    "BOOL hasGeneratedChapters = [[ChapterGenerator shared] hasChaptersFor:self.episode.objectHash];" in episode_controller_source and
    "BOOL hasGeneratedChapters = [[ChapterGenerator shared] hasChaptersFor:episode.objectHash];" in episodes_controller_source,
    "Generated-chapter delete actions must be gated by generated JSON ownership, not by podcast-provided CDChapter rows.",
)
require(
    "If the user generated chapters, make that explicit choice win." in playback_source and
    "chapters = parser.metadataAsset.chapters;" in playback_source,
    "Playback no longer prefers user-generated chapters before embedded chapters, so generation can appear to do nothing.",
)
require(
    "Vorhandene Podcast-Kapitel bleiben erhalten und werden um erkannte Sponsorsegmente ergänzt." in settings_source and
    "Zusammenfassungen benötigen ein Remote-Kapitelmodell." in settings_source,
    "Settings UI no longer explains publisher-chapter preservation, sponsor overlays, and the remote-summary requirement.",
)
require(
    "[processingTask setTaskCompletedWithSuccess:success]" in app_delegate_source and
    "queue.currentItem == nil" in app_delegate_source,
    "Background transcription tasks are no longer completed when the queue finishes.",
)

require(
    "cell.sizeLabel.numberOfLines = 2;" in controller_source,
    "Queue UI no longer allows two-line status text for detailed updates.",
)
for old_text in [
    "Im Hintergrund transkribieren",
    "WhisperKit verarbeitet Podcasts im Hintergrund.",
    "Hintergrund-Transkription",
]:
    require(
        f'NSLocalizedString(@"{old_text}", nil)' not in controller_source,
        f"Background processing UI still exposes the transcription/provider-specific text '{old_text}'.",
    )

continued_background_start = controller_source.find("- (void)_submitContinuedBackgroundTask")
continued_background_end = controller_source.find("- (void)_presentBackgroundExplanationIfNeeded", continued_background_start)
continued_background_body = controller_source[continued_background_start:continued_background_end]
require(
    continued_background_start >= 0
    and continued_background_end > continued_background_start
    and 'NSLocalizedString(@"Transkription läuft", nil)' not in continued_background_body,
    "The continued-background task title still labels every job as transcription.",
)

for new_text in [
    "Im Hintergrund verarbeiten",
    "Verarbeitung läuft",
    "Instacast verarbeitet Podcasts im Hintergrund.",
    "Hintergrundverarbeitung",
    "Die Anfrage wurde an iOS übergeben. Sobald iOS Rechenzeit gewährt, läuft die Verarbeitung im Hintergrund. Wird sie unterbrochen, bleiben Fortschritt und Warteschlange erhalten; fortgesetzt wird beim nächsten verfügbaren Hintergrundlauf oder App-Start.",
]:
    require(
        f'NSLocalizedString(@"{new_text}", nil)' in controller_source,
        f"Background processing UI is missing the lifecycle-accurate text '{new_text}'.",
    )
    require(f'"{new_text}" =' in de_strings, f"German localization is missing '{new_text}'.")
    require(f'"{new_text}" =' in en_strings, f"English localization is missing '{new_text}'.")

for paused_text in [
    "Verarbeitung pausiert",
    "Verarbeitung pausiert (%d%%)",
    "Verarbeitung pausiert (%d%%, %@ verbleibend)",
]:
    require(
        f'NSLocalizedString(@"{paused_text}", nil)' in controller_source,
        f"Paused background work is not rendered provider-neutrally as '{paused_text}'.",
    )
    require(f'"{paused_text}" =' in de_strings, f"German localization is missing '{paused_text}'.")
    require(f'"{paused_text}" =' in en_strings, f"English localization is missing '{paused_text}'.")

require(
    'NSLocalizedString(@"Transkription pausiert", nil)' not in controller_source
    and 'NSLocalizedString(@"Transkription pausiert (%d%%)", nil)' not in controller_source
    and 'NSLocalizedString(@"Transkription pausiert (%d%%, %@ verbleibend)", nil)' not in controller_source,
    "Background-paused analysis is still mislabeled as paused transcription.",
)

blocked_model_text = "Modell kann während einer laufenden Transkription oder Episodenanalyse nicht geändert werden."
require(
    f'NSLocalizedString(@"{blocked_model_text}", nil)' in settings_source
    and 'NSLocalizedString(@"Modell kann während der Transkription nicht geändert werden.", nil)' not in settings_source,
    "The model-library header still says only transcription can block model changes.",
)
require(f'"{blocked_model_text}" =' in de_strings, "German model-block localization is missing.")
require(f'"{blocked_model_text}" =' in en_strings, "English model-block localization is missing.")

completed_status_start = controller_source.find("case ICTranscriptionStatusCompleted:")
completed_status_end = controller_source.find("case ICTranscriptionStatusFailed:", completed_status_start)
completed_status_body = controller_source[completed_status_start:completed_status_end]
require(
    completed_status_start >= 0 and completed_status_end > completed_status_start,
    "Could not inspect the completed transcription-row status branch.",
)
for completed_text in [
    "Transkription fertig ✓",
    "Episodenanalyse fertig ✓",
    "Transkription und Episodenanalyse fertig ✓",
]:
    require(
        f'NSLocalizedString(@"{completed_text}", nil)' in completed_status_body,
        f"Completed queue rows cannot distinguish '{completed_text}'.",
    )
    require(f'"{completed_text}" =' in de_strings, f"German localization is missing '{completed_text}'.")
    require(f'"{completed_text}" =' in en_strings, f"English localization is missing '{completed_text}'.")
require(
    "item.chapterOnly" in completed_status_body and "item.shouldGenerateAnalysis" in completed_status_body,
    "Completed queue-row wording is not derived from the persisted job intent.",
)
require(
    "hasActiveBackgroundExecutionGrant" in controller_source
    and 'NSLocalizedString(@"Hintergrund angefordert …", nil)' in controller_source,
    "A submitted background request is still presented as an active iOS execution grant.",
)
require(
    'isEqualToString:NSLocalizedString(@"Verarbeitung im Hintergrund pausiert. Wird mit verfügbarer Rechenzeit automatisch fortgesetzt.", nil)' in controller_source
    and 'isEqualToString:NSLocalizedString(@"Transkription im Hintergrund pausiert. Wird beim Zurückkehren automatisch fortgesetzt.", nil)' not in controller_source,
    "The queue view does not recognize the current persisted background-pause status.",
)
require(
    "item.automaticallyScheduled && item.nextRetryAt != nil" in controller_source
    and "_automaticRetryHeadlineForItem:" in controller_source
    and 'NSLocalizedString(@"Automatischer neuer Versuch um %@", nil)' in controller_source,
    "Queued automatic retries are still shown as generic interruptions instead of their scheduled retry time.",
)
require(
    "item.progressBaselineStartedAt" in controller_source
    and "item.progressBaseline" in controller_source
    and "progressDelta" in controller_source
    and "remainingProgress / progressDelta" in controller_source
    and "(1.0 - item.progress) / item.progress" not in controller_source,
    "Remaining-time estimates still combine resumed absolute progress with only the current run's elapsed time.",
)
require(
    'stringWithFormat:@"%@ — %@", trimmedHeadline, trimmedDetail' in controller_source,
    "Live phase detail is still discarded as soon as a progress percentage is available.",
)
for phase, label in [
    ("automatic", "Automatische Verarbeitung"),
    ("transcript-import", "Podcast-Transkript"),
    ("recovery", "Wiederherstellung"),
    ("retry", "Neuer Versuch"),
]:
    require(
        f'[phase isEqualToString:@"{phase}"]' in controller_source
        and f'NSLocalizedString(@"{label}", nil)' in controller_source,
        f"The visible transcription log still exposes the raw phase tag '{phase}'.",
    )
    require(f'"{label}" =' in de_strings, f"German localization is missing '{label}'.")
    require(f'"{label}" =' in en_strings, f"English localization is missing '{label}'.")

for text in [
    "Hintergrund angefordert …",
    "Automatischer neuer Versuch um %@",
]:
    require(f'"{text}" =' in de_strings, f"German localization is missing '{text}'.")
    require(f'"{text}" =' in en_strings, f"English localization is missing '{text}'.")

background_pause_start = queue_source.find("private func finishBackgroundPause(")
background_pause_end = queue_source.find("// MARK: - Processing", background_pause_start)
background_pause = queue_source[background_pause_start:background_pause_end]
require(
    'message: "Verarbeitung im Hintergrund pausiert"' in background_pause
    and 'message: "Transkription im Hintergrund pausiert"' not in background_pause,
    "Background pause logs still mislabel chapter/sponsor/summary analysis as transcription.",
)
require(
    "updateDownloadStatusAfterSpeechModelPreparation" in queue_source
    and 'NSLocalizedString("Episode wird heruntergeladen.", comment: "")' in queue_source
    and 'NSLocalizedString("Episode wird heruntergeladen. Modellvorbereitung fehlgeschlagen.", comment: "")' in queue_source,
    "Episode-download status can remain stuck on speech-model preparation after it completed or failed.",
)
require(
    "audioAnalysisError" in queue_source
    and 'message: NSLocalizedString("Audioanalyse fehlgeschlagen", comment: "")' in queue_source
    and 'NSLocalizedString("Verarbeitung wird ohne Audiohinweise fortgesetzt.", comment: "")' in queue_source,
    "A failed optional audio analysis is still reported to users as successfully completed.",
)

transcribe_start = backend_source.find("func transcribe(audioURL: URL")
transcribe_end = backend_source.find("// MARK: -", transcribe_start + 20)
transcribe_body = backend_source[transcribe_start:transcribe_end]
require(
    'statusUpdate(NSLocalizedString("Audioblock wird geladen.", comment: ""))' in transcribe_body
    and 'statusUpdate(NSLocalizedString("Transkription läuft. Warte auf das erste Segment.", comment: ""))' in transcribe_body
    and transcribe_body.find('"Audioblock wird geladen."')
    < transcribe_body.find("AudioProcessor.loadAudioAsFloatArray")
    < transcribe_body.find('"Transkription läuft. Warte auf das erste Segment."'),
    "Whisper status says transcription is running before the current audio slice has loaded.",
)

for text in [
    "Episode wird heruntergeladen.",
    "Episode wird heruntergeladen. Modellvorbereitung fehlgeschlagen.",
    "Audioanalyse fehlgeschlagen",
    "Verarbeitung wird ohne Audiohinweise fortgesetzt.",
    "Audioblock wird geladen.",
    "Transkription läuft. Warte auf das erste Segment.",
]:
    require(f'"{text}" =' in de_strings, f"German localization is missing '{text}'.")
    require(f'"{text}" =' in en_strings, f"English localization is missing '{text}'.")
require(
    "if ([TranscriptionQueue shared].items.count == 0)" in controller_source
    and "[self setToolbarItems:@[] animated:animated]" in controller_source
    and "_updateToolbarItemsAnimated" in controller_source,
    "The transcription queue toolbar must hide the cancel-all button when the queue has no visible items.",
)
require(
    "Transkription wird gestartet" not in controller_source
    and "Transkription läuft" in controller_source
    and "Transkription läuft." in backend_source,
    "The transcription row still says it is starting after transcription is already running.",
)
require(
    "Core ML öffnet das Whisper-Modell." not in queue_source
    and "Core ML öffnet das Whisper-Modell." not in controller_source,
    "Queue UI/status code still exposes technical Core ML model-loading text.",
)
require(
    "_singleStatusTextWithHeadline" in controller_source and
    "_elapsedTextForItem" in controller_source and
    "_presentFailureDetailsForItem" in controller_source,
    "Queue UI no longer composes detailed status text, elapsed time, and failure alerts.",
)
require(
    "_presentRecoveryActionsForItem:" in controller_source
    and "_deleteFailedOrInterruptedItem:" in controller_source
    and "Neustarten" in controller_source
    and "Aus Liste löschen" in controller_source
    and "[[TranscriptionQueue shared] retryProcessing]" not in controller_source,
    "Tapping a failed/interrupted transcription row must ask whether to restart or delete instead of retrying immediately.",
)
require(
    "item.status == ICTranscriptionStatusQueued && item.error.length > 0" in controller_source
    and "item.status == ICTranscriptionStatusFailed" in controller_source
    and "[self _presentRecoveryActionsForItem:item]" in controller_source,
    "Failed and interrupted queue rows are not routed through the same restart/delete action sheet.",
)
require(
    "_statusDetail:(NSString*)detail duplicatesHeadline:" in controller_source
    and "stringByReplacingOccurrencesOfString:@\"\\\\([^)]*%[^)]*\\\\)\"" in controller_source,
    "Queue rows can still show near-duplicate headline/detail status text.",
)
require(
    "cleanupBrokenArtifacts(for item: ICTranscriptionQueueItem)" in queue_source
    and "ChapterGenerator.shared.invalidateChaptersCache(for: episodeHash)" in cleanup_body
    and "removeGeneratedChapters" not in cleanup_body
    and "engine.removeSRT(for: episodeHash)" in queue_source,
    "Retry/delete of failed rows must clean broken transcripts without deleting the last good generated chapters.",
)
require(
    "removeTranscriptCacheFiles(for episodeHash: String)" in engine_source
    and 'pathExtension == "trcache"' in engine_source,
    "Removing a broken transcript no longer deletes stale .trcache transcript cache files.",
)
require(
    "@objc(removeGeneratedChaptersForEpisodeHash:)" in chapter_source
    and "_chapter_debug.json" in chapter_source
    and "Chapter-Debug entfernt" in chapter_source,
    "Removing broken generated chapters does not clean the chapter JSON and chapter debug artifact by episode hash.",
)

for text in [
    "Modell wird vorbereitet.",
    "Spracherkennungsmodell wird vorbereitet",
    "Spracherkennungsmodell wird geladen.",
    "Spracherkennungsmodell wird kompiliert.",
    "Spracherkennungsmodell wird heruntergeladen.",
    "Transkription läuft.",
    "Kapitel werden erstellt (%d%%)",
    "Transkriptionsfehler",
    "Job neu starten?",
    "Neustarten",
    "Aus Liste löschen",
]:
    require(f'"{text}" =' in de_strings, f"German localization is missing '{text}'.")
    require(f'"{text}" =' in en_strings, f"English localization is missing '{text}'.")
