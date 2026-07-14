#!/usr/bin/env python3
"""Pins downloaded-file size indexing off-main and outside sort/cell hot paths."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "MediaFilesViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


reload_content = body("- (void) _reloadContent")
require("QOS_CLASS_UTILITY" in reload_content and "attributesOfItemAtPath" in reload_content,
        "Downloaded-file sizes must be read on a utility queue, never during main-thread sorting.")
require("contentReloadGeneration" in reload_content and
        "generation != self.contentReloadGeneration" in reload_content,
        "A slower obsolete size scan must not replace a newer sort/cache snapshot.")

apply_content = body("- (void) _applyContentEpisodes:")
cell = body("cellForRowAtIndexPath:")
for name, method in (("content sorting", apply_content), ("visible cell rendering", cell)):
    require("numberOfDownloadedBytesForEpisode" not in method and
            "attributesOfItemAtPath" not in method and
            "downloadedBytesForEpisode" in method,
            f"{name} must use the one-pass byte-size snapshot without synchronous file I/O.")

print("Media-files size-sort performance regression checks passed")
