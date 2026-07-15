#!/usr/bin/env python3
"""Core Data runtime proof for lightweight EpisodeList outbox journaling."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

SWIFT_PROOF = r'''
import CoreData
import Foundation

struct ProofFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProofFailure(description: message) }
}

func attribute(_ name: String, _ type: NSAttributeType, optional: Bool = false) -> NSAttributeDescription {
    let value = NSAttributeDescription()
    value.name = name
    value.attributeType = type
    value.isOptional = optional
    return value
}

let model = NSManagedObjectModel()
let feed = NSEntityDescription()
feed.name = "Feed"
feed.managedObjectClassName = "NSManagedObject"
feed.properties = [attribute("uid", .stringAttributeType)]

let list = NSEntityDescription()
list.name = "EpisodeList"
list.managedObjectClassName = "NSManagedObject"
let listUID = attribute("uid", .stringAttributeType)
let listName = attribute("name", .stringAttributeType)
let includedFeeds = NSRelationshipDescription()
includedFeeds.name = "includedFeeds"
includedFeeds.destinationEntity = feed
includedFeeds.minCount = 0
includedFeeds.maxCount = 0
includedFeeds.deleteRule = .nullifyDeleteRule
includedFeeds.isOptional = true
includedFeeds.isOrdered = false
list.properties = [listUID, listName, includedFeeds]

let outbox = NSEntityDescription()
outbox.name = "ICCloudSyncOutboxEntry"
outbox.managedObjectClassName = "NSManagedObject"
outbox.properties = [
    attribute("accountRecordName", .stringAttributeType),
    attribute("recordName", .stringAttributeType),
    attribute("category", .stringAttributeType),
    attribute("operation", .stringAttributeType),
    attribute("acknowledged", .booleanAttributeType),
    attribute("revision", .stringAttributeType),
    attribute("changedAt", .dateAttributeType),
    attribute("payloadData", .binaryDataAttributeType),
]
model.entities = [feed, list, outbox]

guard let storePath = ProcessInfo.processInfo.environment["OUTBOX_RUNTIME_STORE"] else {
    fatalError("OUTBOX_RUNTIME_STORE missing")
}
let container = NSPersistentContainer(name: "EpisodeListOutboxProof", managedObjectModel: model)
let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: storePath))
description.type = NSSQLiteStoreType
container.persistentStoreDescriptions = [description]
let semaphore = DispatchSemaphore(value: 0)
var loadError: Error?
container.loadPersistentStores { _, error in loadError = error; semaphore.signal() }
semaphore.wait()
if let loadError { throw loadError }

let context = container.viewContext
var captureEnabled = false
var nextRevision = ""
var proposedDate = Date(timeIntervalSince1970: 0)
var lastHandlerSeconds = 0.0
let markerData = try PropertyListSerialization.data(
    fromPropertyList: ["requiresCommittedSnapshot": true],
    format: .binary,
    options: 0
)
let observer = NotificationCenter.default.addObserver(
    forName: .NSManagedObjectContextObjectsDidChange,
    object: context,
    queue: nil
) { notification in
    guard captureEnabled else { return }
    let changed = ((notification.userInfo?[NSUpdatedObjectsKey] as? Set<NSManagedObject>) ?? [])
        .contains { $0.entity.name == "EpisodeList" }
    guard changed else { return }
    let started = CFAbsoluteTimeGetCurrent()
    let request = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
    request.predicate = NSPredicate(format: "accountRecordName == %@ AND recordName == %@", "scope", "settings_subscriptionList")
    request.fetchLimit = 1
    let row = (try? context.fetch(request).first)
        ?? NSEntityDescription.insertNewObject(forEntityName: "ICCloudSyncOutboxEntry", into: context)
    let prior = row.value(forKey: "changedAt") as? Date
    let causalDate = prior.map { proposedDate > $0 ? proposedDate : $0.addingTimeInterval(0.000_001) } ?? proposedDate
    row.setValue("scope", forKey: "accountRecordName")
    row.setValue("settings_subscriptionList", forKey: "recordName")
    row.setValue("subscriptionListSettings", forKey: "category")
    row.setValue("save", forKey: "operation")
    row.setValue(false, forKey: "acknowledged")
    row.setValue(nextRevision, forKey: "revision")
    row.setValue(causalDate, forKey: "changedAt")
    row.setValue(markerData, forKey: "payloadData")
    lastHandlerSeconds = CFAbsoluteTimeGetCurrent() - started
}
defer { NotificationCenter.default.removeObserver(observer) }

let episodeList = NSManagedObject(entity: list, insertInto: context)
episodeList.setValue("list", forKey: "uid")
episodeList.setValue("Initial", forKey: "name")
var feedObjects: [NSManagedObject] = []
feedObjects.reserveCapacity(1_000)
for index in 0..<1_000 {
    let object = NSManagedObject(entity: feed, insertInto: context)
    object.setValue("feed-\(index)", forKey: "uid")
    feedObjects.append(object)
}
episodeList.setValue(Set(feedObjects), forKey: "includedFeeds")
try context.save()

// Rollback proof: marker and list mutation live in the same context transaction.
captureEnabled = true
nextRevision = "rollback"
proposedDate = Date(timeIntervalSince1970: 300)
episodeList.setValue("Rolled back", forKey: "name")
context.processPendingChanges()
let pendingRequest = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
let pendingCount = try context.count(for: pendingRequest)
try require(pendingCount == 1, "ObjectsDidChange did not journal the marker")
context.rollback()
let rolledBackCount = try context.count(for: pendingRequest)
try require(rolledBackCount == 0, "Rollback left a committed outbox row")

func fetchedList() throws -> NSManagedObject {
    let request = NSFetchRequest<NSManagedObject>(entityName: "EpisodeList")
    request.fetchLimit = 1
    guard let value = try context.fetch(request).first else { throw ProofFailure(description: "EpisodeList missing") }
    return value
}

// Commit R1. The handler must remain bounded despite the 1000-feed relationship graph.
nextRevision = "r1"
proposedDate = Date(timeIntervalSince1970: 500)
try fetchedList().setValue("R1", forKey: "name")
context.processPendingChanges()
try require(lastHandlerSeconds < 0.100, "Main-context marker handler exceeded 100 ms: \(lastHandlerSeconds)s")
try context.save()
context.reset() // kill/relaunch boundary: only the committed row remains.

let coldContext = container.newBackgroundContext()
let coldRows = try coldContext.performAndWait { try coldContext.fetch(pendingRequest) }
try require(coldRows.count == 1 && coldRows[0].value(forKey: "revision") as? String == "r1",
            "Committed marker did not survive kill-before-drain")

// Commit causal R2 with the wall clock moved backwards.
nextRevision = "r2"
proposedDate = Date(timeIntervalSince1970: 400)
try fetchedList().setValue("R2", forKey: "name")
context.processPendingChanges()
try context.save()

func conditionalExpand(expectedRevision: String) throws -> Bool {
    let background = container.newBackgroundContext()
    return try background.performAndWait {
        let rows = try background.fetch(pendingRequest)
        guard let row = rows.first,
              row.value(forKey: "revision") as? String == expectedRevision else { return false }
        let listRequest = NSFetchRequest<NSManagedObject>(entityName: "EpisodeList")
        listRequest.relationshipKeyPathsForPrefetching = ["includedFeeds"]
        guard let committedList = try background.fetch(listRequest).first else { return false }
        let count = (committedList.value(forKey: "includedFeeds") as? Set<NSManagedObject>)?.count ?? -1
        let payload = try PropertyListSerialization.data(
            fromPropertyList: ["name": committedList.value(forKey: "name") as? String ?? "", "includedFeedCount": count],
            format: .binary,
            options: 0
        )
        row.setValue(payload, forKey: "payloadData")
        try background.save()
        return true
    }
}

let staleExpansionSucceeded = try conditionalExpand(expectedRevision: "r1")
try require(!staleExpansionSucceeded, "Late R1 expansion overwrote committed R2")
let exactExpansionSucceeded = try conditionalExpand(expectedRevision: "r2")
try require(exactExpansionSucceeded, "Exact R2 marker did not expand")
let finalContext = container.newBackgroundContext()
let finalRow = try finalContext.performAndWait { try finalContext.fetch(pendingRequest).first! }
let finalDate = finalRow.value(forKey: "changedAt") as! Date
let finalPayloadData = finalRow.value(forKey: "payloadData") as! Data
let finalPayload = try PropertyListSerialization.propertyList(from: finalPayloadData, format: nil) as! [String: Any]
try require(finalDate > Date(timeIntervalSince1970: 500), "Clock rollback broke causal outbox order")
try require(finalRow.value(forKey: "revision") as? String == "r2"
            && finalPayload["name"] as? String == "R2"
            && finalPayload["includedFeedCount"] as? Int == 1_000,
            "Expanded payload was not the exact committed R2 state")

print("iCloud EpisodeList Core Data transaction/runtime proof passed (handler \(lastHandlerSeconds)s)")
'''


def run(command: list[str], environment: dict[str, str]) -> None:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"Command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}"
        )
    print(result.stdout.strip())


with tempfile.TemporaryDirectory(prefix="instacast-list-outbox-runtime-") as temporary:
    environment = os.environ.copy()
    environment["OUTBOX_RUNTIME_STORE"] = str(Path(temporary) / "outbox.sqlite")
    run(["xcrun", "swift", "-e", SWIFT_PROOF], environment)
