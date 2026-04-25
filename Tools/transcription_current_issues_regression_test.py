from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


queue_source = (ROOT / "Classes" / "TranscriptionQueue.swift").read_text()
backend_source = (ROOT / "Classes" / "WhisperKitBackend.swift").read_text()
controller_source = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()
downloads_controller_source = (ROOT / "Classes" / "DownloadsViewController.m").read_text()
cell_source = (ROOT / "Classes" / "DownloadsTableViewCell.m").read_text()


require(
    "Core ML konnte die Modellgewichte nicht in den Speicher einblenden." in backend_source
    and "Unable to mmap file" in backend_source,
    "Model-load mmap failures are still reported as a generic delete-and-redownload error.",
)

require(
    'message: "WhisperKit-Load beendet"' in backend_source
    and 'message: "Whisper-Modell geladen"' not in backend_source,
    "Diagnostics still duplicate the user-visible 'Modell geladen' log entry.",
)

require(
    "hasCheckpointFor:" in controller_source
    and "Unterbrochene Transkription wird fortgesetzt." in controller_source,
    "Queued rows with an existing checkpoint still show only 'Wartet auf Verarbeitung' after unlock/foreground.",
)

require(
    "UIButtonTypeInfoLight" in controller_source
    and "imageEdgeInsets = UIEdgeInsetsMake(8, 0, -8, 0)" in controller_source
    and "_showLogFromAccessoryButton:" in controller_source,
    "The transcription log info button is still the default accessory and cannot be nudged down.",
)

require(
    "cell.accessoryView = cell.playAccessoryButton" not in downloads_controller_source
    and "[cell.contentView addSubview:cell.playAccessoryButton]" in downloads_controller_source,
    "Downloads still install the download circle as a table accessory, which shifts rows and over-reserves right-side space.",
)

require(
    "cell.sizeLabel.numberOfLines = 2" in controller_source
    and "self.progressView.frame = CGRectMake(CGRectGetMinX(textLabelRect), 34, progressWidth, 10)" in cell_source,
    "Transcription rows do not keep status text full-width with elapsed time beside the progress bar.",
)
require(
    "((self.accessoryView != nil) ? 49 : 0)" in cell_source,
    "Elapsed seconds in transcription rows must keep a 5px gap from the info button.",
)
require(
    "GGUF-Modell konnte nicht geladen werden" not in (ROOT / "Classes" / "LocalGGUFModelRunner.swift").read_text()
    and "llama.cpp" not in (ROOT / "Classes" / "LocalGGUFModelRunner.swift").read_text().split("var errorDescription: String?")[1],
    "Local chapter-model errors still expose implementation details to users.",
)
