#!/usr/bin/env python3
"""Runtime-proves the nil-safe unresolved outbox predicate used by the drain."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


require("unresolvedOnly: true" in LOCAL,
        "The normal drain must not materialize thousands of already acknowledged rows.")
require("missingSubscriptionPairRecordNames" in LOCAL,
        "A partially acknowledged subscription must reload its inverse physical row.")
require("localOutboxEntryIsAcknowledged(entry)" in LOCAL,
        "Fetched snapshots must use the same exact/legacy ACK decoder as the predicate.")


SWIFT_PROOF = r'''
import CoreData
import Foundation

func attribute(
    _ name: String,
    _ type: NSAttributeType,
    optional: Bool = false,
    defaultValue: Any? = nil
) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = optional
    attribute.defaultValue = defaultValue
    return attribute
}

let model = NSManagedObjectModel()
let entity = NSEntityDescription()
entity.name = "Outbox"
entity.managedObjectClassName = "NSManagedObject"
entity.properties = [
    attribute("recordName", .stringAttributeType),
    attribute("revision", .stringAttributeType),
    attribute("operation", .stringAttributeType),
    attribute("acknowledged", .booleanAttributeType, defaultValue: false),
    attribute("acknowledgedRevision", .stringAttributeType, optional: true),
    attribute("acknowledgedOperation", .stringAttributeType, optional: true),
]
model.entities = [entity]

let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("outbox-filter-\(UUID().uuidString).sqlite")
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(
    ofType: NSSQLiteStoreType,
    configurationName: nil,
    at: url,
    options: nil
)
let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

func insert(
    _ name: String,
    revision: String,
    operation: String = "save",
    legacy: Bool = false,
    receiptRevision: String? = nil,
    receiptOperation: String? = nil
) {
    let entry = NSEntityDescription.insertNewObject(forEntityName: "Outbox", into: context)
    entry.setValue(name, forKey: "recordName")
    entry.setValue(revision, forKey: "revision")
    entry.setValue(operation, forKey: "operation")
    entry.setValue(legacy, forKey: "acknowledged")
    entry.setValue(receiptRevision, forKey: "acknowledgedRevision")
    entry.setValue(receiptOperation, forKey: "acknowledgedOperation")
}

insert("legacy-ack", revision: "r1", legacy: true)
insert("exact-ack", revision: "r1", receiptRevision: "r1", receiptOperation: "save")
insert("pending", revision: "r1")
insert("newer-r2", revision: "r2", receiptRevision: "r1", receiptOperation: "save")
insert("partial-receipt", revision: "r1", legacy: true, receiptRevision: "r1")
try context.save()
context.reset()

let pendingLegacyEntry = NSCompoundPredicate(andPredicateWithSubpredicates: [
    NSPredicate(format: "acknowledgedRevision == nil"),
    NSPredicate(format: "acknowledgedOperation == nil"),
    NSPredicate(format: "acknowledged == NO"),
])
let hasAnyReceiptField = NSCompoundPredicate(orPredicateWithSubpredicates: [
    NSPredicate(format: "acknowledgedRevision != nil"),
    NSPredicate(format: "acknowledgedOperation != nil"),
])
let receiptIsIncompleteOrStale = NSCompoundPredicate(orPredicateWithSubpredicates: [
    NSPredicate(format: "acknowledgedRevision == nil"),
    NSPredicate(format: "acknowledgedOperation == nil"),
    NSPredicate(format: "acknowledgedRevision != revision"),
    NSPredicate(format: "acknowledgedOperation != operation"),
])
let unresolved = NSCompoundPredicate(orPredicateWithSubpredicates: [
    pendingLegacyEntry,
    NSCompoundPredicate(andPredicateWithSubpredicates: [
        hasAnyReceiptField,
        receiptIsIncompleteOrStale,
    ]),
])
let request = NSFetchRequest<NSManagedObject>(entityName: "Outbox")
request.predicate = unresolved
let names = Set(try context.fetch(request).compactMap {
    $0.value(forKey: "recordName") as? String
})
precondition(names == ["pending", "newer-r2", "partial-receipt"], "Unexpected unresolved rows: \(names)")

print("nil-safe outbox drain filter passed")
'''


with tempfile.TemporaryDirectory(prefix="instacast-outbox-filter-") as temporary_directory:
    temporary = Path(temporary_directory)
    source = temporary / "proof.swift"
    executable = temporary / "proof"
    source.write_text(SWIFT_PROOF)
    compiled = subprocess.run(
        ["xcrun", "swiftc", str(source), "-o", str(executable)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    require(compiled.returncode == 0, compiled.stdout)
    proof = subprocess.run(
        [str(executable)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    require(proof.returncode == 0, proof.stdout)
    require("nil-safe outbox drain filter passed" in proof.stdout, proof.stdout)

print("iCloud outbox ACK drain filter runtime checks passed")
