#!/usr/bin/env python3
"""Regression proof for non-blocking, revision-bound CloudKit outbox ACKs."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
MODEL8 = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model8.xcdatamodel" / "contents"


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
                return source[brace + 1 : index]
    raise SystemExit(f"Unterminated method: {signature}")


require(MODEL8.exists(), "ACK receipts require a new Model8; Model7 must remain immutable.")
model = ElementTree.parse(MODEL8).getroot()
outbox = next((entity for entity in model.findall("entity")
               if entity.get("name") == "ICCloudSyncOutboxEntry"), None)
require(outbox is not None, "Model8 must retain ICCloudSyncOutboxEntry.")
attributes = {attribute.get("name"): attribute for attribute in outbox.findall("attribute")}
for name in ("acknowledgedRevision", "acknowledgedOperation"):
    attribute = attributes.get(name)
    require(
        attribute is not None
        and attribute.get("attributeType") == "String"
        and attribute.get("optional") == "YES",
        f"Model8 must add optional {name} without changing Model7.",
    )

sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
require(
    "try await Self.acknowledgeLocalOutboxOperationsInBackground" in sent,
    "The sent-record callback must await one background ACK transaction.",
)
require(
    sent.count("acknowledgeLocalOutboxOperationsInBackground") == 1,
    "Successful saves and deletes must share one Core Data transaction per callback.",
)
ack_call = sent.index("acknowledgeLocalOutboxOperationsInBackground")
post_ack_guard = sent.find("generation == cloudAccountGeneration", ack_call)
consume = sent.find("consumeLocalOutboxAcknowledgementResult", post_ack_guard)
initial_progress = sent.find("recordInitialUploadRecordsSaved", consume)
require(
    0 <= ack_call < post_ack_guard < consume < initial_progress,
    "ACK results must be account/generation-validated before upload progress advances.",
)

worker = method_body(
    REMOTE,
    "nonisolated static func acknowledgeLocalOutboxOperationsInBackground",
)
require(
    "newICloudSyncBackgroundContext()" in worker
    and "await context.perform" in worker
    and "databaseManager.objectContext" not in worker
    and "saveReturningError" not in worker,
    "Outbox ACK fetch/CAS/save work must stay on the dedicated private queue.",
)
require(
    'currentRevision == sentAttempt.revision' in worker
    and 'currentOperation == sentAttempt.operation' in worker
    and 'sentAttempt.revision' in worker
    and 'forKey: "acknowledgedRevision"' in worker
    and 'sentAttempt.operation' in worker
    and 'forKey: "acknowledgedOperation"' in worker,
    "The worker must persist only exact revision/operation receipts.",
)
require(
    "context.delete(" not in worker
    and 'setValue(true, forKey: "acknowledged")' not in worker,
    "A background ACK must never delete or boolean-acknowledge the mutable outbox row.",
)
require(
    "attempt == 0" in worker
    and "NSCocoaErrorDomain" in worker
    and "133020" in worker,
    "A concurrent local edit must trigger one fresh CAS read.",
)
perform_position = worker.find("context.perform")
require(
    "let sentAttempts = sentAttemptsByRecordName" in worker[:perform_position]
    and "sentAttemptsByRecordName" not in worker[perform_position:],
    "The private-queue transaction must capture an immutable sent-attempt snapshot.",
)

decoder = method_body(LOCAL, "nonisolated static func localOutboxEntryIsAcknowledged")
require(
    'value(forKey: "acknowledgedRevision")' in decoder
    and 'value(forKey: "acknowledgedOperation")' in decoder
    and "acknowledgedRevision == revision" in decoder
    and "acknowledgedOperation == operation" in decoder,
    "Every outbox reader needs one exact receipt decoder.",
)
require(
    "acknowledgedRevision == nil" in decoder
    and "acknowledgedOperation == nil" in decoder
    and 'value(forKey: "acknowledged")' in decoder,
    "Model7 boolean ACKs may be trusted only when both Model8 receipt fields are nil.",
)

consumer = method_body(REMOTE, "func consumeLocalOutboxAcknowledgementResult")
require(
    "NSUpdatedObjectIDsKey" in consumer
    and "NSDeletedObjectIDsKey" not in consumer
    and "NSManagedObjectContext.mergeChanges" in consumer
    and "context.processPendingChanges()" in consumer
    and "performSynchronousRemoteViewContextMerge" not in consumer
    and "isApplyingRemoteChange" not in consumer,
    "Receipt-only merges must not suppress a pending genuine user edit on the view context.",
)
require(
    "currentRevision == acknowledgedAttempt.revision" in consumer
    and "currentOperation == acknowledgedAttempt.operation" in consumer
    and "removePendingRecordChanges" in consumer
    and "scheduleLocalOutboxDrain" in consumer,
    "A stale R1 receipt must not remove a record-name-identical R2 engine change.",
)


SWIFT_PROOF = r'''
import CoreData
import Foundation

func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = optional
    return attribute
}

func makeModel() -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    let outbox = NSEntityDescription()
    outbox.name = "Outbox"
    outbox.managedObjectClassName = "NSManagedObject"
    outbox.properties = [
        attribute("name", .stringAttributeType),
        attribute("revision", .stringAttributeType),
        attribute("operation", .stringAttributeType),
        attribute("acknowledgedRevision", .stringAttributeType, optional: true),
        attribute("acknowledgedOperation", .stringAttributeType, optional: true),
    ]
    outbox.uniquenessConstraints = [["name"]]
    let userData = NSEntityDescription()
    userData.name = "UserData"
    userData.managedObjectClassName = "NSManagedObject"
    userData.properties = [
        attribute("name", .stringAttributeType),
        attribute("value", .stringAttributeType),
    ]
    userData.uniquenessConstraints = [["name"]]
    model.entities = [outbox, userData]
    return model
}

struct Store {
    let workerCoordinator: NSPersistentStoreCoordinator
    let main: NSManagedObjectContext
}

func makeStore() throws -> Store {
    let model = makeModel()
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("outbox-ack-\(UUID().uuidString).sqlite")
    let options: [AnyHashable: Any] = [
        NSMigratePersistentStoresAutomaticallyOption: true,
        NSInferMappingModelAutomaticallyOption: true,
    ]
    let mainCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try mainCoordinator.addPersistentStore(
        ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options
    )
    let workerCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
    try workerCoordinator.addPersistentStore(
        ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: options
    )
    let main = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    main.persistentStoreCoordinator = mainCoordinator
    main.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    return Store(workerCoordinator: workerCoordinator, main: main)
}

func worker(_ store: Store) -> NSManagedObjectContext {
    let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    context.persistentStoreCoordinator = store.workerCoordinator
    context.mergePolicy = NSErrorMergePolicy
    return context
}

func row(_ context: NSManagedObjectContext) throws -> NSManagedObject {
    try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "Outbox")).first!
}

func seed(_ store: Store) throws -> NSManagedObject {
    let entry = NSEntityDescription.insertNewObject(forEntityName: "Outbox", into: store.main)
    entry.setValue("record", forKey: "name")
    entry.setValue("R1", forKey: "revision")
    entry.setValue("save", forKey: "operation")
    try store.main.save()
    return entry
}

func seedUserData(_ store: Store) throws -> NSManagedObject {
    let entry = NSEntityDescription.insertNewObject(forEntityName: "UserData", into: store.main)
    entry.setValue("user", forKey: "name")
    entry.setValue("before", forKey: "value")
    try store.main.save()
    return entry
}

final class CaptureState: @unchecked Sendable {
    var suppress = false
    var capturedUserEditCount = 0
}

// A receipt-only merge can share one ObjectsDidChange delivery with a genuine pending user edit.
// It must not use the remote-apply suppression flag, because the outbox entity itself is not
// user data and is ignored by local outbox capture.
do {
    let store = try makeStore()
    let outbox = try seed(store)
    let userData = try seedUserData(store)
    let capture = CaptureState()
    let token = NotificationCenter.default.addObserver(
        forName: .NSManagedObjectContextObjectsDidChange,
        object: store.main,
        queue: nil
    ) { notification in
        guard !capture.suppress,
              let updated = notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>,
              updated.contains(userData) else { return }
        capture.capturedUserEditCount += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    userData.setValue("local-edit", forKey: "value")
    let background = worker(store)
    try background.performAndWait {
        let persisted = try row(background)
        persisted.setValue("R1", forKey: "acknowledgedRevision")
        persisted.setValue("save", forKey: "acknowledgedOperation")
        try background.save()
    }
    NSManagedObjectContext.mergeChanges(
        fromRemoteContextSave: [NSUpdatedObjectIDsKey: [outbox.objectID]],
        into: [store.main]
    )
    store.main.processPendingChanges()
    precondition(capture.capturedUserEditCount == 1)
}

// R2 is dirty on the view context while the worker receipts persisted R1.
do {
    let store = try makeStore()
    let entry = try seed(store)
    entry.setValue("R2", forKey: "revision")
    entry.setValue("delete", forKey: "operation")
    store.main.processPendingChanges()
    let background = worker(store)
    try background.performAndWait {
        let persisted = try row(background)
        persisted.setValue("R1", forKey: "acknowledgedRevision")
        persisted.setValue("save", forKey: "acknowledgedOperation")
        try background.save()
    }
    NSManagedObjectContext.mergeChanges(
        fromRemoteContextSave: [NSUpdatedObjectIDsKey: [entry.objectID]],
        into: [store.main]
    )
    store.main.processPendingChanges()
    try store.main.save()
    let check = worker(store)
    try check.performAndWait {
        let persisted = try row(check)
        let revision = persisted.value(forKey: "revision") as? String
        let operation = persisted.value(forKey: "operation") as? String
        let receiptRevision = persisted.value(forKey: "acknowledgedRevision") as? String
        let receiptOperation = persisted.value(forKey: "acknowledgedOperation") as? String
        precondition(revision == "R2" && operation == "delete")
        precondition(receiptRevision == "R1" && receiptOperation == "save")
        precondition(!(revision == receiptRevision && operation == receiptOperation))
    }
}

// R2 commits after the worker's R1 read: ErrorMerge must reject the stale receipt.
do {
    let store = try makeStore()
    let entry = try seed(store)
    let background = worker(store)
    try background.performAndWait {
        let stale = try row(background)
        entry.setValue("R2", forKey: "revision")
        entry.setValue("delete", forKey: "operation")
        try store.main.save()
        stale.setValue("R1", forKey: "acknowledgedRevision")
        stale.setValue("save", forKey: "acknowledgedOperation")
        do {
            try background.save()
            preconditionFailure("A stale R1 receipt committed over R2")
        } catch {
            let persistenceError = error as NSError
            precondition(persistenceError.domain == NSCocoaErrorDomain)
            precondition(persistenceError.code == 133020)
            background.rollback()
        }
    }
    let retry = worker(store)
    try retry.performAndWait {
        let current = try row(retry)
        precondition(current.value(forKey: "revision") as? String == "R2")
        precondition(current.value(forKey: "acknowledgedRevision") == nil)
    }
}

print("exact outbox ACK receipt races passed")
'''


with tempfile.TemporaryDirectory(prefix="instacast-outbox-ack-") as temporary_directory:
    temporary = Path(temporary_directory)
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
        "exact outbox ACK receipt races passed" in proof_result.stdout,
        "The runtime ACK race proof did not complete.",
    )

print("iCloud outbox ACK responsiveness regression checks passed")
