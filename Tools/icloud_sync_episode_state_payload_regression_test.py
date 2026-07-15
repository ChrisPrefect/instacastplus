#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker=None):
    # Brace-matching extraction: the old "cut at the next private member" heuristic broke
    # when the manager was split into files and member access became internal.
    require(signature in source, f"{signature} is missing.")
    start = source.find(signature)
    brace = source.find("{", start)
    require(brace != -1, f"{signature} has no body.")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


MANAGER = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])

# Episode states are materialized batch-wise: ONE fetch per send batch builds the payloads
# (the per-record fetch path was removed — it was the upload bottleneck and store-lock
# contention that froze the UI).
payload = method_body(MANAGER, "nonisolated static func episodeStatesByObjectHash")
require('NSPredicate(format: "objectHash IN %@"' in payload, "Episode payloads must be fetched with one batched IN query, not per record.")
for key in [
    '"objectHash": objectHash',
    '"played": episode.consumed',
    '"position": Int(episode.position)',
    '"starred": episode.starred',
]:
    require(key in payload, f"Episode state payload must keep {key}.")

for key in [
    '"guid"',
    '"feedURL"',
    '"duration"',
    '"deviceID"',
]:
    require(key not in payload, f"Episode state payload must not store bulky/unneeded key {key}.")

materialize = method_body(MANAGER, "nonisolated static func materializeRecordsForSyncEngineCallback")
require('payload["updatedAt"] = updatedAt' in materialize, "Batch materialization must stamp updatedAt from the local modified dates.")
require("episodeStatesByObjectHash(" in materialize, "Batch materialization must source episode payloads from the batched fetch.")
require("newBackgroundContext()" not in materialize, "Record materialization must not create a context per record.")

apply_remote = method_body(MANAGER, "func applyPendingEpisodeStateBatchInBackground")
for key in ["played", "position", "starred", "updatedAt"]:
    require(key in apply_remote, f"Remote episode apply must still use {key}.")
