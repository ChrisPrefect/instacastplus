from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


engine = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
backend = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
queue = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
settings = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
controller = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
app_delegate = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
iphone_plist = (ROOT / "Resources-iPhone" / "Instacast-Info.plist").read_text()
ipad_plist = (ROOT / "Resources-iPad" / "Instacast HD-Info.plist").read_text()


# Whisper downloads must expose the actual Hub transfer and every subsequent
# preparation phase. A validated folder is not yet a user-visible ready state
# while the same task is still specializing or loading it.
require(
    "enum ICModelDownloadPhase" in engine
    and "@objc let phase" in engine
    and "@objc let statusText" in engine
    and "@objc var displayText" in engine,
    "Model download progress still has no explicit download/preparation/loading phases.",
)
require(
    "WhisperKit.download(" in backend
    and "progressCallback:" in backend
    and "hubProgress.fractionCompleted" in engine,
    "WhisperKit download progress still comes from final-folder size instead of Hub transfer telemetry.",
)
require(
    "selected && !busy && (downloaded || !model.requiresDownload)" in settings
    and settings.find("if (busy) {") < settings.find("else if (downloaded || !model.requiresDownload)"),
    "A busy model can still show a ready checkmark before preparation/loading finishes.",
)
download_body = engine.split(
    "@objc(downloadModel:detailProgress:completion:)", 1
)[1].split("private static func setActiveDownloadTask", 1)[0]
require(
    download_body.find("clearActiveDownload(for: selectedModel)")
    < download_body.find("completionCallback(nil)"),
    "The model store still invokes completion while its global task remains busy.",
)


# One OpenAI key is valid for both GPT-5.6 API models. Sol may retain Codex
# login as an additional route, but must prefer the configured API key and use
# the durable Responses API path when it is present.
sol_model = engine.split(
    'identifier: "openai-codex-gpt-5.6-sol-oauth"', 1
)[1].split("ICDownloadableModel(", 1)[0]
require(
    "OpenAI API-Key oder Codex Login" in sol_model,
    "GPT-5.6 Sol still claims that only a separate Codex login can unlock it.",
)
require(
    "hasOpenAIAPIKey() || ICRemoteChapterCredentialStore.hasOpenAIOAuthCredentials()" in engine
    and "hasOpenAIAPIKey] || [ICRemoteChapterCredentialStore hasOpenAIOAuthCredentials]" in settings,
    "Sol readiness does not accept the same OpenAI API key used by Terra.",
)
remote_generator = (ROOT / "Classes" / "ChapterGenerator.swift").read_text().split(
    "private func generateRemoteJSONObject(", 1
)[1]
codex_route = remote_generator.split("case .openAICodexOAuth:", 1)[1].split(
    "case .anthropicAPI:", 1
)[0]
require(
    "openAIAPIKey()" in codex_route
    and "generateOpenAIAPIJSONObject" in codex_route
    and "generateOpenAICodexOAuthJSONObject" in codex_route,
    "Sol does not prefer an OpenAI API key while preserving Codex login as an alternative.",
)
require(
    '[pasteButton setTitle:NSLocalizedString(@"Einfügen", nil)' in settings
    and "UIPasteboard.generalPasteboard.string" in settings,
    "API-key dialogs still have no explicit paste button.",
)


# Delivery of a BGContinued task while the app is active is a grant, not a
# background lifecycle transition. The applied Whisper compute path changes
# only when the scene actually enters/leaves the background.
require(
    "appliedWhisperKitExecutionPath" in queue,
    "The queue still conflates the delivered background grant with the applied Whisper compute profile.",
)
did_enter = queue.split("UIApplication.didEnterBackgroundNotification", 1)[1].split(
    "UIApplication.willEnterForegroundNotification", 1
)[0]
will_enter = queue.split("UIApplication.willEnterForegroundNotification", 1)[1].split(
    "reconcilePersistedAutomaticDiscoveryOutbox", 1
)[0]
require(
    "applyGrantedWhisperKitExecutionPathForCurrentLifecycle" in did_enter
    and "applyForegroundWhisperKitExecutionPath" in will_enter
    and "resumeIfNeeded()" in will_enter,
    "Whisper compute profiles are not switched at the real background/foreground boundaries.",
)
activate = queue.split("func activateBackgroundExecutionPath(path: String, detail: String)", 1)[1].split(
    "@objc(completeBackgroundExecutionPathWithSuccess:reason:)", 1
)[0]
require(
    "beginWhisperKitComputeProfileTransitionIfNeeded" not in activate
    and "WhisperKitBackend.setActiveBackgroundExecutionPath(path)" not in activate,
    "A foreground BGContinued grant still aborts the running GPU transcription immediately.",
)


# iOS 26 requires a wildcard registration identifier and a unique concrete ID
# per continued-processing job. This also prevents stale jobs from being reused
# as a second Live Activity.
require(
    "transcription.continued.*" in iphone_plist
    and "transcription.continued.*" in ipad_plist
    and 'ICTranscriptionContinuedTaskIdentifierPattern = @"com.iteconomy.instacastplus.transcription.continued.*"' in app_delegate
    and "ICTranscriptionActiveContinuedIdentifier" in app_delegate
    and "ICTranscriptionActiveContinuedIdentifier" in controller
    and "NSUUID.UUID.UUIDString" in controller,
    "Continued-processing tasks still reuse one non-wildcard identifier across Live Activities.",
)
require(
    "continuedTask.identifier" in app_delegate
    and "episodeTitle" in app_delegate
    and "statusDetail" in app_delegate
    and "updateTitle" in app_delegate,
    "The continued task still exposes only a generic Live Activity instead of episode/stage progress.",
)


# A profile switch may reuse the persisted music timeline, and normal model
# reloads must not run WhisperKit prewarm/specialization again. Both compute
# profiles are prepared once as part of initial model preparation.
require(
    "hasCachedTimeline(for: episodeHash)" in queue
    and "Audioanalyse aus gespeichertem Ergebnis übernommen" in queue,
    "A resumed transcription still presents cached SoundAnalysis work as a fresh audio analysis.",
)
normal_load = backend.split("func getOrCreateWhisperKit", 1)[1].split(
    "func prepareModel(statusUpdate", 1
)[0]
require(
    "prewarm: false" in normal_load
    and "prewarm: true" not in normal_load,
    "Every ordinary WhisperKit reload still re-runs model prewarm/specialization.",
)
require(
    "prepareDownloadedModelForAllComputeProfiles" in backend,
    "Foreground and background Whisper compute profiles are not prepared once after download.",
)


# Queued and failed jobs use the queue's ordinary row-selection interaction.
selection = controller.split(
    "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath",
    1,
)[1].split("- (void)_rebuildEpisodeCacheForCurrentItems", 1)[0]
require(
    "UILongPressGestureRecognizer" not in controller
    and "item.status == ICTranscriptionStatusQueued || item.status == ICTranscriptionStatusFailed" in selection
    and "_presentRecoveryActionsForItem:item" in selection,
    "Ordinary tap recovery for queued/failed transcription rows is missing.",
)


# New user-facing settings and lifecycle status strings must be localized in
# both supported languages. API credentials already use the existing Keychain
# store, so no new backup/default contract is introduced.
german = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
english = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
for localization_key in (
    "Einfügen",
    "Download wird vorbereitet.",
    "Wird heruntergeladen",
    "Spracherkennungsmodell wird in den Arbeitsspeicher geladen.",
    "Modell wird einmalig für die Hintergrundverarbeitung vorbereitet.",
    "Modell wird einmalig für die Vordergrundverarbeitung vorbereitet.",
    "OpenAI API-Key oder Codex Login fehlt.",
    "Podcast-Verarbeitung",
    "Kapitel und Zusammenfassung werden erstellt.",
):
    declaration = f'"{localization_key}" = '
    require(
        declaration in german and declaration in english,
        f"Missing German/English localization for: {localization_key}",
    )

print("reported transcription regressions: ok")
