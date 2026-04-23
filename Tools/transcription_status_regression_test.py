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

require(
    "ICTranscriptionInternalStatusDetailNotification" in queue_source,
    "Transcription queue no longer has an internal status-detail notification bridge.",
)
require(
    "@objc var statusDetail: String?" in queue_source and "@objc var statusStartedAt: Date?" in queue_source,
    "Queue items no longer persist detail text and step start times for UI status reporting.",
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
    "try await self.chapterGen.generateChaptersAsync(" in queue_source,
    "Transcription queue is no longer awaiting chapter generation directly, so cancel/remove can leave stale LLM work running.",
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
    "Pass 1/2: Themenwechsel in Abschnitt %d von %d werden extrahiert." in chapter_source and
    "Pass 2/2: Finale Kapitelstruktur wird erstellt." in chapter_source,
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
    "Kapiteldatei entfernt" in chapter_source,
    "Chapter generator no longer logs persisted chapter file writes/reads/deletes with file snapshots.",
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
    "try self.chapterGen.saveChaptersThrowing(chapters, for: episodeHash)" in queue_source,
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
    "Folgen mit vorhandenen Kapiteln bleiben unverändert." in settings_source and
    "nur Sponsor-Erkennung durchgeführt" not in settings_source,
    "Settings UI is again promising sponsor detection for existing chapters that the queue does not perform.",
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
require(
    "_combinedStatusTextWithHeadline" in controller_source and
    "_elapsedTextForItem" in controller_source and
    "_presentFailureDetailsForItem" in controller_source,
    "Queue UI no longer composes detailed status text, elapsed time, and failure alerts.",
)

for text in [
    "Core ML öffnet das Whisper-Modell.",
    "Whisper startet die Dekodierung.",
    "Kapitel werden erstellt (%d%%)",
    "Transkriptionsfehler",
]:
    require(f'"{text}" =' in de_strings, f"German localization is missing '{text}'.")
    require(f'"{text}" =' in en_strings, f"English localization is missing '{text}'.")
