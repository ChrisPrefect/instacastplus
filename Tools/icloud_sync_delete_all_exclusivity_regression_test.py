#!/usr/bin/env python3
"""Pins delete-all as one exclusive CloudKit lifecycle transaction."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
SOURCE = MANAGER + "\n" + (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
GATE = "isDeletingAllICloudData"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require(f"var {GATE} = false" in MANAGER,
        "Delete-all needs an explicit MainActor exclusivity gate.")

delete_all = method_body("@objc func deleteAllICloudDataWithCompletion")
gate_on = delete_all.find(f"{GATE} = true")
first_await = delete_all.find("await ")
require(gate_on != -1 and first_await != -1 and gate_on < first_await,
        "Delete-all must close the producer gate before its first suspension point.")
require("defer" in delete_all and f"{GATE} = false" in delete_all,
        "Every delete-all error/early-return path must reopen the producer gate.")

refresh = delete_all.find("await refreshAccountStatus()")
capture_initial = delete_all.find("let activeInitialQueueTask = initialQueueTask")
cancel_initial = delete_all.find("cancelInitialQueueTask()", capture_initial)
await_initial = delete_all.find("await activeInitialQueueTask.value", cancel_initial)
zone_delete = delete_all.find("deleteRecordZone")
local_reset = delete_all.find("resetAllLocalSyncMetadata()")
gate_off = delete_all.rfind(f"{GATE} = false")
intentional_restart = delete_all.find("scheduleCurrentEnabledDataForUpload()")
require(
    -1 not in [refresh, capture_initial, cancel_initial, await_initial, zone_delete,
               local_reset, gate_off, intentional_restart]
    and refresh < capture_initial < cancel_initial < await_initial < zone_delete
    < local_reset < gate_off < intentional_restart,
    "The old initial writer must be cancelled and awaited before zone deletion; the gate may reopen only after local reset and before the intentional fresh upload.",
)

# Account refresh is the existing drain barrier for all other tracked CloudKit work.
account_refresh = method_body("func performAccountStatusRefresh() async")
for marker, label in [
    ("await cancelAndAwaitLowPrioritySync()", "low-priority sync"),
    ("await activeManualSyncTask.value", "manual sync"),
    ("await activeBackgroundSyncTask.value", "background sync"),
    ("await awaitFinalDeviceRecordUpdate()", "final device send"),
]:
    require(marker in account_refresh,
            f"Account refresh must drain the active {label} before delete-all continues.")


def guarded_before_start(signature: str, start_marker: str) -> bool:
    body = method_body(signature)
    start = body.find(start_marker)
    return start != -1 and GATE in body[:start]


producer_guards = {
    "initial": guarded_before_start(
        "func scheduleCurrentEnabledDataForUpload()", "initialQueueTask = Task.detached"
    ),
    "low": guarded_before_start(
        "func scheduleLowPrioritySync()", "lowPrioritySyncTask = Task.detached"
    ),
    "final": guarded_before_start(
        "func sendFinalDeviceRecordUpdate()", "finalDeviceRecordUpdateTask = Task"
    ),
}

# Manual/background entry points suspend for account verification before assigning their
# tracked operation. They need a gate check both when the wrapper starts and after that await.
for signature, name in [
    ("@objc func performManualSyncWithCompletion", "manual"),
    ("@objc func performBackgroundSyncWithCompletion", "background"),
]:
    body = method_body(signature)
    wrapper = body.find("Task { @MainActor in")
    refresh = body.find("await refreshAccountStatus()", wrapper)
    operation = body.find("let operation = Task", refresh)
    producer_guards[name] = (
        -1 not in [wrapper, refresh, operation]
        and GATE in body[wrapper:refresh]
        and GATE in body[refresh:operation]
    )

# Deterministic interleaving: attempt every producer while deleteRecordZone is suspended.
# A source-backed guard on every start path means none can acquire a task handle or writer.
started_during_zone_delete = [name for name, guarded in producer_guards.items() if not guarded]
require(
    not started_during_zone_delete,
    "Delete-all currently permits producers during the zone-delete suspension: "
    + ", ".join(started_during_zone_delete),
)


print("iCloud delete-all exclusivity regression checks passed")
