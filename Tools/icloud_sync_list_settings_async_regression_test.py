#!/usr/bin/env python3
"""Pins one asynchronous committed EpisodeList read per debounced settings check."""

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


schedule = method_body(LOCAL, "func scheduleSettingsChangeCheck")
require("settingsChangeCheckRevision" in schedule
        and "await self?.checkAndQueueSettingsChange" in schedule,
        "Every debounced checker needs an identity that invalidates an older suspended read.")
checker = method_body(LOCAL, "func checkAndQueueSettingsChange")
require(checker.count("committedSubscriptionListSettingsPayload()") == 1,
        "The checker must read the committed EpisodeList graph exactly once.")
require("await Self.committedSubscriptionListSettingsPayload()" in checker
        and "subscriptionListSettingsFingerprint(payload:" in checker
        and "payload: subscriptionListSettingsPayload" in checker,
        "One async committed payload must drive both fingerprinting and intent capture.")
for token in ["cloudAccountGeneration", "settingsChangeCheckRevision", "localOutboxCaptureAccountRecordName"]:
    require(token in checker, f"The suspended checker must revalidate {token} before committing.")
require("Self.subscriptionListSettingsFingerprint()" not in checker
        and "subscriptionListSettingsPayload(in:" not in checker
        and "Self.hasLocalEpisodeListSettings()" not in checker,
        "The MainActor checker must not trigger a synchronous or second full list-graph fetch.")

print("iCloud async list-settings regression checks passed")
