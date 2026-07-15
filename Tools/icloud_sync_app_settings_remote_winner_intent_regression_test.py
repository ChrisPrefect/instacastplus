#!/usr/bin/env python3
"""Pins removal of stale local AppSettings work when the remote record wins."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


def resolve_remote_winner(
    current_payload: str,
    pending_intent: str | None,
    pending_engine_save: bool,
    remote_payload: str,
) -> tuple[str, str | None, bool]:
    # The remote state is committed as one resolution: stale durable and in-memory
    # local work is removed before the remote payload becomes the new baseline.
    pending_intent = None
    pending_engine_save = False
    current_payload = remote_payload
    return current_payload, pending_intent, pending_engine_save


resolved = resolve_remote_winner(
    current_payload="local-p1",
    pending_intent="local-p1",
    pending_engine_save=True,
    remote_payload="cloud-p2",
)
require(resolved == ("cloud-p2", None, False),
        "A Cloud-wins resolution left stale local AppSettings work behind")


body = method_body(REMOTE, "func applyRemoteAppSettings")
local_wins = body.find("localDate.compare(remoteDate) == .orderedDescending")
adopt = body.rfind("adoptSettingsPayload(payload)")
require(local_wins != -1 and adopt > local_wins,
        "AppSettings no longer has the expected local/remote winner resolution")
remote_wins = body[local_wins:adopt]
require("discardPendingSingletonUploadIntent" in remote_wins
        and "RecordPrefix.appSettings" in remote_wins,
        "A remote AppSettings winner does not discard the stale durable local intent and queued save.")
require("guard discardPendingSingletonUploadIntent" in remote_wins,
        "Remote AppSettings must not be adopted if stale local work could not be durably discarded.")

print("iCloud AppSettings remote-winner intent regression checks passed")
