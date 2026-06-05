#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker="\n    private func "):
    require(signature in source, f"{signature} is missing.")
    return source.split(signature, 1)[1].split(next_marker, 1)[0]


MANAGER = read("Classes/ICiCloudSyncManager.swift")

low_priority_sync = method_body(MANAGER, "private func scheduleLowPrioritySync")
require("Task(priority: .background)" in low_priority_sync, "Low-priority sync must still be scheduled at background priority.")
require("Task.detached" not in low_priority_sync, "CKSyncEngine send/fetch must not run from a detached task.")
require("MainActor.run" not in low_priority_sync, "CKSyncEngine must not be pulled out of MainActor.run and then used elsewhere.")
require("return self.syncEngine" not in low_priority_sync, "CKSyncEngine must not be handed across actor boundaries.")
require("try await syncEngine.sendChanges()" in low_priority_sync, "Low-priority sync must send through the manager-owned engine.")
require("try await syncEngine.fetchChanges()" in low_priority_sync, "Low-priority sync must fetch through the manager-owned engine.")

handle_event = method_body(MANAGER, "private func handleEventOnMain")
require("await handleSentRecordZoneChanges(event, syncEngine: syncEngine)" in handle_event, "Sent-record retry handling must receive the event callback's CKSyncEngine.")

sent_records = method_body(MANAGER, "private func handleSentRecordZoneChanges")
require("syncEngine.state.add(pendingDatabaseChanges: retryZones)" in sent_records, "Retry zone changes must be added to the callback CKSyncEngine.")
require("syncEngine.state.add(pendingRecordZoneChanges: retryRecords)" in sent_records, "Retry record changes must be added to the callback CKSyncEngine.")
require("syncEngine?.state.add" not in sent_records, "Retry handling must not mutate CKSyncEngine through the stored optional property.")

