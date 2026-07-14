#!/usr/bin/env python3
"""Pins off-main Watch removal I/O and MainActor commit revalidation.

The serialized removal owner may select and cancel episodes on MainActor, but the
bounded fileExists/removeItem loop must execute at utility priority.  Once that
work returns, only the same still-removing, non-playing episode generation may be
acknowledged as deleted.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
STORAGE = (ROOT / "InstacastWatch" / "WatchStorageManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


storage_removal = function_body(
    STORAGE,
    "nonisolated static func removeLocalFiles(",
)
process = function_body(
    DOWNLOAD,
    "private func processPendingRemovalBatch() async",
)

require(
    "Task.detached(priority: .utility)" in storage_removal
    and "removeLocalFilesOffMain" in storage_removal,
    "The 25-item fileExists/removeItem loop must run in detached utility work, not on "
    "WatchDownloadManager's MainActor.",
)
require(
    "await WatchStorageManager.removeLocalFiles(" in process
    and "WatchStorageManager.shared.removeLocalFiles(" not in process,
    "The serialized removal batch must await the off-main storage API instead of invoking the "
    "synchronous @MainActor storage method.",
)

playback_claim = function_body(
    DOWNLOAD,
    "func claimPlaybackBeforeStorageEviction(hash:",
)
require(
    "removalOwnedIdentities[hash] == nil" in playback_claim
    and "removalOwnedIdentities[hash] = identity" in process,
    "Once detached deletion owns an episode identity, a reentrant playback tap must not open the "
    "same file while it is being removed.",
)

identity_capture = process.find("batchIdentities[hash] = identity")
physical_removal = process.find("await WatchStorageManager.removeLocalFiles(")
identity_revalidation = process.find("identity.matches(currentEpisode)")
status_revalidation = process.find("currentEpisode.status == .removing")
playing_revalidation = process.find("playingEpisodeHash != hash")
acknowledgement = process.find("sendDeletionAcknowledgements(for: completedHashes)")
require(
    -1 not in (
        identity_capture,
        physical_removal,
        identity_revalidation,
        status_revalidation,
        playing_revalidation,
        acknowledgement,
    )
    and identity_capture < physical_removal
    and physical_removal < identity_revalidation < acknowledgement
    and physical_removal < status_revalidation < acknowledgement
    and physical_removal < playing_revalidation < acknowledgement,
    "A removal result may be acknowledged only after the immutable episode identity, pending "
    "status, and playback ownership are revalidated on MainActor.",
)
claim_release = process.find("removalOwnedIdentities[hash] = nil", physical_removal)
require(
    claim_release != -1
    and physical_removal < claim_release < identity_revalidation,
    "Physical-removal ownership must stay held across the await and be released on MainActor "
    "immediately before the returned identity/status result is committed.",
)
require(
    "pendingRemovalHashes.formUnion(deferredHashes)" in process
    and "failedHashes" in process
    and "removalFailureCountByHash[hash, default: 0] += 1" in process,
    "A stale/playing successful deletion must remain deferred without consuming the filesystem "
    "failure retry budget; real file failures keep the existing bounded retry contract.",
)
require(
    "await self.processPendingRemovalBatch()" in process
    and "await Task.yield()" in process,
    "Removal ownership must remain serialized while yielding between off-main batches; no second "
    "manifest or network mutation may overlap it.",
)


print("Watch storage-removal MainActor I/O regression checks passed")
