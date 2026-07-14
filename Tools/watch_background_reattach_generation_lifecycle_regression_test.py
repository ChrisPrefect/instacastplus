#!/usr/bin/env python3
"""Pins latest-generation ownership for Watch background reattachment.

The background URLSession lifecycle completion may be one of several callers waiting
for task reconciliation.  If another caller supersedes its ``getAllTasks`` snapshot,
the stale callback must not invoke that completion: doing so releases the watchOS
background task while the newest reconciliation is still running.  Reattach requests
must share one active generation, and a superseded utility resolver must observe
cancellation instead of scanning the whole manifest unnecessarily.
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


def function_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


require(
    "pendingReattachCompletions" in SOURCE
    and "reattachInProgress" in SOURCE
    and "reattachResolutionTask" in SOURCE,
    "Overlapping foreground/background callers need shared completion ownership and one "
    "cancelable active resolver.",
)

request = function_body("private func reattachDownloadTasks(")
require(
    "pendingReattachCompletions.append(completion)" in request
    and "guard !reattachInProgress else" in request
    and "reattachResolutionTask?.cancel()" in request,
    "A newer reattach request must join the active generation and cancel obsolete resolution "
    "work instead of launching an unbounded overlapping scan.",
)

snapshot = function_body("private func handleReattachTasksSnapshot(")
stale_branch = snapshot.split("guard generation == reattachGeneration else", 1)
require(len(stale_branch) == 2, "The task snapshot must be generation-gated.")
stale_branch = stale_branch[1].split("}", 1)[0]
require(
    "completion()" not in stale_branch
    and "restartLatestReattach()" in stale_branch,
    "A superseded getAllTasks callback must transfer ownership to the newest generation; it may "
    "never release the background lifecycle completion itself.",
)
require(
    "let completions = pendingReattachCompletions" in snapshot
    and "pendingReattachCompletions.removeAll()" in snapshot
    and "completions.forEach" in snapshot,
    "All waiting foreground/background completions may run only after the latest reconciliation "
    "finishes.",
)

resolver = function_body("private nonisolated static func resolveReconcileLocalFiles(")
require(
    "Task.isCancelled" in resolver,
    "A canceled superseded resolver must check cancellation within its bounded file batches.",
)


print("Watch background reattach-generation lifecycle regression checks passed")
