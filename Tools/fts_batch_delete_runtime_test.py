#!/usr/bin/env python3
"""Runtime-proves that Core Data batch deletes bypass save notifications used by FTS."""

from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()

reset = DATABASE.split("- (void)resetAllUserDataWithCompletion:", 1)[1].split("\n\n- (", 1)[0]
if reset.find("prepareForExternalStoreMutation:") > reset.find("NSBatchDeleteRequest"):
    raise AssertionError("FTS must be marked dirty before the batch delete starts")
if reset.find("rebuildIndexWithManagedObjectContext") < reset.find("executeRequest:deleteRequest"):
    raise AssertionError("FTS must rebuild from the post-delete store")

swift_proof = r'''
import CoreData
import Foundation

struct ProofFailure: Error, CustomStringConvertible {
    let description: String
}

final class SaveObserver: NSObject {
    var willSaveCount = 0
    var didSaveCount = 0

    @objc func willSave(_ notification: Notification) { willSaveCount += 1 }
    @objc func didSave(_ notification: Notification) { didSaveCount += 1 }
}

let entity = NSEntityDescription()
entity.name = "Episode"
entity.managedObjectClassName = "NSManagedObject"
let identifier = NSAttributeDescription()
identifier.name = "identifier"
identifier.attributeType = .stringAttributeType
identifier.isOptional = false
entity.properties = [identifier]

let model = NSManagedObjectModel()
model.entities = [entity]
let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("instacast-fts-batch-delete-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let storeURL = directory.appendingPathComponent("DataStore.sqlite")
_ = try coordinator.addPersistentStore(type: .sqlite, at: storeURL)

let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator
for index in 0..<3 {
    let object = NSManagedObject(entity: entity, insertInto: context)
    object.setValue("episode-\(index)", forKey: "identifier")
}
try context.save()

let observer = SaveObserver()
NotificationCenter.default.addObserver(observer,
                                       selector: #selector(SaveObserver.willSave(_:)),
                                       name: .NSManagedObjectContextWillSave,
                                       object: nil)
NotificationCenter.default.addObserver(observer,
                                       selector: #selector(SaveObserver.didSave(_:)),
                                       name: .NSManagedObjectContextDidSave,
                                       object: nil)
defer { NotificationCenter.default.removeObserver(observer) }

let batchContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
batchContext.persistentStoreCoordinator = coordinator
try batchContext.performAndWait {
    let fetch = NSFetchRequest<NSFetchRequestResult>(entityName: "Episode")
    let request = NSBatchDeleteRequest(fetchRequest: fetch)
    _ = try batchContext.execute(request)
}

let verificationContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
verificationContext.persistentStoreCoordinator = coordinator
let remaining = try verificationContext.performAndWait {
    try verificationContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Episode"))
}
guard remaining == 0 else {
    throw ProofFailure(description: "Batch delete left \(remaining) rows")
}
guard observer.willSaveCount == 0 && observer.didSaveCount == 0 else {
    throw ProofFailure(description: "Batch delete unexpectedly emitted save notifications")
}
print("Core Data batch-delete FTS notification-bypass runtime proof passed")
'''

result = subprocess.run(
    ["xcrun", "swift", "-e", swift_proof],
    cwd=ROOT,
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
)
if result.returncode != 0:
    raise AssertionError(result.stdout)
print(result.stdout.strip())
