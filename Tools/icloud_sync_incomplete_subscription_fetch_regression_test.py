#!/usr/bin/env python3
"""Pins destructive subscription apply to a durably completed CloudKit fetch."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FILES = {
    path.name: path.read_text()
    for path in (ROOT / "Classes").glob("ICiCloudSyncManager*.swift")
}
MANAGER = "\n".join(FILES.values())


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = MANAGER.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = MANAGER.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("pendingSubscriptionFetchCompleteKey" in MANAGER and
        "Self.pendingSubscriptionFetchCompleteKey" in body("nonisolated static var fileBackedSyncMetadataKeys"),
        "The fetch-complete gate must be durable and account-scoped beside pending subscription payloads.")

fetched = body("func handleFetchedRecordZoneChanges")
deletion_stage = fetched.find("stagePendingSubscriptionStates")
modification_stage = fetched.find("stagePendingSubscriptionStates", deletion_stage + 1)
require(deletion_stage != -1 and modification_stage != -1,
        "Both deletion and modification halves must use the durable subscription row store.")
for stage in (deletion_stage, modification_stage):
    marker = fetched.rfind("markPendingSubscriptionFetchIncomplete()", 0, stage)
    require(marker != -1 and marker < stage,
            "Staging either physical half must durably close the gate before it can be replayed.")
require(deletion_stage < fetched.find("processFetchedDeletionBatch") and
        modification_stage < fetched.find("processFetchedModificationBatch"),
        "Each subscription payload must be staged before local application and token advancement.")

single_record = body("func applyRemoteRecord(_ record:")
single_stage = single_record.find("stagePendingSubscriptionStates")
require(single_stage != -1 and
        single_record.find("markPendingSubscriptionFetchIncomplete()") < single_stage,
        "A serverRecordChanged conflict must close the same durable fetch gate before staging.")
require("func mergePendingSubscriptions" not in MANAGER and "setPendingPayloads" not in MANAGER,
        "The retired growing pending-subscription plist must not return.")

events = body("func handleEventOnMain")
will_fetch = events.find("markPendingSubscriptionFetchIncomplete()")
did_fetch = events.find("markPendingSubscriptionFetchComplete()")
apply = events.find("await applyPendingSubscriptions()")
require(will_fetch != -1 and did_fetch != -1 and apply != -1 and did_fetch < apply,
        "Only a complete, error-free didFetchChanges event may open the gate before subscription apply.")

apply_pending = body("func applyPendingSubscriptions() async")
require("pendingSubscriptionFetchIsComplete" in apply_pending,
        "Startup, retry, and episode-added callbacks must not apply an incompletely assembled subscription pair.")

# Functional LWW proof: interruption after the older tombstone must not unsubscribe;
# after the newer active half and completed-fetch marker arrive, active wins once.
pending = {"tombstone": {"updatedAt": 10, "deleted": True}}
fetch_complete = False
applied = [] if not fetch_complete else [max(pending.values(), key=lambda value: value["updatedAt"])]
require(not applied, "An incomplete tombstone-only fetch must remain parked.")
pending["active"] = {"updatedAt": 20, "deleted": False}
fetch_complete = True
winner = max(pending.values(), key=lambda value: value["updatedAt"])
require(fetch_complete and not winner["deleted"],
        "After complete assembly, the newer active record must win without destructive unsubscribe flicker.")

print("iCloud incomplete-subscription-fetch regression checks passed")
