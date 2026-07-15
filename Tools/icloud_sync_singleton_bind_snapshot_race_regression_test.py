#!/usr/bin/env python3
"""Pins target-account singleton intents created while account binding is suspended."""

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
class Intent:
    account: str
    record: str
    sequence: int
    payload: str


def bind(snapshot: list[Intent], source: str, target: str) -> list[Intent]:
    result = list(snapshot)
    source_intents = [intent for intent in result if intent.account == source]
    result = [intent for intent in result if intent.account != source]
    for source_intent in source_intents:
        destination = next(
            (
                intent
                for intent in reversed(result)
                if intent.account == target and intent.record == source_intent.record
            ),
            None,
        )
        winner = destination if destination and destination.sequence > source_intent.sequence else Intent(
            target,
            source_intent.record,
            source_intent.sequence,
            source_intent.payload,
        )
        result = [
            intent
            for intent in result
            if not (intent.account == target and intent.record == source_intent.record)
        ]
        result.append(winner)
    return result


# Binder reads source R2, then suspends for the list-outbox fetch. The verified-account
# gate is already open, so a new target R4 can be durably captured while it is suspended.
source_r2 = Intent("pending", "settings_app", 2, "payload-2")
target_r4 = Intent("target", "settings_app", 4, "payload-4")
stale_snapshot = [source_r2]
durable_after_suspend = [source_r2, target_r4]
unsafe_rewrite = bind(stale_snapshot, "pending", "target")
require(unsafe_rewrite[-1].payload == "payload-2",
        "The stale-snapshot fixture no longer demonstrates loss of R4")
safe_rewrite = bind(durable_after_suspend, "pending", "target")
require(safe_rewrite == [target_r4],
        "Re-reading after suspension did not preserve the newer target-account R4")


body = method_body(MANAGER, "func bindPendingSingletonUploadIntents")
await_index = body.find("try await Self.localOutboxEntries")
require(await_index != -1, "Account binding no longer has the expected suspension point")
initial_snapshot = body.find("var intents = Self.pendingSingletonUploadIntents()")
fresh_snapshot = body.find("Self.pendingSingletonUploadIntents()", await_index)
require(initial_snapshot > await_index or fresh_snapshot != -1,
        "Account binding rewrites the intent file from a snapshot taken before an await.")

print("iCloud singleton bind snapshot-race regression checks passed")
