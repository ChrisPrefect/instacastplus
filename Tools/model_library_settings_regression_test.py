from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


engine_source = (ROOT / "Classes" / "TranscriptionEngine.swift").read_text()
settings_source = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()
settings_header = (ROOT / "Classes" / "TranscriptionSettingsViewController.h").read_text()
episode_source = (ROOT / "Classes" / "EpisodeViewController.m").read_text()
episodes_source = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
backend_source = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
chapter_source = (ROOT / "Classes" / "ChapterGenerator.swift").read_text()
local_runner_source = (ROOT / "Classes" / "LocalGGUFModelRunner.swift").read_text()
project_source = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()
de_strings = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()
en_strings = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
model_catalog_source = engine_source.split(
    "private static let models: [ICDownloadableModel] = [", 1
)[1].split("\n    ]", 1)[0]
options_footer_source = (ROOT / "Classes" / "OptionsViewController.m").read_text().split(
    "- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section", 1
)[1].split(
    "- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section", 1
)[0]


require(
    "Gemma 4 E2B-it" in engine_source
    and "shortTitle: \"Gemma 4\"" in engine_source
    and "gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K.gguf" in engine_source
    and "2_629_991_680" in engine_source,
    "Gemma 4 E2B-it is missing from the downloadable chapter model catalog.",
)
chapter_model_order = [
    'identifier: "openai-codex-oauth"',
    'identifier: "openai-chatgpt-5.5-api-key"',
    'identifier: "kimi-k2.6-api-key"',
    'identifier: "anthropic-claude-opus-4.7-api-key"',
    'identifier: "gemma-4-e2b-it-q4-k"',
    'identifier: "apple-foundation-models"',
]
chapter_model_indices = [model_catalog_source.find(marker) for marker in chapter_model_order]
require(
    all(index != -1 for index in chapter_model_indices)
    and chapter_model_indices == sorted(chapter_model_indices)
    and "Lokales Modell mit sehr großem Download. Qualität schwankt je nach Folge." in engine_source,
    "Chapter model order/copy must put Codex before OpenAI API, Gemma near the end with honest copy, and Apple Intelligence last.",
)
require(
    "MARKETING_VERSION = 3.5;" in project_source
    and "MARKETING_VERSION = 3.3;" not in project_source
    and 'CGRectMake(0, 0, tableView.frame.size.width, 170)' in options_footer_source
    and 'CGRectMake(20, 5, footerView.frame.size.width-40, 170)' in options_footer_source
    and '"\\nVersion %@ (%@)\\nPublisher: Chris Thomann \\nOriginally developed by Martin Hering \\nThank you Martin!"' in options_footer_source
    and "[NSBundle buildVersion]" in options_footer_source
    and "Developer:" not in options_footer_source
    and "Claude" not in options_footer_source
    and "Opus" not in options_footer_source
    and "Codex" not in options_footer_source
    and "Devendra" not in options_footer_source
    and "Tasia" not in options_footer_source
    and "Build " not in options_footer_source
    and "CFBundleVersion" not in options_footer_source,
    "Version must be 3.5 and the options footer must keep original credits, show build behind version, and remove developer names.",
)
require(
    "ICChapterModelProvider" in engine_source
    and "openai-chatgpt-5.5-api-key" in engine_source
    and 'remoteModelName: "gpt-5.5"' in engine_source
    and "openai-codex-oauth" in engine_source
    and "OpenAI Codex" in engine_source
    and "anthropic-claude-opus-4.7-api-key" in model_catalog_source
    and 'remoteModelName: "claude-opus-4-7"' in model_catalog_source
    and "kimi-k2.6-api-key" in model_catalog_source
    and 'remoteModelName: "kimi-k2.6"' in model_catalog_source,
    "Remote chapter models must offer OpenAI API key, OpenAI Codex login, Anthropic Claude Opus 4.7, and Kimi K2.6.",
)
require(
    "ICRemoteChapterCredentialStore" in engine_source
    and "kSecClassGenericPassword" in engine_source
    and "requestOpenAIDeviceCodeWithCompletion" in engine_source
    and "completeOpenAIDeviceLoginWithDeviceCode" in engine_source
    and "ChatGPT-Account-ID" in chapter_source,
    "Remote chapter credentials must be stored in Keychain and ChatGPT OAuth must use device-code login with the Codex account header.",
)
require(
    "granite-3.3-2b-instruct-q4-k-m" not in model_catalog_source
    and "Granite 3.3" not in model_catalog_source
    and "granite-3.3-2b-instruct-GGUF" not in model_catalog_source,
    "Granite must not be offered as a chapter model because it produced unreliable chapters in simulator tests.",
)
require(
    'private static let defaultChapterModelIdentifier = "gemma-4-e2b-it-q4-k"' in engine_source
    and "UserDefaults.standard.set(defaultChapterModelIdentifier, forKey: chapterModelKey)" in engine_source,
    "Gemma 4 must be the chapter default, including migration from removed stored chapter models.",
)
require(
    'private static let removedTextModelIdentifiers: Set<String> = ["granite-3.3-2b-instruct-q4-k-m"]' in engine_source
    and "cleanupRemovedTextModelsIfNeeded()" in engine_source
    and "Entferntes Kapitelmodell gelöscht" in engine_source,
    "Removing Granite from the catalog must also clean up already-downloaded Granite files that the UI can no longer show.",
)
require(
    "ICDownloadableModelRole" in engine_source
    and "case voiceToText" in engine_source
    and "case textToChapters" in engine_source
    and "@objc(downloadModel:progress:completion:)" in engine_source
    and "@objc(downloadModel:detailProgress:completion:)" in engine_source
    and "@objc(deleteModel:completion:)" in engine_source
    and "@objc(prepareModel:completion:)" in engine_source,
    "The shared downloadable model store does not expose download/delete/prepare for both roles.",
)
require(
    "ICModelDownloadTask" in engine_source
    and "ICModelDownloadProgress" in engine_source
    and "@objc func cancel()" in engine_source
    and "@objc var byteText: String" in engine_source,
    "Model downloads must return a cancellable task and report user-visible byte progress.",
)
require(
    "activeDownloadTasksByModelID" in engine_source
    and "activeDownloadProgressByModelID" in engine_source
    and "@objc(downloadTaskForModel:)" in engine_source
    and "@objc(downloadProgressForModel:)" in engine_source
    and "@objc(cancelDownloadForModel:)" in engine_source
    and "isDownloadingModel" in settings_source,
    "Download state must live in the model store, not only in the currently visible settings controller.",
)
require(
    "validateTextModelFile" in engine_source
    and "GGUF" in engine_source
    and "Modell-Download ungültig" in engine_source
    and "modelFileURL(for: model) != nil" in engine_source,
    "Downloaded chapter models must be validated by size and GGUF header before they are treated as ready.",
)
require(
    "volumeAvailableCapacityForImportantUsageKey" in engine_source
    and "as? NSNumber" in engine_source
    and "Nicht genug freier Speicher" in engine_source
    and "Verfügbar" in engine_source,
    "Model download free-space checks must use the iOS available-capacity API and report required/available bytes.",
)
require(
    "modelLibraryViewControllerFocusedOnVoiceToText:" in settings_header
    and "ICModelLibraryViewController" in settings_source
    and "Transkribieren" in settings_source
    and "Kapitel generieren" in settings_source
    and "Voice to Text" not in settings_source
    and "Text zu Kapitel" not in settings_source,
    "Settings does not provide dedicated Transkribieren/Kapitel generieren model subpages.",
)
require(
    "case TSSectionModels: return 2;" in settings_source
    and "Modelle verwalten" not in settings_source,
    "Settings should open separate voice/text model pages directly instead of showing a separate manage-models row.",
)
require(
    "TSSectionCloud" in settings_source
    and "Cloud-Zugänge" in settings_source
    and "_showOpenAIAPIKeyEditor" in settings_source
    and "_showOpenAIOAuthLogin" in settings_source
    and "_showAnthropicAPIKeyEditor" in settings_source
    and "_showKimiAPIKeyEditor" in settings_source
    and "case TSSectionCloud: return 4;" in settings_source
    and "OpenAI Codex Login" in settings_source
    and "Anthropic API-Key" in settings_source,
    "Settings must expose OpenAI API key, Codex login, Anthropic API key, and Kimi API key credentials.",
)
require(
    "Gerätecode erstellen" in settings_source
    and "Code kopieren" in settings_source
    and "UIPasteboard.generalPasteboard.string = info.userCode" in settings_source
    and "https://platform.openai.com/api-keys" in settings_source
    and "https://console.anthropic.com/settings/keys" in settings_source
    and "https://platform.kimi.ai/console/api-keys" in settings_source
    and "Key erstellen" in settings_source,
    "Cloud credential UI must let users create a Codex device code and jump directly to provider API key pages.",
)
require(
    "_showCredentialSetupForModel:model" in settings_source
    and "case ICChapterModelProviderOpenAIAPI:" in settings_source
    and "case ICChapterModelProviderOpenAICodexOAuth:" in settings_source
    and "case ICChapterModelProviderAnthropicAPI:" in settings_source
    and "case ICChapterModelProviderKimiAPI:" in settings_source,
    "Selecting a remote chapter model with missing credentials must open the matching API key or Codex device-code dialog immediately.",
)
require(
    "GGUF" not in settings_source
    and "Core ML" not in settings_source
    and "GPU" not in settings_source
    and "llama.cpp" not in settings_source
    and "Unterseite" not in settings_source,
    "Model settings copy must stay user-centered and avoid implementation details.",
)
require(
    '"Modelle werden bei Bedarf heruntergeladen und danach vorbereitet."' not in de_strings
    and '"Modelle werden bei Bedarf heruntergeladen und danach vorbereitet."' not in en_strings
    and "Diese Zugangsdaten werden nur verwendet" not in settings_source
    and '"Wähle das Modell für Transkriptionen. Wenn es fehlt, wird es heruntergeladen und vorbereitet."' in en_strings
    and '"Wähle das Modell für Kapitel. Wenn es fehlt, wird es heruntergeladen und vorbereitet."' in en_strings,
    "Main transcription settings must not repeat model-download or cloud-credential hints already covered elsewhere.",
)
require(
    "Geladene Modelle kannst du per Swipe nach links löschen." in settings_source
    and '"Geladene Modelle kannst du per Swipe nach links löschen."' in de_strings
    and '"Geladene Modelle kannst du per Swipe nach links löschen."' in en_strings,
    "Model subpages must tell users that downloaded models can be deleted by swiping left.",
)
require(
    "Beste Transkriptionsgenauigkeit, Core ML/GPU" not in engine_source
    and "Kleineres Sprachmodell, Core ML/GPU" not in engine_source
    and "128k Kontext" not in engine_source
    and "GGUF" not in settings_source,
    "Downloadable model descriptions should not expose technical model/runtime details to users.",
)
require(
    "downloadTasksByModelID" in settings_source
    and "downloadProgressByModelID" in settings_source
    and "_cancelDownloadForModel:" in settings_source
    and "Abbrechen" in settings_source
    and "byteText" in settings_source,
    "The model library UI must let users cancel downloads and show x MB / total MB progress.",
)
require(
    "selected && (downloaded || !model.requiresDownload)" in settings_source
    and "Ausgewählt" in settings_source
    and "noch nicht geladen" in settings_source,
    "Undownloaded selected models must not show a checkmark and must say they still need downloading.",
)
require(
    "[ICDownloadableModelStore selectModel:model]" in settings_source
    and "_startDownloadForModel:model" in settings_source
    and "Löschen" in settings_source
    and "Vorbereiten" in settings_source,
    "Selecting a missing model must download it, with manual delete/download/prepare actions available.",
)
require(
    "selectedVoiceModelIsReady" in episode_source
    and "selectedVoiceModelIsReady" in episodes_source
    and "modelLibraryViewControllerFocusedOnVoiceToText:YES" in episode_source
    and "modelLibraryViewControllerFocusedOnVoiceToText:YES" in episodes_source,
    "Transcribe actions do not route to model settings when the selected voice model is missing.",
)
require(
    "selectedChapterModelCanGenerate" in episode_source
    and "selectedChapterModelCanGenerate" in episodes_source
    and "modelLibraryViewControllerFocusedOnVoiceToText:NO" in episode_source
    and "modelLibraryViewControllerFocusedOnVoiceToText:NO" in episodes_source
    and "selectedChapterModelIsReady" in queue_source,
    "Chapter actions do not route to model settings or guard queue work when the selected chapter model is missing.",
)
require(
    "selectedChapterModelCanGenerate" in engine_source
    and "case .appleFoundation:" in engine_source
    and "ICRemoteChapterCredentialStore.hasOpenAIAPIKey()" in engine_source
    and "ICRemoteChapterCredentialStore.hasOpenAIOAuthCredentials()" in engine_source
    and "ICRemoteChapterCredentialStore.hasAnthropicAPIKey()" in engine_source
    and "ICRemoteChapterCredentialStore.hasKimiAPIKey()" in engine_source
    and "modelFileURL(for: model) != nil" in engine_source
    and "selectedChapterModelCanGenerate" in episode_source
    and "selectedChapterModelCanGenerate" in episodes_source
    and "selectedChapterModelCanGenerate" in queue_source,
    "Chapter generation readiness must validate local GGUF files, Apple availability, and remote credentials per provider.",
)
require(
    "generateWithRemoteChapterModel" in chapter_source
    and "https://api.openai.com/v1/responses" in chapter_source
    and "https://chatgpt.com/backend-api/codex/responses" in chapter_source
    and "https://api.anthropic.com/v1/messages" in chapter_source
    and "https://api.moonshot.ai/v1/chat/completions" in chapter_source
    and "buildRemoteDirectChaptersPrompt(cues: cues" in chapter_source
    and "remoteChapterStartsSchema" in chapter_source,
    "Remote chapter generation must send the full transcript prompt to OpenAI API key, Codex OAuth, Anthropic, or Kimi and request structured chapter JSON.",
)
require(
    '"tool_choice": "auto"' in chapter_source
    and "configuration.timeoutIntervalForRequest = 5 * 60" in chapter_source,
    "Remote chapter requests must match the Responses request shape used by Codex and allow long full-transcript runs.",
)
require(
    "generateWithLocalGGUF" in chapter_source
    and "LocalGGUFModelRunner.create" in chapter_source
    and "decodeLocalJSON" in chapter_source
    and "import llama" in local_runner_source
    and "llama.xcframework" in project_source,
    "Downloaded GGUF chapter models are not wired to a real llama.cpp local runtime.",
)
require(
    "downloadModel(modelName:" in backend_source
    and "prepareModel(modelName:" in backend_source
    and "deleteModel(modelName:" in backend_source
    and "isModelDownloadedSync(modelName:" in backend_source,
    "WhisperKit backend cannot manage individual voice models from the shared model page.",
)
require(
    "modelMutationBlockReason(for role: ICDownloadableModelRole)" in queue_source
    and "modelDeletionBlockReason(for model: ICDownloadableModel)" in queue_source
    and "ICDownloadableModelStore.deleteModelBlocked" in engine_source
    and "Modell-Löschung blockiert" in engine_source,
    "Model deletion is not blocked while active transcription/chapter jobs can still use that model role.",
)
require(
    "modelMutationBlockReasonForRole" in settings_source
    and "_updateBlockedHeader" in settings_source
    and "Modell kann während der Transkription nicht geändert werden." in settings_source
    and "TranscriptionQueueViewController" in settings_source
    and "return model.detail;" in settings_source,
    "The model settings UI still puts the mutation block warning in model rows or lacks a link back to the transcription queue.",
)
require(
    'case "deleteChapterModel":' in (ROOT / "Classes" / "ICTranscriptionDebugAutomation.swift").read_text()
    and '"deleteBlockedReason"' in (ROOT / "Classes" / "ICTranscriptionDebugAutomation.swift").read_text(),
    "Remote transcription automation cannot exercise blocked chapter-model deletion during a live job.",
)
