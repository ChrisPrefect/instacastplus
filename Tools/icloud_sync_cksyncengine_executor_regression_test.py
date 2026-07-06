#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker=None):
    # Brace-matching extraction: the old "cut at the next member" heuristic broke when
    # the manager was split into files and member access became internal.
    require(signature in source, f"{signature} is missing.")
    start = source.find(signature)
    brace = source.find("{", start)
    require(brace != -1, f"{signature} has no body.")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


MANAGER = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])

low_priority_sync = method_body(MANAGER, "func scheduleLowPrioritySync")
require("Task.detached(priority: .background)" in low_priority_sync, "Low-priority sync must cross a detached scheduling boundary before calling CKSyncEngine; otherwise sendChanges can recurse from CKSyncEngine delegate callbacks and trip CloudKit's executor assertion.")
require("MainActor.run" not in low_priority_sync, "CKSyncEngine must not be pulled out of MainActor.run and then used elsewhere.")
require("return self.syncEngine" not in low_priority_sync, "CKSyncEngine must not be handed across actor boundaries.")
require("await self.performLowPrioritySync()" in low_priority_sync, "The detached scheduler must hop into a dedicated manager helper after leaving any CKSyncEngine delegate callback task.")
require("try await syncEngine.sendChanges()" not in low_priority_sync, "scheduleLowPrioritySync must not call sendChanges directly from the inherited task context.")
require("try await syncEngine.fetchChanges()" not in low_priority_sync, "scheduleLowPrioritySync must not call fetchChanges directly from the inherited task context.")

perform_low_priority_sync = method_body(MANAGER, "func performLowPrioritySync")
require("try await syncEngine.sendChanges()" in perform_low_priority_sync, "Low-priority sync must send through the manager-owned engine.")
require("try await syncEngine.fetchChanges()" in perform_low_priority_sync, "Low-priority sync must fetch through the manager-owned engine.")

handle_event = method_body(MANAGER, "func handleEventOnMain")
require("await handleSentRecordZoneChanges(event, syncEngine: syncEngine)" in handle_event, "Sent-record retry handling must receive the event callback's CKSyncEngine.")

sent_records = method_body(MANAGER, "func handleSentRecordZoneChanges")
require("syncEngine.state.add(pendingDatabaseChanges: retryZones)" in sent_records, "Retry zone changes must be added to the callback CKSyncEngine.")
require("syncEngine.state.add(pendingRecordZoneChanges: retryRecords)" in sent_records, "Retry record changes must be added to the callback CKSyncEngine.")
require("syncEngine?.state.add" not in sent_records, "Retry handling must not mutate CKSyncEngine through the stored optional property.")
