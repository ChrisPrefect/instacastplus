#!/usr/bin/env python3
"""Pins handled CKSyncEngine record conflicts below the user-visible error boundary."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
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


sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
require(
    "handledRecordZonePartialFailureInCurrentSend = true" in sent,
    "A send callback whose record failures were all reconciled must report that outcome.",
)
handled_marker = sent.find("handledRecordZonePartialFailureInCurrentSend = true")
failure_branch = sent.find("if hasFailedRecordChanges")
require(
    handled_marker != -1 and failure_branch != -1 and handled_marker > failure_branch,
    "The handled marker must be decided from the final record-failure classification.",
)

send_loop = method_body(MANAGER, "func sendChangesAndApplyCallbackOutcomes")
for token in [
    "handledRecordZonePartialFailureInCurrentSend = false",
    "ckError?.code == .partialFailure",
    "handledRecordZonePartialFailureInCurrentSend",
    "!hasUnresolvedSyncFailures",
    "continue",
]:
    require(token in send_loop, f"Handled partial-failure send loop is missing: {token}")

catch_body = send_loop.split("} catch {", 1)[1].split("\n            }", 1)[0]
require(
    "throw error" in catch_body,
    "Real send failures must still escape to status, retry, and manual-sync UI handling.",
)
require(
    catch_body.find("ckError?.code == .partialFailure") < catch_body.find("throw error"),
    "Only an explicitly handled partial failure may bypass the real-error throw.",
)

print("iCloud handled partial-failure regression checks passed")
