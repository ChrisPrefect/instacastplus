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
    "pauseWhisperKitForBackgroundIfNeeded()" in queue_source
    and "Transkription im Hintergrund pausiert" in queue_source
    and "applicationDidEnterBackground" in queue_source,
    "WhisperKit transcription is not paused when the app enters background.",
)
require(
    "TranscriptionEngine.isBackgroundGPUExecutionError(error)" in queue_source
    and "finishBackgroundPause" in queue_source,
    "Queue does not turn the known background-GPU error into a resumable pause.",
)
require(
    "@objc func retry(episodeHash: String)" in queue_source
    and "resetCheckpointFailureCounter" in engine_source
    and "retryWithEpisodeHash" in controller_source,
    "Failed transcription rows cannot be restarted cleanly.",
)
require(
    "segmentCallback: liveSegmentCallback" in backend_source
    and "deliveredSegmentKeys" in backend_source,
    "WhisperKit segments are still only delivered after the full transcription returns.",
)
require(
    "prewarm: true" in backend_source
    and "removeOriginalModelSources" in backend_source
    and "Whisper-Modell vorgewärmt" in backend_source,
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
    and "accessoryReservedWidth" in cell_source,
    "Download/transcription cell layout does not reserve space for the info accessory.",
)
require(
    "WhisperKit nutzt Core ML/GPU. Im Hintergrund läuft es nur über iOS 26 Background GPU Access" in settings_source
    and "Hintergrund möglich" in settings_source
    and "iOS 26 GPU-Hintergrund" in settings_source,
    "Model settings do not explain the foreground/background tradeoff.",
)
require(
    "willBeginEditingRowAtIndexPath" in controller_source
    and "didEndEditingRowAtIndexPath" in controller_source
    and "swipeInteractionActive" in controller_source
    and "if (self.swipeInteractionActive) return;" in controller_source,
    "Swipe-to-delete still allows progress reloads during the swipe gesture.",
)
require(
    "musicBoundaryChapters" in chapter_source
    and "Kapitel aus Musikgrenzen ergänzt" in chapter_source,
    "Detected intro/outro music segments are not converted into structural chapter boundaries.",
)
