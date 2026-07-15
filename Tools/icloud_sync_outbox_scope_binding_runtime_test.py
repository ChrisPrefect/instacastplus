#!/usr/bin/env python3
"""Core Data proof for account-isolated clocks and bind/save interleavings."""

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
    let value = NSAttributeDescription()
    value.name = name
    value.attributeType = type
    value.isOptional = false
    return value
}

let model = NSManagedObjectModel()
let outbox = NSEntityDescription()
outbox.name = "ICCloudSyncOutboxEntry"
outbox.managedObjectClassName = "NSManagedObject"
outbox.properties = [
    attribute("accountRecordName", .stringAttributeType),
    attribute("recordName", .stringAttributeType),
    attribute("revision", .stringAttributeType),
    attribute("changedAt", .dateAttributeType),
]
outbox.uniquenessConstraints = [["accountRecordName", "recordName"]]
model.entities = [outbox]

guard let storePath = ProcessInfo.processInfo.environment["OUTBOX_SCOPE_STORE"] else {
    fatalError("OUTBOX_SCOPE_STORE missing")
}
let storeURL = URL(fileURLWithPath: storePath)

func openContainer() throws -> NSPersistentContainer {
    let container = NSPersistentContainer(name: "OutboxScopeProof", managedObjectModel: model)
    let description = NSPersistentStoreDescription(url: storeURL)
    description.type = NSSQLiteStoreType
    container.persistentStoreDescriptions = [description]
    let semaphore = DispatchSemaphore(value: 0)
    var loadError: Error?
    container.loadPersistentStores { _, error in loadError = error; semaphore.signal() }
    semaphore.wait()
    if let loadError { throw loadError }
    return container
}

func closeContainer(_ container: NSPersistentContainer) throws {
    for store in container.persistentStoreCoordinator.persistentStores {
        try container.persistentStoreCoordinator.remove(store)
    }
}

func nextSafeDate(_ proposed: Date, after floor: Date?) -> Date {
    let maximum = max(proposed.timeIntervalSince1970,
                      floor?.timeIntervalSince1970 ?? proposed.timeIntervalSince1970)
    return Date(timeIntervalSince1970: (ceil(maximum * 1_000.0) + 1.0) / 1_000.0)
}

func seed(_ container: NSPersistentContainer, scope: String, revision: String, changedAt: Date) throws {
    let context = container.newBackgroundContext()
    try context.performAndWait {
        let row = NSEntityDescription.insertNewObject(forEntityName: "ICCloudSyncOutboxEntry", into: context)
        row.setValue(scope, forKey: "accountRecordName")
        row.setValue("settings_subscriptionList", forKey: "recordName")
        row.setValue(revision, forKey: "revision")
        row.setValue(changedAt, forKey: "changedAt")
        try context.save()
    }
}

@discardableResult
func persistCausal(_ container: NSPersistentContainer,
                   scope: String,
                   causalScopes: Set<String>,
                   revision: String,
                   proposed: Date) throws -> Date {
    let context = container.newBackgroundContext()
    context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    return try context.performAndWait {
        let allRequest = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
        allRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "accountRecordName IN %@", Array(causalScopes)),
            NSPredicate(format: "recordName == %@", "settings_subscriptionList"),
        ])
        let allRows = try context.fetch(allRequest)
        let floor = allRows.compactMap { $0.value(forKey: "changedAt") as? Date }.max()
        let changedAt = nextSafeDate(proposed, after: floor)
        let current = allRows.first { $0.value(forKey: "accountRecordName") as? String == scope }
            ?? NSEntityDescription.insertNewObject(forEntityName: "ICCloudSyncOutboxEntry", into: context)
        current.setValue(scope, forKey: "accountRecordName")
        current.setValue("settings_subscriptionList", forKey: "recordName")
        current.setValue(revision, forKey: "revision")
        current.setValue(changedAt, forKey: "changedAt")
        try context.save()
        return changedAt
    }
}

func bind(_ container: NSPersistentContainer,
          sourceScope: String,
          destinationScope: String,
          didPrepareFirstSave: (() -> Void)? = nil,
          continueFirstSave: DispatchSemaphore? = nil) throws {
    let context = container.newBackgroundContext()
    context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
    try context.performAndWait {
        var isFirstChunk = true
        while true {
            let sourceRequest = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
            sourceRequest.predicate = NSPredicate(format: "accountRecordName == %@", sourceScope)
            let sourceRows = try context.fetch(sourceRequest)
            guard !sourceRows.isEmpty else { break }
            let recordNames = sourceRows.compactMap { $0.value(forKey: "recordName") as? String }
            let destinationRequest = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
            destinationRequest.predicate = NSPredicate(
                format: "accountRecordName == %@ AND recordName IN %@",
                destinationScope,
                recordNames
            )
            let destinationRows = try context.fetch(destinationRequest)
            var destinations = Dictionary(uniqueKeysWithValues: destinationRows.compactMap { row in
                (row.value(forKey: "recordName") as? String).map { ($0, row) }
            })
            for source in sourceRows {
                guard let recordName = source.value(forKey: "recordName") as? String else { continue }
                if let destination = destinations[recordName] {
                    let destinationDate = destination.value(forKey: "changedAt") as? Date ?? .distantPast
                    let sourceDate = source.value(forKey: "changedAt") as? Date ?? .distantPast
                    // A pending/unbound source mutation happened logically after the
                    // destination state. Re-clock it only against this destination account.
                    // Preserve destination identity so StoreTrump protects a concurrent R3.
                    destination.setValue(source.value(forKey: "revision"), forKey: "revision")
                    destination.setValue(nextSafeDate(sourceDate, after: destinationDate),
                                         forKey: "changedAt")
                    context.delete(source)
                } else {
                    source.setValue(destinationScope, forKey: "accountRecordName")
                    destinations[recordName] = source
                }
            }
            if isFirstChunk {
                isFirstChunk = false
                didPrepareFirstSave?()
                continueFirstSave?.wait()
            }
            if context.hasChanges { try context.save() }
            context.reset()
        }
    }
}

func rows(_ container: NSPersistentContainer) throws -> [(scope: String, revision: String, changedAt: Date)] {
    let context = container.newBackgroundContext()
    return try context.performAndWait {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
        return try context.fetch(request).map {
            ($0.value(forKey: "accountRecordName") as! String,
             $0.value(forKey: "revision") as! String,
             $0.value(forKey: "changedAt") as! Date)
        }
    }
}

func clearRows(_ container: NSPersistentContainer) throws {
    let context = container.newBackgroundContext()
    try context.performAndWait {
        let request = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
        for row in try context.fetch(request) { context.delete(row) }
        try context.save()
    }
}

// Interleaving 1: A has a far-future clock, while pending R2 will bind to B. A must not
// stamp the pending mutation; the bind itself re-clocks R2 above B/R1. Reopen first to
// prove the boundary is kill-safe.
var container = try openContainer()
try seed(container, scope: "A", revision: "a-future", changedAt: Date(timeIntervalSince1970: 900))
try seed(container, scope: "B", revision: "r1", changedAt: Date(timeIntervalSince1970: 500))
let r2Date = try persistCausal(
    container,
    scope: "pending",
    causalScopes: ["pending"],
    revision: "r2",
    proposed: Date(timeIntervalSince1970: 400)
)
try require(r2Date < Date(timeIntervalSince1970: 500), "Foreign account A or destination B poisoned pending R2")
try closeContainer(container)
container = try openContainer()
try bind(container, sourceScope: "pending", destinationScope: "B")
let rebound = try rows(container)
let reboundB = rebound.first { $0.scope == "B" }
try require(reboundB?.revision == "r2"
                && reboundB!.changedAt > Date(timeIntervalSince1970: 500)
                && reboundB!.changedAt < Date(timeIntervalSince1970: 900),
            "Kill-safe bind discarded the causally newer pending R2")

// Interleaving 2: binder fetched source R2 and destination R1. Before its save, a local
// destination R3 commits. StoreTrump must preserve R3; a following fresh bind pass removes R2.
try clearRows(container)
try seed(container, scope: "B", revision: "r1", changedAt: Date(timeIntervalSince1970: 500))
try seed(container, scope: "pending", revision: "r2", changedAt: Date(timeIntervalSince1970: 500.001))
let prepared = DispatchSemaphore(value: 0)
let continueSave = DispatchSemaphore(value: 0)
let finished = DispatchSemaphore(value: 0)
let errorLock = NSLock()
var bindError: Error?
DispatchQueue.global(qos: .userInitiated).async {
    do {
        try bind(
            container,
            sourceScope: "pending",
            destinationScope: "B",
            didPrepareFirstSave: { prepared.signal() },
            continueFirstSave: continueSave
        )
    } catch {
        errorLock.lock(); bindError = error; errorLock.unlock()
    }
    finished.signal()
}
try require(prepared.wait(timeout: .now() + 5) == .success, "Binder did not reach pre-save interleaving")
let r3Date = try persistCausal(
    container,
    scope: "B",
    causalScopes: ["B", "pending"],
    revision: "r3",
    proposed: Date(timeIntervalSince1970: 400)
)
try require(r3Date > Date(timeIntervalSince1970: 500.001), "Destination R3 did not advance over active pending R2")
continueSave.signal()
try require(finished.wait(timeout: .now() + 5) == .success, "Binder did not terminate after StoreTrump conflict")
errorLock.lock(); let capturedError = bindError; errorLock.unlock()
if let capturedError { throw capturedError }
let raced = try rows(container)
let racedDescription = raced.map {
    "\($0.scope)/\($0.revision)/\($0.changedAt.timeIntervalSince1970)"
}
try require(raced.count == 1 && raced[0].scope == "B" && raced[0].revision == "r3",
            "Stale binder overwrote or duplicated destination R3: \(racedDescription)")

print("iCloud outbox scope-binding Core Data runtime proof passed")
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


with tempfile.TemporaryDirectory(prefix="icloud-outbox-scope-") as directory:
    environment = os.environ.copy()
    environment["OUTBOX_SCOPE_STORE"] = str(Path(directory) / "proof.sqlite")
    result = subprocess.run(
        ["xcrun", "swift", "-e", SWIFT_PROOF],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise AssertionError(f"Core Data scope-binding proof failed:\n{result.stdout}")
    print(result.stdout.strip())


persist = method_body(
    LOCAL,
    "func persistLocalOutboxMutations(_ mutations: [String: LocalOutboxMutation],\n                                     accountRecordName: String,\n                                     metadataWrites: [ICCloudSyncItemMetadataWrite],\n                                     metadataIdentityWrites: [ICCloudSyncItemMetadataWrite],\n                                     context: NSManagedObjectContext,",
)
if ("causalLocalOutboxScopes" not in persist
        or "accountRecordName IN" not in persist
        or "highestCommittedOutboxDateByRecordName" not in persist
        or "nextCloudKitSafeDate" not in persist):
    raise AssertionError(
        "Production outbox writes do not isolate their causal floors to the destination lineage."
    )
bind = method_body(LOCAL, "func bindLocalOutboxEntries")
if ("NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)" not in bind
        or "nextCloudKitSafeDate" not in bind
        or "currentDate.compare(sourceDate)" in bind):
    raise AssertionError(
        "Production scope binding does not re-clock the logical source while protecting concurrent R3."
    )

print("iCloud outbox scope-binding source checks passed")
