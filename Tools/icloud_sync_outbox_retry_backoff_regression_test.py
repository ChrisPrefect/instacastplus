#!/usr/bin/env python3
"""Pins immediate outbox re-drains to stale races, never persistence failures."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def declaration_and_body(signature: str) -> str:
    start = LOCAL.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = LOCAL.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(LOCAL)):
        if LOCAL[index] == "{":
            depth += 1
        elif LOCAL[index] == "}":
            depth -= 1
            if depth == 0:
                return LOCAL[start:index + 1]
    raise AssertionError(f"Unterminated method: {signature}")


def switch_body(source: str, awaited_call: str) -> str:
    start = source.find(f"switch await {awaited_call}")
    require(start != -1, f"Missing result switch for {awaited_call}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated result switch for {awaited_call}")


def branch(switch: str, label: str, next_label: str | None) -> str:
    start = switch.find(label)
    require(start != -1, f"Missing switch branch: {label}")
    end = switch.find(next_label, start + len(label)) if next_label else len(switch)
    require(end != -1, f"Missing following switch branch: {next_label}")
    return switch[start:end]


# A persistence write can keep failing until disk/store recovery. Re-entering the drain
# immediately defeats handleLocalPersistenceFailure's 15-second retry backoff and spins.
# A stale revision/intent CAS, on the other hand, is expected during concurrent edits and
# must coalesce one immediate re-drain so the newer durable revision is picked up.
require(
    "enum ICSubscriptionListOutboxPreparationResult" in LOCAL
    and "case success(ICCloudSyncOutboxSnapshot)" in LOCAL
    and "case staleRace" in LOCAL
    and "case persistenceFailure" in LOCAL,
    "List outbox preparation must preserve success, stale-race, and persistence-failure causes.",
)

expand = declaration_and_body("func expandCommittedSubscriptionListSettingsOutboxEntry")
align = declaration_and_body("func alignCommittedSubscriptionListSettingsOutboxEntry")
for name, method in (("expand", expand), ("align", align)):
    require(
        "ICSubscriptionListOutboxPreparationResult" in method,
        f"{name} must return the cause-aware preparation result.",
    )
    require(
        "handleLocalPersistenceFailure" in method and ".persistenceFailure" in method,
        f"{name} must route real store failures only through the retry backoff.",
    )
    require(
        ".staleRace" in method,
        f"{name} must preserve compare-and-swap races for an immediate coalesced re-drain.",
    )

drain = declaration_and_body("func drainLocalOutbox")
expand_switch = switch_body(
    drain, "expandCommittedSubscriptionListSettingsOutboxEntry("
)
align_switch = switch_body(
    drain, "alignCommittedSubscriptionListSettingsOutboxEntry("
)
for name, result_switch in (("expand", expand_switch), ("align", align_switch)):
    stale = branch(result_switch, "case .staleRace:", "case .persistenceFailure:")
    failure = branch(result_switch, "case .persistenceFailure:", None)
    require(
        "scheduleLocalOutboxDrain()" in stale and "return false" in stale,
        f"{name} stale races must request exactly one immediate follow-up drain.",
    )
    require(
        "scheduleLocalOutboxDrain()" not in failure and "return false" in failure,
        f"{name} persistence failures must wait for scheduleSyncRetryAfterFailure's backoff.",
    )

print("iCloud outbox retry/backoff regression checks passed")
