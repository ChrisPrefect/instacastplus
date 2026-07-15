#!/usr/bin/env python3
"""Pins the R3-align/R4-intent interleaving before list upload preparation."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


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


@dataclass(frozen=True)
class Intent:
    revision: str
    changed_at: float
    payload: str


def unsafe_stale_prepare(aligned: Intent, durable_current: Intent) -> Intent:
    """Models persistPendingSingletonUploadIntent replacing R4 with re-clocked stale R3."""
    return Intent(aligned.revision, durable_current.changed_at + 0.001, aligned.payload)


def safe_prepare(aligned: Intent, durable_current: Intent) -> Intent | None:
    if (aligned.revision, aligned.changed_at) != (
        durable_current.revision,
        durable_current.changed_at,
    ):
        return None
    return aligned


# drainLocalOutbox captured R3 and suspended while aligning its Core Data row. During
# that suspension, a new defaults/menu edit durably committed R4 and its full payload.
r3 = Intent("r3", 501.0, "payload-3")
r4 = Intent("r4", 502.0, "payload-4")
unsafe = unsafe_stale_prepare(r3, r4)
require(unsafe.revision == "r3" and unsafe.payload == "payload-3",
        "The fixture no longer reproduces stale R3 replacing R4")
require(safe_prepare(r3, r4) is None,
        "An exact post-suspension check did not reject stale R3")
require(r4 == Intent("r4", 502.0, "payload-4"),
        "Rejecting stale preparation must leave the durable R4 intent untouched")


drain = method_body(LOCAL, "func drainLocalOutbox")
alignment = drain.find("alignCommittedSubscriptionListSettingsOutboxEntry")
preparation = drain.find("prepareCommittedSubscriptionListSettingsOutboxEntryForUpload")
require(alignment != -1 and preparation > alignment,
        "The list outbox no longer aligns before upload preparation")
post_alignment = drain[alignment:preparation]

# MainActor cannot interleave again between the awaited align return and synchronous
# preparation. Re-read the durable intent there and require exact revision/date equality.
require(post_alignment.count("pendingSingletonUploadIntent(") >= 1,
        "The list drain does not re-read the current singleton intent after alignment suspended.")
require("revision" in post_alignment and ("modifiedAt" in post_alignment or "changedAt" in post_alignment),
        "The post-alignment intent check must compare the exact revision and timestamp.")

print("iCloud list prepare/intent race regression checks passed")
