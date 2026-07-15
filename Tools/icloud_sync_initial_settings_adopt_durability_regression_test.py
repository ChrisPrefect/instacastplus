#!/usr/bin/env python3
"""Pins crash-safe replay of a parked initial Cloud AppSettings choice."""

from __future__ import annotations

from dataclasses import dataclass
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


@dataclass
class DurableState:
    parked_cloud_payload: str | None
    pending_local_intent: str | None
    applied_payload: str


def begin_adopt(state: DurableState) -> None:
    # A stale local upload is resolved first, but the already-fetched Cloud payload
    # remains a durable replay intent until applying and baselining has succeeded.
    state.pending_local_intent = None


def finish_adopt(state: DurableState) -> None:
    require(state.parked_cloud_payload is not None, "Parked payload vanished before replay")
    state.applied_payload = state.parked_cloud_payload
    state.parked_cloud_payload = None


state = DurableState("cloud-p2", "local-p1", "local-p1")
begin_adopt(state)
# Deterministic kill point: the process exits after stale-local cleanup but before apply.
reopened = DurableState(
    parked_cloud_payload=state.parked_cloud_payload,
    pending_local_intent=state.pending_local_intent,
    applied_payload=state.applied_payload,
)
require(reopened.parked_cloud_payload == "cloud-p2",
        "A kill before apply made the fetched Cloud payload unreplayable")
finish_adopt(reopened)
require(reopened == DurableState(None, None, "cloud-p2"),
        "Restart did not finish the exact parked Cloud choice")


body = method_body(REMOTE, "@objc func resolveInitialSettingsAdoptingCloud")
discard = body.find("discardPendingSingletonUploadIntent")
adopt = body.find("adoptSettingsPayload(payload)")
clear = body.find("setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)")
require(discard != -1 and "RecordPrefix.appSettings" in body[discard:adopt],
        "Initial Cloud adoption does not durably discard the superseded local AppSettings intent.")
require(adopt != -1 and clear > adopt,
        "The parked Cloud AppSettings payload is deleted before it has been applied and baselined.")
require("guard adoptSettingsPayload(payload)" in body
        or "if adoptSettingsPayload(payload)" in body,
        "Initial Cloud adoption clears its replay payload even when applying the payload fails.")

print("iCloud initial settings adoption durability regression checks passed")
