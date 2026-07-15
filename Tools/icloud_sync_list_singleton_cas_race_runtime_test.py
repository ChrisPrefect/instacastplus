#!/usr/bin/env python3
"""Proves list-singleton reconciliation cannot overwrite a newer Core Data edit."""

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


SWIFT_PROOF = r'''
import CoreData
import Foundation

struct ProofFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProofFailure(description: message) }
}

func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let attribute = NSAttributeDescription()
    attribute.name = name
    attribute.attributeType = type
    attribute.isOptional = false
    return attribute
}

let model = NSManagedObjectModel()
let entity = NSEntityDescription()
entity.name = "ICCloudSyncOutboxEntry"
entity.managedObjectClassName = "NSManagedObject"
entity.properties = [
    attribute("accountRecordName", .stringAttributeType),
    attribute("recordName", .stringAttributeType),
    attribute("revision", .stringAttributeType),
    attribute("changedAt", .dateAttributeType),
    attribute("payloadData", .binaryDataAttributeType),
]
entity.uniquenessConstraints = [["accountRecordName", "recordName"]]
model.entities = [entity]

guard let storePath = ProcessInfo.processInfo.environment["LIST_CAS_STORE"] else {
    fatalError("LIST_CAS_STORE missing")
}
let container = NSPersistentContainer(name: "ListCASProof", managedObjectModel: model)
let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: storePath))
description.type = NSSQLiteStoreType
container.persistentStoreDescriptions = [description]
let loaded = DispatchSemaphore(value: 0)
var loadError: Error?
container.loadPersistentStores { _, error in loadError = error; loaded.signal() }
loaded.wait()
if let loadError { throw loadError }

let account = "account"
let record = "settings_subscriptionList"
let r2Date = Date(timeIntervalSince1970: 500)
let r3Date = Date(timeIntervalSince1970: 501)
let r4Date = Date(timeIntervalSince1970: 502)
let marker = Data("dirty-marker".utf8)
let r2Payload = Data("full-r2-payload".utf8)
let r3Payload = Data("full-r3-payload".utf8)
let r4Payload = Data("full-r4-payload".utf8)

func fetch(_ context: NSManagedObjectContext) throws -> NSManagedObject {
    let request = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
    request.predicate = NSPredicate(
        format: "accountRecordName == %@ AND recordName == %@", account, record
    )
    request.fetchLimit = 1
    guard let row = try context.fetch(request).first else {
        throw ProofFailure(description: "Missing outbox row")
    }
    return row
}

func seed(revision: String, changedAt: Date, payload: Data) throws {
    let context = container.newBackgroundContext()
    context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    try context.performAndWait {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
        for row in try context.fetch(request) { context.delete(row) }
        let row = NSEntityDescription.insertNewObject(
            forEntityName: "ICCloudSyncOutboxEntry", into: context
        )
        row.setValue(account, forKey: "accountRecordName")
        row.setValue(record, forKey: "recordName")
        row.setValue(revision, forKey: "revision")
        row.setValue(changedAt, forKey: "changedAt")
        row.setValue(payload, forKey: "payloadData")
        try context.save()
    }
}

func commit(revision: String, changedAt: Date, payload: Data) throws {
    let context = container.newBackgroundContext()
    context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
    try context.performAndWait {
        let row = try fetch(context)
        row.setValue(revision, forKey: "revision")
        row.setValue(changedAt, forKey: "changedAt")
        row.setValue(payload, forKey: "payloadData")
        try context.save()
    }
}

func freshValues() throws -> (String, Date, Data) {
    let context = container.newBackgroundContext()
    return try context.performAndWait {
        let row = try fetch(context)
        return (
            row.value(forKey: "revision") as! String,
            row.value(forKey: "changedAt") as! Date,
            row.value(forKey: "payloadData") as! Data
        )
    }
}

// Race 1: aligner fetched R2. A new local edit commits R4 before the aligner tries
// to replace R2 with singleton R3. ErrorMergePolicy is the required compare-and-swap:
// it must reject the stale save instead of rolling the row back to R3.
try seed(revision: "r2", changedAt: r2Date, payload: r2Payload)
let staleAlign = container.newBackgroundContext()
staleAlign.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
let staleAlignRow = try staleAlign.performAndWait { try fetch(staleAlign) }
staleAlign.performAndWait {
    staleAlignRow.setValue("r3", forKey: "revision")
    staleAlignRow.setValue(r3Date, forKey: "changedAt")
    staleAlignRow.setValue(r3Payload, forKey: "payloadData")
}
try commit(revision: "r4", changedAt: r4Date, payload: r4Payload)
var alignmentRejected = false
do {
    try staleAlign.performAndWait {
        try staleAlign.save()
    }
} catch {
    alignmentRejected = true
    staleAlign.rollback()
}
try require(alignmentRejected, "The stale R2→R3 alignment was not rejected")
var values = try freshValues()
try require(values.0 == "r4" && values.1 == r4Date && values.2 == r4Payload,
            "Stale alignment overwrote the newer R4 edit")

// Race 2: dirty-marker expansion fetched R2. R4 then commits the same marker.
// The old expansion payload must not become a full R2 payload paired with R4's
// revision/date, because that silently uploads stale list contents as R4.
try seed(revision: "r2", changedAt: r2Date, payload: marker)
let staleExpansion = container.newBackgroundContext()
staleExpansion.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
let staleExpansionRow = try staleExpansion.performAndWait { try fetch(staleExpansion) }
staleExpansion.performAndWait {
    staleExpansionRow.setValue(r2Payload, forKey: "payloadData")
}
try commit(revision: "r4", changedAt: r4Date, payload: marker)
var expansionRejected = false
do {
    try staleExpansion.performAndWait {
        try staleExpansion.save()
    }
} catch {
    expansionRejected = true
    staleExpansion.rollback()
}
try require(expansionRejected, "The stale R2 dirty-marker expansion was not rejected")
values = try freshValues()
try require(values.0 == "r4" && values.1 == r4Date && values.2 == marker,
            "R4 was paired with the stale full R2 payload")

print("iCloud list singleton CAS Core Data runtime proof passed")
'''


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
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


with tempfile.TemporaryDirectory(prefix="icloud-list-cas-") as directory:
    environment = os.environ.copy()
    environment["LIST_CAS_STORE"] = str(Path(directory) / "proof.sqlite")
    result = subprocess.run(
        ["xcrun", "swift", "-e", SWIFT_PROOF],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise AssertionError(f"Core Data list-CAS proof failed:\n{result.stdout}")
    print(result.stdout.strip())


align = method_body(LOCAL, "func alignCommittedSubscriptionListSettingsOutboxEntry")
expand = method_body(LOCAL, "nonisolated static func replaceSubscriptionListSettingsDirtyMarker")
for name, body in [("intent alignment", align), ("dirty-marker expansion", expand)]:
    if ".errorMergePolicyType" not in body and "NSBatchUpdateRequest" not in body:
        raise AssertionError(
            f"Production {name} still inherits ObjectTrump instead of performing a compare-and-swap."
        )

print("iCloud list singleton CAS source checks passed")
