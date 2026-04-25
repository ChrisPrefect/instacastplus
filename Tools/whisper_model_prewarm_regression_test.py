from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
SETTINGS_SOURCE = (ROOT / "Classes" / "TranscriptionSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def block_between(start: str, end: str) -> str:
    start_index = SOURCE.index(start)
    end_index = SOURCE.index(end, start_index)
    return SOURCE[start_index:end_index]


download_block = block_between(
    "func downloadModel(statusUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws {",
    "// MARK: - Get Instance",
)

require(
    "downloadBase: base" in download_block,
    "Whisper model download no longer targets the stable Application Support base directory.",
)
require(
    "load: false" in download_block and "try await whisper.loadModels()" in download_block,
    "Whisper model download no longer loads the model eagerly after download, so specialization can slip back to first transcription.",
)
require(
    "if ([self.busyModelIDs containsObject:model.identifier]) return;" in SETTINGS_SOURCE and
    "Cancel — reset UI" not in SETTINGS_SOURCE,
    "Settings UI can again fake-cancel a model download without cancelling the underlying WhisperKit task.",
)

require(
    "downloadBase: base" in download_block and "WhisperKitBackend.whisperDownloadBase()" in SOURCE,
    "Whisper model download no longer uses the stable Application Support HuggingFace base.",
)

require(
    "private nonisolated static func directorySize(at url: URL) -> Int64" in SOURCE and
    "return WhisperKitBackend.directorySize(at: WhisperKitBackend.modelFolderURL(modelName: modelName))" in SOURCE,
    "Model size reporting no longer counts partially-downloaded model directories, so settings download progress can stay at 0 bytes.",
)

require(
    "let oldRoot = modelRoot(in: docsHub)" in SOURCE and
    "let newRoot = modelRoot(in: newHub)" in SOURCE and
    "if fm.fileExists(atPath: dst.path)" in SOURCE,
    "Whisper model migration is no longer per-model and could delete a stale Documents model when another model already exists in Application Support.",
)

helper_block = block_between(
    "private func ensureModelLoaded(_ wk: WhisperKit,",
    "// MARK: - Download",
)

require(
    "guard wk.modelState != .loaded else {" in helper_block,
    "WhisperKit backend is missing the loaded-state guard for cached model instances.",
)
require(
    "try await whisper.loadModels()" in helper_block,
    "WhisperKit backend does not load an existing but unloaded model instance before reuse.",
)

factory_block = block_between(
    "func getOrCreateWhisperKit(statusUpdate: @escaping @Sendable (String) -> Void = { _ in }) async throws -> WhisperKit {",
    "func prepareModel(",
)

require(
    "return try await ensureModelLoaded(existing, statusUpdate: statusUpdate)" in factory_block,
    "WhisperKit backend still returns cached instances without ensuring the models are actually loaded.",
)
require(
    "load: false" in factory_block and "try await whisper.loadModels()" in factory_block,
    "WhisperKit backend no longer performs explicit model loading for on-disk models.",
)
