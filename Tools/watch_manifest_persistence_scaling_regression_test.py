#!/usr/bin/env python3
"""Pins Watch manifest I/O off MainActor and one-write bulk mutations."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STORE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
DOWNLOADS = (ROOT / "InstacastWatch" / "WatchDownloadManager.swift").read_text()
EPISODE = (ROOT / "InstacastWatch" / "WatchEpisode.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
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


require("private actor WatchManifestPersistenceWriter" in STORE,
        "Manifest encoding and atomic writes need one serial non-MainActor owner.")
writer = body(STORE, "private actor WatchManifestPersistenceWriter")
require("JSONEncoder" in writer and "createDirectory" in writer and ".write(to:" in writer,
        "The serial writer must own encoding, directory creation and atomic file replacement.")

persist = body(STORE, "private func persistEpisodesNow")
require("async throws" in STORE[STORE.find("private func persistEpisodesNow"):STORE.find("private func persistEpisodesNow") + 220] and
        "await persistenceWriter" in persist and
        "encoder.encode" not in persist and
        "createDirectory" not in persist and
        ".write(to:" not in persist,
        "WatchManifestStore must suspend while its immutable snapshot writes off MainActor.")
require("struct WatchEpisode: Codable, Identifiable, Equatable, Sendable" in EPISODE and
        "struct WatchChapter: Codable, Identifiable, Equatable, Sendable" in EPISODE,
        "Snapshots crossing to the persistence actor must be genuinely Sendable value types.")

update_one = body(STORE, "func updateEpisode(hash:")
require("var updatedEpisode" in update_one and
        ("guard updatedEpisode != episodes[index]" in update_one or
         "guard updatedEpisode != previousEpisode" in update_one) and
        "mutate(&episodes[index])" not in update_one,
        "No-op progress/playback mutations must not rewrite the whole manifest.")

update_many = body(STORE, "func updateEpisodes(")
require("var nextEpisodes = episodes" in update_many and
        update_many.count("episodes = nextEpisodes") == 1 and
        "mutate(&episodes[index])" not in update_many,
        "A bulk update must mutate a local array and publish it once instead of k @Published changes.")

autofill = body(DOWNLOADS, "private func autoFillEvictedEpisodes()")
require("updateEpisode(hash:" not in autofill and
        "episode(hash:" not in autofill and
        "updateEpisodes(" in autofill,
        "Auto-fill must collect fitting hashes and issue one bulk manifest mutation.")

reconcile = body(DOWNLOADS, "private func reconcileManifestWithDownloadTasks(")
require("updateEpisode(hash:" not in reconcile and
        "updateEpisodes(" in reconcile,
        "Task reconciliation must commit all path/status repairs in one manifest mutation.")

finish_download = body(DOWNLOADS, "private func processFinishedDownload(")
durable_update = finish_download.find("try await WatchManifestStore.shared.updateEpisodeDurably")
success_event = finish_download.find("reportTerminalDownloadState")
require(durable_update != -1 and success_event != -1 and durable_update < success_event,
        "A terminal watch.downloaded event may be sent only after the downloaded state is durably written.")

print("Watch manifest persistence scaling regression checks passed")
