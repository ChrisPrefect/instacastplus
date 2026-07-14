#!/usr/bin/env python3
"""Pins Watch manifest file normalization off MainActor and to affected entries."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "InstacastWatch" / "WatchManifestStore.swift").read_text()


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


normalizer = body("private nonisolated static func normalizeStoredLocalFileURLs")
require("Task.detached(priority: .utility)" in normalizer and
        normalizer.count("createDirectory") == 1 and
        "WatchStorageManager.shared" not in normalizer,
        "Manifest path resolution must stat files off-main and create/resolve the downloads directory only once per batch.")

load = body("private func performInitialLoad(")
require("await Self.normalizeStoredLocalFileURLs" in load,
        "The one full local-file repair pass belongs in asynchronous startup loading.")

apply_manifest = body("func applyManifest(")
require("await Self.normalizeStoredLocalFileURLs" in apply_manifest,
        "Manifest replacement must await off-main file normalization before durable ACK.")

upsert = body("func upsert(entries:")
require("let affectedHashes = await Task.detached(priority: .utility)" in upsert and
        "Set(entries.map(\\.episodeHash))" in upsert and
        "affectedHashes: affectedHashes" in upsert and
        "await Self.normalizeStoredLocalFileURLs" in upsert,
        "A one-entry upsert must normalize only that episode instead of all 4,500 stored files.")
require("manifestMutationGeneration" in apply_manifest and "manifestMutationGeneration" in upsert,
        "Actor reentrancy during detached normalization must not let an older manifest overwrite a newer revision.")

print("Watch manifest MainActor-I/O regression checks passed")
