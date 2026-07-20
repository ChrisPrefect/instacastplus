from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "TranscriptionQueueViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


selection = SOURCE.split(
    "- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath",
    1,
)[1].split("- (void)_rebuildEpisodeCacheForCurrentItems", 1)[0]

require(
    "UILongPressGestureRecognizer" not in SOURCE
    and "_handleQueueLongPress" not in SOURCE,
    "Restart actions still require the newly added long press instead of the established row tap.",
)
require(
    "item.status == ICTranscriptionStatusQueued || item.status == ICTranscriptionStatusFailed" in selection
    and "[self _presentRecoveryActionsForItem:item];" in selection,
    "Tapping a queued or failed transcription row does not open its restart/delete actions.",
)
require(
    selection.find("[self _presentRecoveryActionsForItem:item];")
    < selection.find("PlaybackViewController* playbackController"),
    "The tap handler opens playback before offering recovery for queued or failed jobs.",
)

print("transcription queue tap restart regression checks passed")
