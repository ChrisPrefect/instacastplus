#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker="\n    private"):
    require(signature in source, f"{signature} is missing.")
    return source.split(signature, 1)[1].split(next_marker, 1)[0]


MANAGER = read("Classes/ICiCloudSyncManager.swift")

payload = method_body(MANAGER, "private nonisolated static func episodeStatePayloadForSyncEngineCallback")
for key in [
    '"objectHash": objectHash',
    '"played": episode.consumed',
    '"position": Int(episode.position)',
    '"starred": episode.starred',
    '"updatedAt": updatedAt',
]:
    require(key in payload, f"Episode state payload must keep {key}.")

for key in [
    '"guid"',
    '"feedURL"',
    '"duration"',
    '"deviceID"',
]:
    require(key not in payload, f"Episode state payload must not store bulky/unneeded key {key}.")

apply_remote = method_body(MANAGER, "private func applyRemoteEpisodeState")
for key in ["played", "position", "starred", "updatedAt"]:
    require(key in apply_remote, f"Remote episode apply must still use {key}.")
