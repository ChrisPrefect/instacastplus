#!/usr/bin/env python3
"""Pins retry ownership for failed Watch audio-file removals.

A failed physical audio deletion must remain queued without being acknowledged.
The current cleanup run may retry it once, but a permanent filesystem failure must
not create a tight loop. A durable error then blocks automatic restart retries until
an explicit user retry clears it and grants a fresh retry budget.
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


enqueue = function_body("private func enqueuePendingRemovalHashes(")
prepare = function_body("private func preparePendingRemovalCleanup() async")
process = function_body("private func processPendingRemovalBatch()")

require(
    "removalFailureCountByHash" in SOURCE,
    "Failed physical removals need durable in-process retry ownership instead of being lost "
    "after activeRemovalHashes removes the hash.",
)
require(
    "requestedHashes" in enqueue
    and "removalFailureCountByHash[hash] = nil" in enqueue,
    "A later real removal request must reset the hash's retry budget; internal empty queue "
    "continuations must preserve it.",
)
require(
    "removalFailureCountByHash[$0, default: 0] < 2" in prepare,
    "A permanently failing audio deletion must exhaust its in-process retry budget.",
)
require(
    "hasPendingRemovalError" in prepare,
    "A durable removal error must remain stopped after restart until an explicit retry clears it.",
)
require(
    "attemptedHashes" in process
    and "failedHashes" in process
    and "attemptedHashes.subtracting(physicallyDeletedHashes)" in process
    and "pendingRemovalHashes.formUnion(failedHashes)" in process,
    "Every attempted hash that was not physically deleted must return to pending ownership.",
)
episode_guard = process.find("guard let episode = WatchManifestStore.shared.episode(hash: hash)")
physical_removal = process.find("let physicallyDeletedHashes")
require(
    episode_guard != -1
    and physical_removal != -1
    and "removalFailureCountByHash[hash] = nil" in process[episode_guard:physical_removal],
    "A hash that disappeared or is no longer pending removal must release its stale retry "
    "counter instead of growing in-memory state forever.",
)
require(
    "removalFailureCountByHash[hash, default: 0] += 1" in process
    and "removalFailureCountByHash[hash, default: 0] >= 2" in process
    and "persistPendingRemovalFailures" in process
    and "removalCleanupRequested = true" in process,
    "The first failure must request exactly one serialized retry; the second must persist a "
    "terminal pending-removal error instead of spinning.",
)
require(
    "physicallyRemovedHashes.formUnion(confirmedDeletedHashes)" in process
    and "identity.matches(currentEpisode)" in process
    and "currentEpisode.status == .removing" in process
    and "sendDeletionAcknowledgements(for: completedHashes)" in process,
    "Deletion acknowledgements must remain restricted to physically removed hashes whose same "
    "pending-removal generation is still authoritative after detached file I/O.",
)


print("Watch removal retry-ownership regression checks passed")
