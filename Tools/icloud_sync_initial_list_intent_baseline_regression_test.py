#!/usr/bin/env python3
"""Pins R1 payload authority while an initial upload plan is suspended."""

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


apply_plan = method_body(MANAGER, "func applyInitialUploadPlan")
subscription_branch = apply_plan[apply_plan.find("subscriptionBackfillOffset != nil"):]
subscription_branch = subscription_branch[:subscription_branch.find("applyInitialSubscriptionQueue")]
require("intent.payloadDictionary()" in subscription_branch
        and "subscriptionListSettingsFingerprint(payload:" in subscription_branch,
        "Initial list backfill must derive its baseline from the exact durable R1 intent payload.")
require("Self.subscriptionListSettingsFingerprint()" not in subscription_branch,
        "A live P2 fingerprint must never mark an older queued R1 payload as already sent.")


def suspended_plan_result(intent_payload: dict, live_payload_after_suspend: dict) -> tuple[dict, str]:
    queued = intent_payload
    baseline = repr(sorted(intent_payload.items()))
    require(baseline != repr(sorted(live_payload_after_suspend.items())),
            "The regression fixture must contain a genuine R1→P2 change.")
    return queued, baseline


r1 = {"sortMode": "manual", "mainMenuListUIDs": ["default.favorites"]}
p2 = {"sortMode": "date", "mainMenuListUIDs": ["default.downloaded"]}
queued, baseline = suspended_plan_result(r1, p2)
require(queued == r1 and baseline == repr(sorted(r1.items())),
        "The queued payload and its baseline must remain the same R1 revision.")

print("iCloud initial list-intent baseline regression checks passed")
