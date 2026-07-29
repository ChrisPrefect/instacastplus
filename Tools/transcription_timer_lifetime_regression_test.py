#!/usr/bin/env python3
"""Pin repeating transcription UI timers to weak controller captures."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.index(signature)
    brace = source.index("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


checks = (
    (
        "Classes/TranscriptionQueueViewController.m",
        "- (void)_restartElapsedTimerIfNeeded",
        "self.elapsedTimer = [NSTimer scheduledTimerWithTimeInterval:",
    ),
    (
        "Classes/TranscriptionSettingsViewController.m",
        "- (void)_startRefreshTimerIfNeeded",
        "self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:",
    ),
)

for relative_path, signature, timer_start in checks:
    source = (ROOT / relative_path).read_text()
    method = body(source, signature)
    require(
        "WEAK_SELF" in method
        and method.index("WEAK_SELF") < method.index(timer_start),
        f"{relative_path} must establish a weak controller capture before its repeating timer.",
    )
    timer_offset = method.index(timer_start)
    block_offset = method.index("block:^", timer_offset)
    timer_block = method[block_offset:method.index("}];", block_offset) + 3]
    require(
        "[self " not in timer_block and "self." not in timer_block,
        f"{relative_path} repeating timer still strongly captures its controller, so the "
        "dealloc invalidation can never break the RunLoop-to-timer-to-block cycle.",
    )

print("Transcription timer lifetime regression checks passed")
