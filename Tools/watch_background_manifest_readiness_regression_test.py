#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
DOWNLOADS = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


load = method_body(STORE, "func load() async")
require(
    "manifestLoaded" in STORE
    and "manifestLoadInProgress" in STORE
    and "manifestLoadContinuations" in STORE,
    "Concurrent foreground/background manifest loads need one shared readiness gate.",
)
require(
    "guard !manifestLoaded" in load
    and "manifestLoadInProgress" in load
    and "withCheckedContinuation" in load
    and "performInitialLoad" in load,
    "Manifest load must be idempotent and coalesce callers instead of resetting live state twice.",
)

background = method_body(DOWNLOADS, "func handleBackgroundEvents() async")
require(
    "await WatchManifestStore.shared.load()" in background
    and background.find("await WatchManifestStore.shared.load()")
    < background.find("reattachDownloadTasks"),
    "Background URLSession tasks must not be reconciled against an unloaded empty manifest.",
)
require(
    "markReattachFinished()" in background
    and "await lifecycle.waitUntilFinished()" in background
    and background.find("markReattachFinished()")
    < background.find("await lifecycle.waitUntilFinished()"),
    "The watchOS background task must remain alive after URLSession task reattachment until "
    "the complete background-session lifecycle gate opens.",
)


print("Watch background manifest-readiness regression checks passed")
