#!/usr/bin/env python3
"""Pins immutable URLSession-task ownership for staged Watch downloads.

An old task and its replacement can share one episode hash. URLSession still owes
both tasks their own didFinish/didComplete callback pair, so a hash-keyed staging
map lets either task overwrite or consume the other's temporary file.
"""

from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "InstacastWatch"
    / "WatchDownloadManager.swift"
).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


did_finish = method_body("didFinishDownloadingTo location: URL")
did_complete = method_body("didCompleteWithError error: Error?")

require(
    "stagedLocationsByTaskIdentifier: [Int: URL]" in SOURCE
    and "stagedLocationsByHash" not in SOURCE,
    "Staged download files must be owned by immutable URLSession task identifiers, not by "
    "a reusable episode hash.",
)
require(
    "stagedLocationsByTaskIdentifier[downloadTask.taskIdentifier] = stagedLocation" in did_finish,
    "didFinishDownloadingTo must stage the file under the exact task that produced it.",
)
require(
    "stagedLocationsByTaskIdentifier.removeValue(" in did_complete
    and "forKey: task.taskIdentifier" in did_complete,
    "didCompleteWithError must consume only the staged file belonging to that same task.",
)


print("Watch download staging task-identity regression checks passed")
