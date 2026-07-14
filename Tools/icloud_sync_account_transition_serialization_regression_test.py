#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
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


require("isICloudAccountTransitionRunning" in MANAGER
        and "iCloudAccountTransitionWaiters" in MANAGER,
        "Overlapping A→B→C transitions need one process-wide serialized account transaction gate.")

acquire = method_body(REMOTE, "func acquireICloudAccountTransition")
release = method_body(REMOTE, "func releaseICloudAccountTransition")
require("withCheckedContinuation" in acquire
        and "iCloudAccountTransitionWaiters.append" in acquire,
        "A second account transition must wait instead of rotating another pending scope concurrently.")
require("removeFirst()" in release and ".resume()" in release,
        "Queued account transitions must resume FIFO, preserving each transition's outbox scope ownership.")

account_change = method_body(REMOTE, "func handleAccountChange")
require(account_change.find("await acquireICloudAccountTransition()")
        < account_change.find("clearError()")
        and "defer { releaseICloudAccountTransition() }" in account_change,
        "Every CK account event must hold the transition gate across switch cleanup and reconciliation.")
account_cancel_guard = account_change.find("guard !Task.isCancelled else { return }")
require(account_cancel_guard != -1
        and account_cancel_guard < account_change.find("clearError()"),
        "A cancelled CK event waiter must release the FIFO gate without mutating account state.")
require("handleAccountChange(event, syncEngine: syncEngine)" in ENGINE
        and account_change.find("guard syncEngine === self.syncEngine else { return }")
            < account_change.find("clearError()"),
        "An old engine's account event queued behind a newer transition must be discarded after acquiring the gate.")

account_refresh = method_body(METADATA, "func performAccountStatusRefresh")
acquire_index = account_refresh.find("await acquireICloudAccountTransition()")
identity_close = account_refresh.find("setICloudAccountIdentityVerified(false)")
status_lookup = account_refresh.find("container.accountStatus()")
require(-1 not in (acquire_index, identity_close, status_lookup)
        and acquire_index < identity_close < status_lookup
        and "defer { releaseICloudAccountTransition() }" in account_refresh,
        "Manual/foreground account reconciliation must share the same serialized transition gate.")
cancel_guard = account_refresh.find("guard !Task.isCancelled else { return }")
require(acquire_index < cancel_guard < identity_close,
        "A queued account refresh cancelled before gate acquisition must not later close identity or reconcile.")

reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require("let pendingScope = currentPendingLocalOutboxScope()" in reconcile
        and "bindPendingAccountLocalOutboxEntries" in reconcile
        and "bindSyncItemMetadata" in reconcile,
        "A serialized transition must bind exactly its captured outbox and metadata scope before reopening callbacks.")

print("iCloud account-transition serialization regression checks passed")
