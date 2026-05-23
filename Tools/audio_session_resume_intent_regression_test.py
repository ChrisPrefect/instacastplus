#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "AudioSession.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")

    depth = 0
    for index in range(brace, len(SOURCE)):
        char = SOURCE[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]

    raise SystemExit(f"Unterminated method body: {signature}")


resume_body = method_body("-(void)resumePlayback")
interruption_body = method_body("- (void) audioSessionInterruptionNotification:(NSNotification*)notification")

resume_snapshot_index = resume_body.find("BOOL shouldResumePlayback = self.playerWasPlayingBeforeWentToBackground;")
resume_clear_index = resume_body.find("self.playerWasPlayingBeforeWentToBackground = NO;")
resume_play_index = resume_body.find("[pman play];")

require(
    resume_snapshot_index != -1,
    "Background resume must snapshot playerWasPlayingBeforeWentToBackground before clearing it.",
)
require(
    resume_clear_index != -1 and resume_play_index != -1 and resume_clear_index < resume_play_index,
    "Background resume intent must be consumed before calling play so stale pause state cannot auto-start later.",
)
require(
    "if (shouldResumePlayback && pman.movingVideo && pman.paused)" in resume_body,
    "Background resume must use the consumed snapshot, not the stale property, when deciding to play.",
)
require(
    "self.playerWasPlayingBeforeWentToBackground = (pman.movingVideo && !pman.paused);" in method_body("- (void)applicationWillResignActiveNotification:(UIApplication *)application"),
    "Background auto-resume intent must only be captured for moving video; audio should continue naturally and must not be restarted after a user pause.",
)

interruption_snapshot_index = interruption_body.find("BOOL shouldResumeAfterInterruption = pman.hasBeenPlayingWhenInterrupted;")
interruption_clear_index = interruption_body.find("pman.hasBeenPlayingWhenInterrupted = NO;")
interruption_play_index = interruption_body.find("[pman play];")

require(
    interruption_snapshot_index != -1,
    "Interruption end handling must snapshot hasBeenPlayingWhenInterrupted before clearing it.",
)
require(
    interruption_clear_index != -1
    and interruption_play_index != -1
    and interruption_clear_index < interruption_play_index,
    "Interruption resume intent must be consumed before calling play so later interruption-ended events cannot restart a paused player.",
)
require(
    "shouldResumeAfterInterruption && option == AVAudioSessionInterruptionOptionShouldResume" in interruption_body,
    "Interruption end handling must resume only from the consumed interruption snapshot and the system ShouldResume option.",
)
