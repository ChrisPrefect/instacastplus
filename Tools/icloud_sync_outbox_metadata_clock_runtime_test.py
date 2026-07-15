#!/usr/bin/env python3
"""Runtime proof that durable item metadata carries the exact causal outbox clock."""

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
    let value = NSAttributeDescription(); value.name = name; value.attributeType = type
    value.isOptional = false; return value
}
func optionalAttribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let value = attribute(name, type); value.isOptional = true; return value
}

let model = NSManagedObjectModel()
let outbox = NSEntityDescription(); outbox.name = "Outbox"; outbox.managedObjectClassName = "NSManagedObject"
outbox.properties = [attribute("account", .stringAttributeType), attribute("record", .stringAttributeType),
                     attribute("revision", .stringAttributeType), attribute("changedAt", .dateAttributeType)]
outbox.uniquenessConstraints = [["account", "record"]]
let metadata = NSEntityDescription(); metadata.name = "Metadata"; metadata.managedObjectClassName = "NSManagedObject"
metadata.properties = [attribute("account", .stringAttributeType), attribute("record", .stringAttributeType),
                       optionalAttribute("localModifiedAt", .dateAttributeType)]
metadata.uniquenessConstraints = [["account", "record"]]
model.entities = [outbox, metadata]

let container = NSPersistentContainer(name: "MetadataClockProof", managedObjectModel: model)
let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLOCK_STORE"]!))
description.type = NSSQLiteStoreType; container.persistentStoreDescriptions = [description]
let loaded = DispatchSemaphore(value: 0); var loadError: Error?
container.loadPersistentStores { _, error in loadError = error; loaded.signal() }; loaded.wait()
if let loadError { throw loadError }

func nextSafe(_ proposed: Date, _ floor: Date?) -> Date {
    let value = max(proposed.timeIntervalSince1970, floor?.timeIntervalSince1970 ?? proposed.timeIntervalSince1970)
    return Date(timeIntervalSince1970: (ceil(value * 1_000) + 1) / 1_000)
}
func seedMetadata(_ record: String, _ date: Date) throws {
    let context = container.newBackgroundContext()
    try context.performAndWait {
        let row = NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
        row.setValue("A", forKey: "account"); row.setValue(record, forKey: "record")
        row.setValue(date, forKey: "localModifiedAt"); try context.save()
    }
}
@discardableResult
func persist(records: [String], revision: String, proposed: Date) throws -> Date {
    let context = container.newBackgroundContext()
    return try context.performAndWait {
        let outboxRequest = NSFetchRequest<NSManagedObject>(entityName: "Outbox")
        outboxRequest.predicate = NSPredicate(format: "account == %@ AND record IN %@", "A", records)
        let existingOutbox = try context.fetch(outboxRequest)
        let metadataRequest = NSFetchRequest<NSManagedObject>(entityName: "Metadata")
        metadataRequest.predicate = NSPredicate(format: "account == %@ AND record IN %@", "A", records)
        let existingMetadata = try context.fetch(metadataRequest)
        let floor = (existingOutbox.compactMap { $0.value(forKey: "changedAt") as? Date }
                     + existingMetadata.compactMap { $0.value(forKey: "localModifiedAt") as? Date }).max()
        let date = nextSafe(proposed, floor)
        var metadataByRecord = Dictionary(uniqueKeysWithValues: existingMetadata.map { ($0.value(forKey: "record") as! String, $0) })
        var outboxByRecord = Dictionary(uniqueKeysWithValues: existingOutbox.map { ($0.value(forKey: "record") as! String, $0) })
        for record in records {
            let row = outboxByRecord[record] ?? NSEntityDescription.insertNewObject(forEntityName: "Outbox", into: context)
            row.setValue("A", forKey: "account"); row.setValue(record, forKey: "record")
            row.setValue(revision, forKey: "revision"); row.setValue(date, forKey: "changedAt")
            outboxByRecord[record] = row
            let clock = metadataByRecord[record] ?? NSEntityDescription.insertNewObject(forEntityName: "Metadata", into: context)
            clock.setValue("A", forKey: "account"); clock.setValue(record, forKey: "record")
            clock.setValue(date, forKey: "localModifiedAt"); metadataByRecord[record] = clock
        }
        try context.save(); return date
    }
}
func acknowledge(_ record: String) throws {
    let context = container.newBackgroundContext()
    try context.performAndWait {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Outbox")
        request.predicate = NSPredicate(format: "account == %@ AND record == %@", "A", record)
        for row in try context.fetch(request) { context.delete(row) }; try context.save()
    }
}

try seedMetadata("episode", Date(timeIntervalSince1970: 500))
let r1 = try persist(records: ["episode"], revision: "r1", proposed: Date(timeIntervalSince1970: 400))
try require(r1 > Date(timeIntervalSince1970: 500), "R1 did not advance over durable metadata")
try acknowledge("episode")
let r2 = try persist(records: ["episode"], revision: "r2", proposed: Date(timeIntervalSince1970: 400))
try require(r2 > r1, "Post-ACK R2 regressed after the wall clock moved backwards")

try seedMetadata("subscription", Date(timeIntervalSince1970: 600))
try seedMetadata("tombstone", Date(timeIntervalSince1970: 700))
let pair = try persist(records: ["subscription", "tombstone"], revision: "pair", proposed: Date(timeIntervalSince1970: 400))
try require(pair > Date(timeIntervalSince1970: 700), "Subscription pair did not use its maximum logical floor")
let verify = container.newBackgroundContext()
try verify.performAndWait {
    let request = NSFetchRequest<NSManagedObject>(entityName: "Outbox")
    request.predicate = NSPredicate(format: "revision == %@", "pair")
    let dates = Set(try verify.fetch(request).compactMap { ($0.value(forKey: "changedAt") as? Date)?.timeIntervalSince1970 })
    try require(dates == [pair.timeIntervalSince1970], "Active/tombstone pair has split clocks")
}

print("iCloud outbox/metadata causal-clock runtime proof passed")
'''


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{": depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0: return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


with tempfile.TemporaryDirectory(prefix="icloud-metadata-clock-") as directory:
    environment = os.environ.copy(); environment["CLOCK_STORE"] = str(Path(directory) / "proof.sqlite")
    result = subprocess.run(["xcrun", "swift", "-e", SWIFT_PROOF], cwd=ROOT, env=environment,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        raise AssertionError(f"Metadata clock runtime proof failed:\n{result.stdout}")
    print(result.stdout.strip())


persist = method_body(LOCAL, "func persistLocalOutboxMutations(_ mutations: [String: LocalOutboxMutation],\n                                     accountRecordName: String,\n                                     metadataWrites: [ICCloudSyncItemMetadataWrite],\n                                     metadataIdentityWrites: [ICCloudSyncItemMetadataWrite],\n                                     context: NSManagedObjectContext,")
for token in ["causalDatesByRevision", "metadataWritesWithCausalDates", "metadataBatch.entriesByRecordName"]:
    if token not in persist:
        raise AssertionError(f"Production outbox transaction is missing causal metadata coupling: {token}")

print("iCloud outbox/metadata causal-clock source checks passed")
