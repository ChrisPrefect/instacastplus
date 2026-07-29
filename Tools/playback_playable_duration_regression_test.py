#!/usr/bin/env python3
"""Pin playableDuration to a finite zero for an unloaded AVPlayerItem."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "PlaybackManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.index("- (NSTimeInterval) playableDuration")
brace = SOURCE.index("{", start)
depth = 0
for index in range(brace, len(SOURCE)):
    if SOURCE[index] == "{":
        depth += 1
    elif SOURCE[index] == "}":
        depth -= 1
        if depth == 0:
            method = SOURCE[brace + 1:index]
            break
else:
    raise AssertionError("Unterminated playableDuration method")

require(
    "NSValue*" in method
    and "loadedTimeRanges lastObject" in method
    and "if (!loadedTimeRangeValue)" in method
    and method.index("if (!loadedTimeRangeValue)") < method.index("CMTimeRangeValue"),
    "An AVPlayerItem may have no loaded time range; the getter must return zero before "
    "asking nil for a structure-valued CMTimeRange.",
)
require(
    "CMTIMERANGE_IS_VALID" in method
    and "CMTimeRangeGetEnd" in method
    and "CMTimeGetSeconds" in method
    and "isfinite" in method,
    "Invalid, indefinite, or non-finite AVFoundation times must not escape as NaN progress.",
)

print("Playback playable-duration regression checks passed")
