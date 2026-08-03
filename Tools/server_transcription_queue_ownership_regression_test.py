#!/usr/bin/env python3
"""Pin server-transcription task ownership and terminal queue cleanup."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ServerTranscriptionManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.index(signature)
    brace = SOURCE.index("{", start)
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated declaration: {signature}")


require(
    "private var currentItem: ICTranscriptionQueueItem?" in SOURCE,
    "The single server task must record which queue item it owns.",
)

dequeue = body("@objc func dequeueEpisodeHash")
require(
    re.search(
        r"if currentItem === item\s*\{\s*currentTask\?\.cancel\(\)\s*\}",
        dequeue,
    )
    is not None,
    "Removing a queued item must not cancel the unrelated item currently using the one task.",
)

process = body("private func processNext()")
require(
    "currentItem = item" in process
    and process.index("currentItem = item") < process.index("currentTask = Task"),
    "Task ownership must be installed before the asynchronous server operation starts.",
)
cleanup_match = re.search(
    r"defer\s*\{\s*"
    r"self\.currentItem = nil\s*"
    r"self\.currentTask = nil\s*"
    r"self\.persistQueue\(\)\s*"
    r"self\.processNext\(\)\s*"
    r"self\.postQueueChange\(\)\s*"
    r"\}",
    process,
)
require(
    cleanup_match is not None,
    "Every success, cancellation, removed-item, and error path must release the task gate "
    "and continue the durable queue through one common terminal cleanup.",
)

missing_endpoint = process[
    process.index("guard let episodeURL"):
    process.index("item.status = .transcribing")
]
require(
    "fail(item" in missing_endpoint
    and "persistQueue()" in missing_endpoint
    and "postQueueChange()" in missing_endpoint
    and "processNext()" in missing_endpoint,
    "The pre-task missing-URL failure must still persist, publish, and drain explicitly.",
)

for signature in (
    "private func apply(",
    "private func fail(",
    "private func handle(error:",
):
    helper = body(signature)
    require(
        "currentTask = nil" not in helper and "processNext()" not in helper,
        f"{signature} must not clear or restart queue ownership independently; doing so can "
        "erase a newer task started by another terminal helper.",
    )

print("Server transcription queue-ownership regression checks passed")
