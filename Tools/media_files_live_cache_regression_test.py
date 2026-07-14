#!/usr/bin/env python3
"""Pins the downloaded-files screen to live cache membership changes."""

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


view_did_load = body("- (void)viewDidLoad")
require('addTaskObserver:self forKeyPath:@"cachedEpisodes"' in view_did_load and
        "_reloadContent" in view_did_load and "reloadData" in view_did_load,
        "Downloaded Files must update while visible after download completion, deletion, or asynchronous auto-clear.")
require("viewIfLoaded.window" in view_did_load,
        "Off-screen cache changes must not trigger expensive table reconstruction.")

dealloc = body("- (void) dealloc")
require('removeTaskObserver:self forKeyPath:@"cachedEpisodes"' in dealloc,
        "The live cache observer must be removed with the screen lifecycle.")

print("Media-files live-cache regression checks passed")
