#!/usr/bin/env python3
"""Pins account-scoped outbox reset to bounded off-main Core Data deletes."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise SystemExit(f"Unterminated method: {signature}")


delete_entries = method_body(
    LOCAL,
    "func deleteLocalOutboxEntries(for accountRecordName: String) async throws",
)
require(
    "newICloudSyncBackgroundContext()" in delete_entries
    and "await backgroundContext.perform" in delete_entries
    and "managedObjectIDResultType" in delete_entries
    and "fetchLimit = Self.pendingChangeQueueChunkSize" in delete_entries
    and "NSBatchDeleteRequest(objectIDs:" in delete_entries,
    "Delete-all must fetch and delete only one bounded outbox-ID page on a private context.",
)
require(
    "while true" in delete_entries
    and "await Task.yield()" in delete_entries
    and "databaseManager.saveReturningError" not in delete_entries,
    "Large account outboxes must drain in yielded background batches, never one main-context save.",
)
require(
    "NSDeletedObjectIDsKey" in delete_entries
    and "NSManagedObjectContext.mergeChanges" in delete_entries
    and "context.processPendingChanges()" in delete_entries
    and "performSynchronousRemoteViewContextMerge" not in delete_entries
    and "isApplyingRemoteChange" not in delete_entries,
    "Each small receipt-only deletion page must invalidate the view context without suppressing user edits.",
)

delete_all = method_body(MANAGER, "@objc func deleteAllICloudDataWithCompletion")
transition = delete_all.find("await acquireICloudAccountTransition()")
delete_call = delete_all.find("try await deleteLocalOutboxEntries")
require(
    -1 < transition < delete_call
    and "deleteLocalOutboxEntries(for:" not in delete_all[:transition],
    "Account producers must be stopped before the awaited outbox reset starts.",
)


SWIFT_PROOF = r'''
import CoreData
import Foundation

func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    return attribute
}

let model = NSManagedObjectModel()
let outbox = NSEntityDescription()
outbox.name = "Outbox"
outbox.managedObjectClassName = "NSManagedObject"
outbox.properties = [
    attribute("account", .stringAttributeType),
    attribute("record", .stringAttributeType),
]
outbox.uniquenessConstraints = [["account", "record"]]
model.entities = [outbox]

let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("outbox-delete-all-\(UUID().uuidString).sqlite")
let mainCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try mainCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
let workerCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try workerCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL)
let main = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
main.persistentStoreCoordinator = mainCoordinator
for index in 0..<4_500 {
    let entry = NSEntityDescription.insertNewObject(forEntityName: "Outbox", into: main)
    entry.setValue("target", forKey: "account")
    entry.setValue("target-\(index)", forKey: "record")
}
for index in 0..<10 {
    let entry = NSEntityDescription.insertNewObject(forEntityName: "Outbox", into: main)
    entry.setValue("other", forKey: "account")
    entry.setValue("other-\(index)", forKey: "record")
}
try main.save()

let worker = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
worker.persistentStoreCoordinator = workerCoordinator
var pageCount = 0
var maximumPageSize = 0
while true {
    let objectIDs: [NSManagedObjectID] = try worker.performAndWait {
        let request = NSFetchRequest<NSManagedObjectID>(entityName: "Outbox")
        request.resultType = .managedObjectIDResultType
        request.predicate = NSPredicate(format: "account == %@", "target")
        request.fetchLimit = 250
        let ids = try worker.fetch(request)
        guard !ids.isEmpty else { return [] }
        let deleteRequest = NSBatchDeleteRequest(objectIDs: ids)
        try worker.execute(deleteRequest)
        worker.reset()
        return ids
    }
    guard !objectIDs.isEmpty else { break }
    pageCount += 1
    maximumPageSize = max(maximumPageSize, objectIDs.count)
    let uriSet = Set(objectIDs.map { $0.uriRepresentation() })
    let mainIDs = uriSet.compactMap { mainCoordinator.managedObjectID(forURIRepresentation: $0) }
    NSManagedObjectContext.mergeChanges(
        fromRemoteContextSave: [NSDeletedObjectIDsKey: mainIDs],
        into: [main]
    )
    main.processPendingChanges()
}

let check = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
check.persistentStoreCoordinator = workerCoordinator
try check.performAndWait {
    let target = NSFetchRequest<NSManagedObject>(entityName: "Outbox")
    target.predicate = NSPredicate(format: "account == %@", "target")
    let other = NSFetchRequest<NSManagedObject>(entityName: "Outbox")
    other.predicate = NSPredicate(format: "account == %@", "other")
    let targetCount = try check.count(for: target)
    let otherCount = try check.count(for: other)
    precondition(targetCount == 0)
    precondition(otherCount == 10)
}
precondition(pageCount == 18)
precondition(maximumPageSize == 250)
print("4,500 outbox rows deleted in 18 bounded pages")
'''


with tempfile.TemporaryDirectory(prefix="instacast-outbox-delete-all-") as temporary_path:
    temporary = Path(temporary_path)
    source = temporary / "proof.swift"
    executable = temporary / "proof"
    source.write_text(SWIFT_PROOF)
    compile_result = subprocess.run(
        ["xcrun", "swiftc", str(source), "-o", str(executable)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    require(compile_result.returncode == 0, compile_result.stdout)
    proof_result = subprocess.run(
        [str(executable)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    require(proof_result.returncode == 0, proof_result.stdout)
    require(
        "4,500 outbox rows deleted in 18 bounded pages" in proof_result.stdout,
        "The bounded account-delete runtime proof did not complete.",
    )

print("iCloud outbox delete-all responsiveness regression checks passed")
