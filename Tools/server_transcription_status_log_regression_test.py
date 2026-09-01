#!/usr/bin/env python3
"""Regression contract for server transcription status-detail logging."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ServerTranscriptionManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace : index + 1]
    raise SystemExit(f"Unterminated body: {signature}")


status_update = function_body(
    MANAGER,
    "private func updateStatusDetail(_ detail: String, for item:",
)
require(
    status_update.find("guard item.statusDetail != detail else { return }")
    < status_update.find("TranscriptionLogger.shared.append")
    and 'phase: "status"' in status_update
    and "message: detail" in status_update,
    "Server status details are not deduplicated into the per-episode transcription log.",
)

process_next = function_body(MANAGER, "private func processNext()")
apply = function_body(MANAGER, "private func apply(_ envelope:")
handle = function_body(MANAGER, "private func handle(error:")
for detail in [
    "Server verarbeitet die Episode.",
    "Server-Ergebnis wird geprüft und übernommen.",
    "Server-Ergebnis konnte vorübergehend nicht geladen werden. Neuer Versuch ist geplant.",
]:
    require(
        f'updateStatusDetail(NSLocalizedString("{detail}"' in process_next + apply,
        f"Live server status bypasses the central log helper: {detail}",
    )
require(
    "updateStatusDetail(phase, for: item)" in apply,
    "Server queue/running phases are still invisible in the detailed log.",
)
require(
    'updateStatusDetail(NSLocalizedString("Server vorübergehend nicht erreichbar.' in handle,
    "Transient server connectivity status is still invisible in the detailed log.",
)


print("server transcription status-log regression checks passed")
