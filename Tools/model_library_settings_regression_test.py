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


require(
    "Granite 3.3 2B Instruct" in engine_source
    and "shortTitle: \"Granite 3.3\"" in engine_source
    and "granite-3.3-2b-instruct-GGUF/resolve/main/granite-3.3-2b-instruct-Q4_K_M.gguf" in engine_source
    and "1_545_303_328" in engine_source,
    "Granite 3.3 2B is missing from the downloadable chapter model catalog.",
)
require(
    "Gemma 4 E2B-it" in engine_source
    and "shortTitle: \"Gemma 4\"" in engine_source
    and "gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K.gguf" in engine_source
    and "2_629_991_680" in engine_source,
    "Gemma 4 E2B-it is missing from the downloadable chapter model catalog.",
)
gemma_index = engine_source.find('identifier: "gemma-4-e2b-it-q4-k"')
granite_index = engine_source.find('identifier: "granite-3.3-2b-instruct-q4-k-m"')
require(
    gemma_index != -1 and granite_index != -1 and gemma_index < granite_index,
    "Gemma 4 must be listed above Granite in the chapter model list.",
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
    and "Voice to Text" in settings_source
    and "Text zu Kapitel" in settings_source,
    "Settings does not provide dedicated voice/chapter model subpages.",
)
require(
    "case TSSectionModels: return 2;" in settings_source
    and "Modelle verwalten" not in settings_source,
    "Settings should open separate voice/text model pages directly instead of showing a separate manage-models row.",
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
    '"Modelle werden bei Bedarf heruntergeladen und danach vorbereitet."' in de_strings
    and '"Modelle werden bei Bedarf heruntergeladen und danach vorbereitet."' in en_strings
    and '"Wähle das Modell für Transkriptionen. Wenn es fehlt, wird es heruntergeladen und vorbereitet."' in en_strings
    and '"Wähle das Modell für Kapitel. Wenn es fehlt, wird es heruntergeladen und vorbereitet."' in en_strings,
    "New user-facing model settings strings must be localized instead of falling back to German.",
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
    and "model.identifier == \"apple-foundation-models\"" in engine_source
    and "modelFileURL(for: model) != nil" in engine_source
    and "selectedChapterModelCanGenerate" in episode_source
    and "selectedChapterModelCanGenerate" in episodes_source
    and "selectedChapterModelCanGenerate" in queue_source,
    "Downloaded GGUF chapter models must be allowed only when their local model file is present.",
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
    and "Modell kann gerade nicht geändert werden" in settings_source
    and "return nil;" in settings_source,
    "The model settings UI still allows model selection or destructive actions while that model role is active.",
)
require(
    'case "deleteChapterModel":' in (ROOT / "Classes" / "ICTranscriptionDebugAutomation.swift").read_text()
    and '"deleteBlockedReason"' in (ROOT / "Classes" / "ICTranscriptionDebugAutomation.swift").read_text(),
    "Remote transcription automation cannot exercise blocked chapter-model deletion during a live job.",
)
