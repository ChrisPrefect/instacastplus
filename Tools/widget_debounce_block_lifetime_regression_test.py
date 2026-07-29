#!/usr/bin/env python3
"""Pin self-referential Widget export blocks to post-invocation release."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "WidgetDataExporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.index(signature, search_start)
        brace = SOURCE.index("{", start)
        semicolon = SOURCE.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


for signature in (
    "- (void)_scheduleDebouncedNowPlayingExport",
    "- (void)_scheduleControlActionNowPlayingExport",
):
    method = body(signature)
    if "__block dispatch_block_t exportBlock = nil;" not in method:
        continue
    cleanup = re.search(
        r"dispatch_async\(dispatch_get_main_queue\(\), \^\{\s*"
        r"exportBlock = nil;\s*"
        r"\}\);",
        method,
    )
    require(
        cleanup is not None
        and cleanup.start() < method.index("__strong typeof(weakSelf) strongSelf"),
        f"{signature} must always break Block-to-byref-to-Block ownership after the block "
        "returns, including early-return paths.",
    )

print("Widget debounce block lifetime regression checks passed")
