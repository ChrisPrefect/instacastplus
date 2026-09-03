from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


player_info = (ROOT / "Classes" / "PlayerInfoViewController_v5.m").read_text()
playback_manager = (ROOT / "Classes" / "PlaybackManager.m").read_text()
playback_controls = (ROOT / "Classes" / "PlaybackControlsViewController.m").read_text()

chapter_selection = player_info.split("- (void) tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath", 1)[1]
chapter_selection = chapter_selection.split("else if ([self _hasBookmarks]", 1)[0]
play_block = playback_manager.split("- (void) play", 1)[1].split("- (void) pause", 1)[0]

require(
    "pman.currentChapter = indexPath.row;" in chapter_selection
    and "[self _updateVisibleCells];" in chapter_selection,
    "Chapter taps must mark the requested chapter immediately before AVPlayer catches up.",
)
require(
    "NSArray* playbackChapters = pman.chapters;" in chapter_selection
    and "[pman seekToChapter:playbackChapter];" in chapter_selection,
    "Loaded chapter taps must preserve chapter intent by using seekToChapter:, not only a raw time seek.",
)
require(
    "[[AudioSession sharedAudioSession] playEpisode:episodeToPlay queueUpCurrent:NO "
    "at:MAX(0.0, chapter.timecode) autostart:YES preservingPlaybackSource:YES];" in chapter_selection,
    "When the app was reopened and the player is not loaded, tapping a chapter must start that episode at the chapter time.",
)
require(
    "self.seekingPosition = MIN(MAX(time / duration, 0), 1);" in playback_manager
    and "self.seekingPositionChangeDate = [NSDate date];" in playback_manager.split("- (void) seekToTime:(NSTimeInterval)time tolerance:(BOOL)tolerance", 1)[1].split("- (void) seekToChapter:", 1)[0],
    "seekToTime:tolerance: must expose the target position immediately so UI progress does not show the old chapter.",
)
seek_to_time_block = playback_manager.split("- (void) seekToTime:(NSTimeInterval)time tolerance:(BOOL)tolerance", 1)[1].split("- (void) seekToChapter:", 1)[0]
require(
    '[self willChangeValueForKey:@"time"];' in seek_to_time_block
    and '[self didChangeValueForKey:@"time"];' in seek_to_time_block,
    "seekToTime:tolerance: must notify time observers immediately so the seek bar redraws to the target chapter.",
)
require(
    "self.timeSlider.value = pman.position;" in playback_controls,
    "The player seek bar must use PlaybackManager.position so transient seek targets update the highlighted chapter segment.",
)
require(
    "BOOL hasRecentSeek" in play_block
    and "if (!hasRecentSeek && [USER_DEFAULTS boolForKey:PlayerReplayAfterPause]" in play_block
    and "self.lastPauseDate = nil;" in play_block,
    "Playback after an explicit chapter seek must not apply replay-after-pause from the sleep timer.",
)
require(
    "if (hasRecentSeek && self.duration > 0) {" in play_block
    and "resumeTime = self.seekingPosition * self.duration;" in play_block,
    "If playback reopens the local cached file after an explicit seek, it must reopen at the seek target, not the stale AVPlayer time.",
)
