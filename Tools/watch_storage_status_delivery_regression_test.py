#!/usr/bin/env python3
"""Pins Watch storage status as a coalesced best-effort snapshot.

The Watch emits this periodic status while downloads run.  Historical snapshots have
no durable meaning, so an offline phone must not accumulate one transferUserInfo item
every ten seconds.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchConnectivityController.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


send_status = function_body(SOURCE, "func sendStorageStatus()")
finish_status = function_body(SOURCE, "private func finishStorageStatus(")
require(
    "storageStatusScanInFlight" in send_status
    and "storageStatusResendRequested" in send_status
    and "await WatchStorageManager.measureStatus" in send_status,
    "Concurrent periodic storage requests must remain one in-flight measurement plus one "
    "coalesced latest resend.",
)
require(
    'send(type: "watch.storageStatus"' in finish_status
    and "delivery: .live" in finish_status,
    "Storage status is a replaceable best-effort snapshot and must use the live channel, which "
    "drops offline instead of enqueueing durable user-info transfers.",
)
require(
    "delivery: .reliable" not in finish_status
    and "delivery: .durable" not in finish_status
    and "transferUserInfo" not in finish_status,
    "Periodic storage status must never select a queued WatchConnectivity delivery path.",
)
require(
    "storageStatusScanInFlight = false" in finish_status
    and "if storageStatusResendRequested" in finish_status
    and "sendStorageStatus()" in finish_status,
    "Finishing a scan must release ownership and collapse every overlapping request into one "
    "fresh snapshot.",
)

send = function_body(SOURCE, "func send(type:")
live_preflight = send.find("if case .live = delivery")
revision_allocation = send.find('message["watchEventRevision"]')
require(
    -1 not in (live_preflight, revision_allocation)
    and live_preflight < revision_allocation
    and "!WCSession.default.isReachable" in send[live_preflight:revision_allocation],
    "An offline best-effort snapshot must be rejected before allocating/persisting an event "
    "revision; otherwise the ten-second timer still performs pointless durable writes.",
)
live = send.split("case .live:", 1)[1].split("case ", 1)[0]
require(
    "guard WCSession.default.isReachable else { return false }" in live
    and "sendMessage" in live
    and "transferUserInfo" not in live,
    "The live channel must be a strict best-effort send with no offline durable fallback.",
)

print("Watch storage-status delivery regression checks passed")
