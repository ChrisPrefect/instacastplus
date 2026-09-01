#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
AUDIO_SESSION = (ROOT / "Classes" / "AudioSession.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def objc_method(signature: str) -> str:
    start = AUDIO_SESSION.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = AUDIO_SESSION.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")

    depth = 0
    for index in range(brace, len(AUDIO_SESSION)):
        if AUDIO_SESSION[index] == "{":
            depth += 1
        elif AUDIO_SESSION[index] == "}":
            depth -= 1
            if depth == 0:
                return AUDIO_SESSION[brace + 1:index]
    raise SystemExit(f"Unterminated method body: {signature}")


timer_value = objc_method("- (void) setTimerValue:(PlaybackStopTimeValue)timerValue")
timer_duration = objc_method("- (void)setTimerWithDuration:(NSTimeInterval)seconds")

for method, replay_call in (
    (timer_value, "self.timerValue = timerValue;"),
    (timer_duration, "[self setTimerWithDuration:seconds];"),
):
    require(
        "if (![NSThread isMainThread])" in method
        and "dispatch_async(dispatch_get_main_queue()" in method
        and replay_call in method,
        "Sleep-timer mutation must hop to the main thread before creating its NSTimer; "
        "otherwise asynchronous system callbacks attach it to a dormant currentRunLoop "
        "and playback continues after the displayed countdown reaches zero.",
    )
    require(
        method.index("if (![NSThread isMainThread])")
        < method.index("[self.playbackTimer invalidate]"),
        "The sleep timer must enter the main thread before touching its NSTimer.",
    )

require(
    "[[PlaybackManager playbackManager] pause];" in objc_method("- (void)stopPlaybackTimer:(NSTimer*)timer"),
    "An expired sleep timer must still pause playback.",
)
