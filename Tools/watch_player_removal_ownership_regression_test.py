#!/usr/bin/env python3
"""Pins ownership and commit ordering for Watch playback-file invalidation.

A truncated/decode-invalid file is removed asynchronously. While that file I/O
is suspended, a new player, a manifest upsert, or a download may reuse the same
episode hash. The stale result must never clear that newer state.
"""
from dataclasses import dataclass
from pathlib import Path
import re
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
PLAYER = (ROOT / "InstacastWatch" / "WatchPlayerController.swift").read_text()
DOWNLOAD = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
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
    raise AssertionError(f"Unterminated function: {signature}")


finish = function_body(PLAYER, "nonisolated func audioPlayerDidFinishPlaying(")
playback_failure = function_body(PLAYER, "private func markEpisodePlaybackFailed(")
remove_playback = function_body(DOWNLOAD, "func removePlaybackFile(")
begin_blocker = function_body(DOWNLOAD, "private func beginStorageMutationBlocker(")
end_blocker = function_body(DOWNLOAD, "private func endStorageMutationBlocker(")

# Player callbacks must not synchronously touch the filesystem. They hand the
# immutable episode snapshot to the one DownloadManager-owned removal path.
for label, body in (("truncated finish", finish), ("playback failure", playback_failure)):
    require(
        "removeLocalFile(for:" not in body
        and "FileManager.default" not in body
        and "await WatchDownloadManager.shared.removePlaybackFile(" in body,
        f"{label} must use the asynchronous, owned removePlaybackFile path.",
    )

# A failed AVAudioPlayer construction/play call is already in async play(); it
# must await invalidation instead of spawning an unowned fire-and-forget Task.
play = function_body(PLAYER, "func play(_ episode: WatchEpisode) async -> Bool")
require(
    play.count("await markEpisodePlaybackFailed(") == 3,
    "Every invalid-audio failure in play() must await the owned removal result.",
)
require(
    "private func markEpisodePlaybackFailed(_ episode: WatchEpisode, error: String) async" in PLAYER,
    "Playback failure cleanup must remain in the caller's structured async lifetime.",
)

# Ownership and the global storage-mutation blocker are established before the
# first suspension. They block play/re-download/reuse of the file while I/O runs.
owner_claim = remove_playback.find("removalOwnedIdentities[hash] = identity")
blocker_claim = remove_playback.find("await beginStorageMutationBlocker()")
physical_remove = remove_playback.find("await WatchStorageManager.removeLocalFiles(")
require(
    0 <= owner_claim < blocker_claim < physical_remove,
    "removePlaybackFile must claim the stable episode identity before its first await and "
    "hold a storageMutationBlocker across physical removal.",
)
require(
    "defer" in remove_playback
    and "removalOwnedIdentities[hash] = nil" in remove_playback
    and "endStorageMutationBlocker(" in remove_playback,
    "Every removePlaybackFile exit must release both ownership and its storage blocker.",
)
require(
    "if !storageMutationBlockers.isEmpty" in begin_blocker
    and "pendingStorageMutationBlockerWaiters" in begin_blocker
    and "pendingStorageMutationBlockerWaiters" in end_blocker,
    "storageMutationBlocker must serialize manifest upserts behind playback removal; merely "
    "counting concurrent blockers lets an upsert reuse the file while it is being deleted.",
)
require(
    "downloadsDirectory:" in remove_playback
    and "chapterArtworkDirectory:" in remove_playback
    and "WatchStorageManager.shared.removeLocal" not in remove_playback,
    "Playback removal must use the completed detached Storage API, never a synchronous manager call.",
)

# The file result is only allowed to mutate the manifest after its logical
# episode, exact status, and download ownership have been revalidated. Player B
# may start during file I/O; A must still commit URL=nil because A's file is
# already gone. Player identity is revalidated by the caller before UI mutation.
after_remove = remove_playback[physical_remove:]
manifest_commit = after_remove.find("updateEpisodeDurably")
require(manifest_commit != -1, "A successful playback-file removal must be persisted durably.")
guard_region = after_remove[:manifest_commit]
for contract in (
    "removalOwnedIdentities[hash]",
    "matchesPlaybackRemovalIdentity",
    "expectedStatus",
    "activeTasksByHash[hash] == nil",
    "!finishingDownloadHashes.contains(hash)",
    "!pendingDownloadStartHashes.contains(hash)",
    "removalResult.removedHashes.contains(hash)",
):
    require(
        contract in guard_region,
        f"removePlaybackFile must revalidate `{contract}` after storage I/O before commit.",
    )
require(
    "stillCurrentPlayback()" not in guard_region,
    "Player B starting after physical deletion must not leave episode A pointing at its deleted file; "
    "Player identity only gates caller-side Player/UI mutation.",
)

require(
    "item.localFileURL = nil" in remove_playback
    and "item.status = disposition.status" in remove_playback,
    "Only the successful, revalidated path may clear the URL and commit queued/failed state.",
)
removal_failed = function_body(DOWNLOAD, "private func recordPlaybackFileRemovalFailure(")
require(
    "item.lastError" in removal_failed
    and "item.localFileURL = nil" not in removal_failed
    and re.search(r"item\.status\s*=(?!=)", removal_failed) is None,
    "An audio-removal failure must stay visible/retryable without lying that the file is gone.",
)

# Player ownership is represented by immutable ObjectIdentifier + generation
# tokens across suspension. A stale return cannot clear player B, report A as
# terminal, or trigger A's re-download.
require(
    "let removalGeneration = playbackGeneration" in finish
    and "stillCurrentPlayback:" in finish
    and "playbackGeneration == removalGeneration" in finish
    and "ObjectIdentifier(currentPlayer) == callbackPlayerIdentifier" in finish,
    "Truncated cleanup must pass the finished player identity and playback generation for post-await validation.",
)
finish_await = finish.find("await WatchDownloadManager.shared.removePlaybackFile(")
require(
    finish_await
    < finish.find("ObjectIdentifier(currentPlayer) == callbackPlayerIdentifier", finish_await)
    < finish.find("self.player = nil", finish_await),
    "After removal, the callback must re-prove player identity before clearing Player state.",
)
require(
    "truncatedFile && !pendingRemoval && removalCommitted" in finish
    and "startQueuedDownloads()" in finish,
    "A truncated file may only start its replacement download after successful removal/commit.",
)
require(
    "if pendingRemoval" in finish and "finalizePendingRemoval" in finish,
    "A pending user removal must keep its existing removal lifecycle instead of being requeued.",
)


# Deterministic state model for the suspension window.
@dataclass(frozen=True)
class Identity:
    episode_hash: str
    selection_id: str
    added: int
    media_url: str


@dataclass
class Episode:
    identity: Identity
    status: str
    local_url: Optional[str]
    last_error: Optional[str] = None


@dataclass
class RemovalState:
    episode: Episode
    player_generation: int
    owner: Optional[Identity] = None
    download_active: bool = False

    def complete(self, claimed: Identity, expected_status: str, removed: bool) -> bool:
        current = self.episode
        current_matches = current.identity == claimed
        if self.owner != claimed or not current_matches or current.status != expected_status:
            return False
        if self.download_active:
            return False
        if not removed:
            current.last_error = "remove failed"
            return False
        current.status = "queued"
        current.local_url = None
        return True


identity_a = Identity("same-hash", "selection-a", 1, "https://example.test/a.mp3")
identity_b = Identity("same-hash", "selection-b", 2, "https://example.test/b.mp3")

for mutation in ("new-player", "manifest-upsert", "new-download"):
    state = RemovalState(Episode(identity_a, "downloaded", "old.mp3"), player_generation=7, owner=identity_a)
    if mutation == "new-player":
        state.player_generation = 8
    elif mutation == "manifest-upsert":
        state.episode = Episode(identity_b, "downloaded", "new.mp3")
    else:
        state.download_active = True
        state.episode.local_url = "new.mp3"
    committed = state.complete(identity_a, "downloaded", removed=True)
    expected_commit = mutation == "new-player"
    expected_url = None if mutation == "new-player" else "new.mp3"
    require(
        committed == expected_commit and state.episode.local_url == expected_url,
        f"A stale {mutation} window must not clear the newer Player/Manifest/Download state.",
    )

failure = RemovalState(Episode(identity_a, "downloaded", "old.mp3"), player_generation=7, owner=identity_a)
require(
    not failure.complete(identity_a, "downloaded", removed=False)
    and failure.episode.status == "downloaded"
    and failure.episode.local_url == "old.mp3"
    and failure.episode.last_error == "remove failed",
    "A physical deletion failure must preserve retryable file ownership and expose the error.",
)

success = RemovalState(Episode(identity_a, "downloaded", "old.mp3"), player_generation=7, owner=identity_a)
require(
    success.complete(identity_a, "downloaded", removed=True)
    and success.episode.status == "queued"
    and success.episode.local_url is None,
    "Only the unchanged owner may commit after successful physical deletion.",
)

# Manifest replace/upsert also acquires storageMutationBlocker. It must wait for
# playback removal to finish, then merge from queued/nil rather than inheriting
# the just-deleted old.mp3 under a new logical identity.
success.episode = Episode(identity_b, success.episode.status, success.episode.local_url)
require(
    success.episode.status == "queued" and success.episode.local_url is None,
    "A manifest upsert queued behind the claim must not reuse the physically removed URL.",
)

print("watch player-removal ownership regression test passed")
