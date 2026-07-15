#!/usr/bin/env python3
"""Pins crash-safe persistence ordering for singleton payloads and clock floors."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


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
class DurableState:
    floor: float
    intent_payload: str | None
    intent_date: float | None


old = DurableState(floor=500.0, intent_payload=None, intent_date=None)
new_date = 501.0

# Current floor-first sequence: a kill after the first atomic file replace records a
# newer clock but loses the only payload/revision telling the app what to upload.
unsafe_kill = DurableState(floor=new_date, intent_payload=None, intent_date=None)
require(unsafe_kill.floor == new_date and unsafe_kill.intent_payload is None,
        "The fixture no longer represents the floor-only kill window")

# Crash-safe state machine: payload first, then floor. Every creation prefix either
# contains the complete retryable mutation or is still exactly the old state.
creation_prefixes = [
    old,
    DurableState(floor=old.floor, intent_payload="payload-r2", intent_date=new_date),
    DurableState(floor=new_date, intent_payload="payload-r2", intent_date=new_date),
]
for state in creation_prefixes:
    require(
        state == old
        or (state.intent_payload == "payload-r2" and state.intent_date == new_date),
        f"Creation kill prefix lost its retryable mutation: {state}",
    )

# ACK cleanup is the inverse ordering: preserve the floor before deleting the intent.
# Every cleanup prefix retains the payload or has already made its timestamp durable.
cleanup_prefixes = [
    creation_prefixes[-1],
    DurableState(floor=new_date, intent_payload="payload-r2", intent_date=new_date),
    DurableState(floor=new_date, intent_payload=None, intent_date=None),
]
for state in cleanup_prefixes:
    require(state.intent_payload is not None or state.floor >= new_date,
            f"ACK cleanup lost both singleton payload and causal floor: {state}")


persist = method_body(MANAGER, "func persistPendingSingletonUploadIntent")
intent_write = persist.find("writePendingSingletonUploadIntents")
floor_write = persist.find("persistSingletonClockFloor")
combined_write = "writePendingSingletonUploadState" in persist
require(combined_write or (
    intent_write != -1 and floor_write != -1 and intent_write < floor_write
), "Singleton creation persists its clock floor before its payload/revision retry intent.")

clear = method_body(MANAGER, "func clearPendingSingletonUploadIntent")
clear_intent_write = clear.find("writePendingSingletonUploadIntents")
clear_floor_write = clear.find("persistSingletonClockFloor")
combined_clear = "writePendingSingletonUploadState" in clear
require(combined_clear or (
    clear_floor_write != -1
    and clear_intent_write != -1
    and clear_floor_write < clear_intent_write
), "Singleton ACK cleanup can remove the intent without durably preserving its exact clock floor.")

print("iCloud singleton intent/clock atomicity regression checks passed")
