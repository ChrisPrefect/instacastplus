#!/usr/bin/env python3
"""Pins hard cloud inventory behind user-requested sync work."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
SETTINGS = (ROOT / "Classes" / "ICiCloudSyncSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


toggle = method_body(SETTINGS, "- (void)toggleSyncOption:")
request = "requestCloudInventoryRefreshAfterOptionChange"
first_manager_mutation = min(
    position for position in [
        toggle.find("setEpisodesSyncEnabled:"),
        toggle.find("setSubscriptionsSyncEnabled:"),
        toggle.find("setSettingsSyncEnabled:"),
    ] if position >= 0
)
require(
    toggle.find(request) >= 0 and toggle.find(request) < first_manager_mutation,
    "A switch must cancel/defer the optional full-zone inventory before it starts the "
    "user-requested sync.",
)

request_refresh = method_body(
    MANAGER, "@objc func requestCloudInventoryRefreshAfterOptionChange"
)
require(
    "cancelCloudInventoryRefreshForSync()" in request_refresh,
    "Requesting a post-sync inventory must cancel an in-flight pre-sync full-zone scan.",
)
require(
    "requestedCloudInventoryRefreshMustRun" in request_refresh,
    "Cancelling an already-needed inventory for an option change must remember that the "
    "post-sync scan is mandatory even when the option change produces no user records.",
)

run_requested = method_body(MANAGER, "func runRequestedCloudInventoryRefresh")
require(
    "afterCompletedSync: true" in run_requested,
    "The requested inventory must be allowed to start at logical sync completion while "
    "the owning task is still releasing its activity token.",
)
require(
    "requestedCloudInventoryRefreshMustRun" in run_requested,
    "The no-op option gate must not discard a view/cleanup inventory that was interrupted "
    "to prioritize sync.",
)

refresh = method_body(MANAGER, "func refreshCloudInventory(reason:")
require(
    "syncInProgress" in refresh
    and refresh.find("syncInProgress") < refresh.find("isFetchingCloudInventory"),
    "A full-zone inventory requested during active sync must be deferred, not compete "
    "with send/fetch work.",
)
require(
    "cloudInventoryRefreshGeneration" in refresh,
    "Cancelled inventory preparation and callbacks must be rejected by request generation.",
)
require(
    "cloudInventoryOperation = operation" in refresh,
    "The active CloudKit inventory operation must be owned so a switch can cancel it.",
)

cancel = method_body(MANAGER, "func cancelCloudInventoryRefreshForSync")
for expected in [
    "cloudInventoryRefreshGeneration &+= 1",
    "cloudInventoryCancellationToken?.cancel()",
    "cloudInventoryOperation?.cancel()",
    "cloudInventoryOperation = nil",
    "isFetchingCloudInventory = false",
]:
    require(expected in cancel, f"Inventory cancellation is missing: {expected}")

reset = method_body(REMOTE, "func resetForICloudAccountTransition")
require(
    "cancelCloudInventoryRefreshForSync()" in reset,
    "Sign-out/account transition must stop old-account inventory I/O, not merely ignore "
    "its eventual callback.",
)

local_reset = method_body(MANAGER, "@objc func prepareForLocalAppResetWithCompletion")
first_destructive_delete = min(
    local_reset.find(token) for token in [
        "deleteAllPendingEpisodeStates",
        "deleteAllPendingSubscriptionStates",
        "deleteSyncItemMetadata",
        "deleteKnownRecordSystemFields",
        "deleteAllLocalOutboxEntriesForLocalReset",
    ] if local_reset.find(token) >= 0
)
require(
    0 <= local_reset.find("cancelCloudInventoryRefreshForSync()") < first_destructive_delete,
    "Local reset must cancel inventory preparation and CloudKit callbacks before deleting "
    "any local sync metadata.",
)


print("iCloud inventory sync-priority regression checks passed")
