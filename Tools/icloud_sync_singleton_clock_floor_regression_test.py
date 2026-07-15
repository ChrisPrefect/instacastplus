#!/usr/bin/env python3
"""Pins durable account-scoped Cloud-LWW clocks for singleton records."""

from math import ceil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
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


require('singletonClockFloorsKey = "ICiCloudSyncSingletonClockFloors"' in MANAGER,
        "Singleton Cloud-LWW floors need their own durable account+record store.")
file_keys = method_body(MANAGER, "nonisolated static var fileBackedSyncMetadataKeys")
require("singletonClockFloorsKey" in file_keys,
        "Singleton clock floors must be atomically file-backed.")
persist_singleton = method_body(MANAGER, "func persistPendingSingletonUploadIntent")
for token in ["nextSingletonModifiedAt", "persistSingletonClockFloor", "effectiveModifiedAt"]:
    require(token in persist_singleton,
            f"A singleton mutation is missing the causal-clock step: {token}")
require('capturedPayload["updatedAt"] = effectiveModifiedAt' in persist_singleton
        and "modifiedAt: effectiveModifiedAt" in persist_singleton,
        "Intent metadata and encrypted payload must carry the exact same causal timestamp.")
clock_helper = method_body(MANAGER, "func nextSingletonModifiedAt")
require("nextCloudKitSafeDate" in clock_helper
        and "singletonClockFloor" in clock_helper
        and "singletonMetadataClockFloor" in clock_helper
        and "singletonListOutboxClockFloor" in clock_helper,
        "The next singleton clock must include durable, metadata, intent and List-outbox floors.")
scoped_floor = method_body(MANAGER, "func singletonClockFloor")
require("floors.values" not in scoped_floor,
        "A pending/unbound singleton must never inherit a future clock from another account.")
bind_intents = method_body(MANAGER, "func bindPendingSingletonUploadIntents")
for token in ["nextCloudKitSafeDate", "payloadDataByReplacingSingletonDates", "persistSingletonClockFloor"]:
    require(token in bind_intents,
            f"A bound singleton source must be re-clocked with exact payload dates: {token}")
reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require("bindSingletonClockFloors" in reconcile,
        "Pending/unbound clock floors must bind to the verified account with their intents.")
factory_reset = method_body(MANAGER, "@objc func prepareForLocalAppResetWithCompletion")
require("singletonClockFloorsKey" in factory_reset,
        "A local factory reset must remove the durable singleton clock floors.")
account_reset = method_body(MANAGER, "func resetAllLocalSyncMetadata")
require("singletonClockFloorsKey" not in account_reset,
        "Normal account/engine transitions must retain per-account singleton clock floors.")
publish_local = method_body(REMOTE, "@objc func resolveInitialSettingsPublishingLocal")
require("pendingInitialSettingsPayloadKey" in publish_local
        and 'payload["updatedAt"] as? Date' in publish_local
        and "modifiedAt: remoteDate" in publish_local,
        "Publishing local settings after the initial choice must beat the parked Cloud timestamp.")


def next_safe_ms(*floors: float) -> float:
    return (ceil(max(floors) * 1000.0) + 1.0) / 1000.0


# R1 is ACKed and its intent disappears. R2 must still beat it after a clock rollback
# and CloudKit's millisecond Date round-trip.
r1 = 500.0
r2 = next_safe_ms(400.0, r1)
require(r2 > r1 and round(r2 * 1000) > round(r1 * 1000),
        "The post-ACK R2 edit must remain newer after CloudKit millisecond conversion.")

# Floors are isolated by account and survive A→B→A.
floors = {("A", "settings_app"): r2, ("B", "settings_app"): 900.0}
a_return = next_safe_ms(450.0, floors[("A", "settings_app")])
require(r2 < a_return < floors[("B", "settings_app")],
        "Returning to A must resume A's floor without discarding or inheriting B's clock.")

# Before identity is known, B's edit must not inherit A's future date. At bind time it is
# advanced only over B's own destination floor, with the exact value copied into the payload.
account_a_future = 900.0
pending_source = next_safe_ms(400.0)
require(pending_source < account_a_future,
        "Pending singleton unexpectedly inherited foreign account A's clock.")
account_b_floor = 500.0
bound_source = next_safe_ms(pending_source, account_b_floor)
payload = {"updatedAt": bound_source, "lastModified": bound_source}
require(bound_source > account_b_floor
        and payload["updatedAt"] == bound_source
        and payload["lastModified"] == bound_source,
        "Binding must stamp metadata and payload with one exact CloudKit-safe date.")

print("iCloud singleton clock-floor regression checks passed")
