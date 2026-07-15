#!/usr/bin/env python3
"""Pins exact revision/date coupling between EpisodeList outbox rows and singleton intents."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
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


# Deterministic model of the two formerly-stalling orders.
def aligned(outbox: tuple[str, float], intent: tuple[str, float]) -> tuple[tuple[str, float], tuple[str, float]]:
    if intent[1] > outbox[1]:
        outbox = intent
    elif outbox != intent:
        intent = outbox
    return outbox, intent


# A Core Data list edit R2 was committed, then a newer defaults edit captured singleton R3.
# R3 must replace the stale row, otherwise EngineRecords defers forever on revision mismatch.
row, intent = aligned(("r2", 500.0), ("r3", 501.0))
require(row == intent == ("r3", 501.0), "Newer singleton revision did not supersede stale row")

# The inverse order must replace the old intent with the already-safe exact outbox clock;
# inventing 502 here while the row stays 501 recreates the strict-equality deadlock.
row, intent = aligned(("r2", 502.0), ("r1", 501.0))
require(row == intent == ("r2", 502.0), "Newer outbox revision did not supersede stale intent")

drain = method_body(LOCAL, "func drainLocalOutbox")
require("alignCommittedSubscriptionListSettingsOutboxEntry" in drain,
        "The drain must reconcile a stale list row/intent pair before queueing it.")
aligner = method_body(LOCAL, "func alignCommittedSubscriptionListSettingsOutboxEntry")
for token in ["intent.revision", "intent.modifiedAt", "intent.payloadData", "entry.changedAt"]:
    require(token in aligner, f"List alignment is missing exact field: {token}")

persist = method_body(MANAGER, "func persistPendingSingletonUploadIntent")
existing_guard = persist[:persist.find("let effectiveModifiedAt")]
require("existing.modifiedAt == modifiedAt" in existing_guard,
        "A same-revision intent with a stale clock must not be returned unchanged.")

materialize = method_body(
    (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text(),
    "nonisolated static func materializeRecordsForSyncEngineCallback",
)
require("singletonIntent.revision == entry.revision" in materialize
        and "singletonIntent.modifiedAt == entry.changedAt" in materialize,
        "The materializer must retain the exact revision/date invariant.")

print("iCloud singleton/outbox alignment regression checks passed")
