#!/usr/bin/env python3
"""Pins conflict retries as handled work so large episode backfills keep sending."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature):
    require(signature in source, f"{signature} is missing.")
    start = source.find(signature)
    brace = source.find("{", start)
    require(brace != -1, f"{signature} has no body.")
    depth = 0
    for index in range(brace, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


failed_save = method_body(REMOTE, "func handleFailedRecordSave")
episode_retry = failed_save.split(
    "if serverRecord.recordType == RecordKind.episodeState {",
    2,
)[2].split("}", 1)[0]

require(
    "retryRecords.append(.saveRecord(recordID))" in episode_retry,
    "A reconciled episode conflict must retain its save for retry with server system fields.",
)
require(
    "return true" in episode_retry,
    "A reconciled episode conflict must be reported as handled so sendChanges continues "
    "without error backoff.",
)

sent_changes = method_body(REMOTE, "func handleSentRecordZoneChanges")
require(
    "if !(await handleFailedRecordSave(" in sent_changes,
    "Only genuinely unhandled record failures may set the unresolved-failure state.",
)

print("iCloud episode conflict retry regression checks passed")
