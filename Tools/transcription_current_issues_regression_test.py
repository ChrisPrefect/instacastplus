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
    "rightContentAccessoryView" in controller_source
    and "UIButtonTypeInfoLight" in controller_source
    and "imageEdgeInsets = UIEdgeInsetsMake(8, 0, -8, 0)" in controller_source
    and "cell.accessoryView = logButton" not in controller_source
    and "_showLogFromAccessoryButton:" in controller_source,
    "The transcription log info button is still the table accessory, so elapsed time cannot be centered under it.",
)

require(
    "cell.accessoryView = cell.playAccessoryButton" not in downloads_controller_source
    and "[cell.contentView addSubview:cell.playAccessoryButton]" in downloads_controller_source,
    "Downloads still install the download circle as a table accessory, which shifts rows and over-reserves right-side space.",
)

require(
    "cell.sizeLabel.numberOfLines = 2" in controller_source
    and "cell.sizeLabel.lineBreakMode = NSLineBreakByWordWrapping" in controller_source
    and "self.timeLabel.frame = CGRectMake(CGRectGetMaxX(bounds) - rightContentAccessoryWidth" in cell_source,
    "Transcription rows must use one wrapping status label and place elapsed time centered under the right-side info button.",
)
require(
    "_singleStatusTextWithHeadline" in controller_source
    and '"%@\\n%@"' not in controller_source,
    "Transcription rows still compose two separate status lines instead of one wrapping status message.",
)
require(
    "rightContentAccessoryWidth + 5" in cell_source,
    "Elapsed seconds in transcription rows must keep a 5px gap from the info button.",
)
require(
    "UIAlertController *alert = [UIAlertController alertControllerWithTitle:NSLocalizedString(@\"Job neu starten?\", nil)\n                                                                  message:nil" in controller_source,
    "Restart dialog still repeats the full failure text instead of only offering recovery actions.",
)
require(
    "GGUF-Modell konnte nicht geladen werden" not in (ROOT / "Classes" / "LocalGGUFModelRunner.swift").read_text()
    and "llama.cpp" not in (ROOT / "Classes" / "LocalGGUFModelRunner.swift").read_text().split("var errorDescription: String?")[1],
    "Local chapter-model errors still expose implementation details to users.",
)

require(
    "maxTranscriptionSliceDuration" in backend_source
    and "while sliceStart < totalDuration" in backend_source
    and "endTime: sliceEnd" in backend_source
    and "loadedDurationSeconds" in backend_source
    and "sliceEndSeconds" in backend_source,
    "WhisperKit still loads the whole remaining podcast into one audio buffer, which can crash long transcriptions at start.",
)

auto_download_block = queue_source.split("if autoDownloadEpisode(hash: candidate.episodeHash)", 1)[0].split("// Audio not available", 1)[1]
require(
    "startSpeechModelPreparationIfNeeded(episodeHash: candidate.episodeHash" in auto_download_block
    and "speechModelPreparationTask" in queue_source
    and "cancelSpeechModelPreparation" in queue_source,
    "The speech model is not prepared in parallel before an automatic episode download completes.",
)
