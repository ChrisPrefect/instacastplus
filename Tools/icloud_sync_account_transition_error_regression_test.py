#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()


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


require("iCloudAccountTransitionToken" in MANAGER,
        "Account-transition errors need a token independent of cloudAccountGeneration.")
acquire = method_body(REMOTE, "func acquireICloudAccountTransition")
require("iCloudAccountTransitionToken &+= 1" in acquire
        and "return iCloudAccountTransitionToken" in acquire,
        "Each serialized account transition must receive a stable error-ownership token.")

account_change = method_body(REMOTE, "func handleAccountChange")
require("let transitionToken = await acquireICloudAccountTransition()" in account_change,
        "CK account-event error reporting must use the serialized transition token.")
require(account_change.count("transitionToken == iCloudAccountTransitionToken") >= 3,
        "Sign-in, switch and unknown-transition failures must remain visible for their active transition.")
require(account_change.count("scheduleSyncRetryAfterFailure") >= 5
        and account_change.count("setError(error)") >= 5,
        "Every legitimate account-transition failure must show an error and schedule its retry.")

account_refresh = method_body(METADATA, "func performAccountStatusRefresh")
require("let transitionToken = await acquireICloudAccountTransition()" in account_refresh
        and "guard transitionToken == iCloudAccountTransitionToken else { return }" in account_refresh,
        "An internally incremented cloud generation must not swallow account-status/reconcile failures.")

print("iCloud account-transition error regression checks passed")
