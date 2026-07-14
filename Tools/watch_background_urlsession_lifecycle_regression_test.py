#!/usr/bin/env python3
"""Pins the real-watch background URLSession completion contract.

Apple delivers background-session callbacks before
``urlSessionDidFinishEvents(forBackgroundURLSession:)``. Returning from the SwiftUI
background-task action lets watchOS suspend the app, so that action may finish only
after reattachment/readiness, the finish-events delegate callback, and every async
``didCompleteWithError`` finalization (validation plus durable manifest commit).

The finish-events callback can arrive before the async waiter is installed. It must
therefore be latched, not treated as a one-shot continuation callback.
"""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()


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


require(
    "private final class WatchBackgroundSessionLifecycle" in SOURCE
    and "reattachFinished" in SOURCE
    and "delegateEventsFinished" in SOURCE
    and "pendingFinalizations" in SOURCE,
    "Background completion needs one race-safe lifecycle gate for readiness, the URLSession "
    "finish-events callback, and async delegate finalizations.",
)

completion_gate = method_body("private func takeContinuationsIfReady(")
require(
    "reattachFinished" in completion_gate
    and "delegateEventsFinished" in completion_gate
    and "pendingFinalizations == 0" in completion_gate,
    "The background task may complete only after reattach, URLSession finish-events, and every "
    "async didComplete finalization.",
)

waiter = method_body("func waitUntilFinished() async")
require(
    "completed" in waiter and "continuation.resume()" in waiter,
    "Finish-events can precede waiter installation, so a completed lifecycle must resume a late "
    "waiter immediately.",
)

background = method_body("func handleBackgroundEvents() async")
begin = background.find("backgroundSessionLifecycle.begin()")
load = background.find("await WatchManifestStore.shared.load()")
reattach = background.find("reattachDownloadTasks")
mark_reattach = background.find("markReattachFinished()")
wait = background.find("await lifecycle.waitUntilFinished()")
require(
    -1 not in (begin, load, reattach, mark_reattach, wait)
    and begin < load < reattach < mark_reattach < wait,
    "The lifecycle must be installed before URLSession is touched, and reattach may only mark "
    "readiness—not complete the background task before delegate callbacks finish.",
)
require(
    "withCheckedContinuation" not in background and "continuation.resume()" not in background,
    "The getAllTasks/reattach callback must not directly finish the watchOS background task.",
)

did_complete = method_body("didCompleteWithError error: Error?")
register = did_complete.find("beginFinalization()")
main_actor_task = did_complete.find("Task { @MainActor")
finish = did_complete.find("finishFinalization()")
require(
    -1 not in (register, main_actor_task, finish)
    and register < main_actor_task < finish,
    "didComplete must synchronously register its async processing before returning to URLSession, "
    "then release the lifecycle only after validation and the durable manifest commit finish.",
)
require(
    "defer" in did_complete[main_actor_task:finish],
    "Every early-return path in async didComplete processing must release its finalization token.",
)

did_finish = method_body("didFinishDownloadingTo location: URL")
require(
    "stagingFailureDescriptionsByTaskIdentifier" in SOURCE
    and "downloadTask.taskIdentifier" in did_finish
    and "stagingFailureDescriptionsByTaskIdentifier" in did_finish
    and "Task { @MainActor" not in did_finish,
    "A synchronous staging failure must be handed to didComplete by task identity, not launched "
    "as an untracked async persistence task before the background lifecycle token exists.",
)
staging_failure_read = did_complete.find("stagingFailureDescriptionsByTaskIdentifier.removeValue")
staging_failure_commit = did_complete.find("await markDownloadFailed")
require(
    -1 not in (staging_failure_read, staging_failure_commit)
    and staging_failure_read < main_actor_task < finish < staging_failure_commit,
    "didComplete must consume the staging failure synchronously, then persist it inside the same "
    "registered finalization whose deferred completion gates watchOS suspension.",
)

finish_events = method_body("urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession)")
require(
    "markDelegateEventsFinished()" in finish_events,
    "URLSession's finish-events delegate callback—not getAllTasks—must release the system "
    "background-event side of the lifecycle gate.",
)


print("Watch background URLSession lifecycle regression checks passed")
