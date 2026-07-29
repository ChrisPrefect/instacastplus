#!/usr/bin/env python3
"""Runtime-proves Model7→Model8 outbox receipt migration and legacy decoding."""

from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIRECTORY = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"
MODEL7 = MODEL_DIRECTORY / "Model7.xcdatamodel"
MODEL8 = MODEL_DIRECTORY / "Model8.xcdatamodel"
MODEL9 = MODEL_DIRECTORY / "Model9.xcdatamodel"
CURRENT_VERSION = MODEL_DIRECTORY / ".xccurrentversion"
PROJECT = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


require(MODEL7.exists(), "Model7 must remain bundled as the immediate predecessor.")
require(MODEL8.exists(), "Model8 must contain the outbox ACK receipt fields.")
require(MODEL9.exists(), "Model9 must preserve the Model8 outbox ACK receipt fields.")
with CURRENT_VERSION.open("rb") as current_version_file:
    current_version = plistlib.load(current_version_file)
require(
    current_version.get("_XCCurrentVersionName") == "Model9.xcdatamodel",
    ".xccurrentversion must select Model9.",
)
require(
    "Model9.xcdatamodel" in PROJECT
    and "currentVersion" in PROJECT
    and "/* Model9.xcdatamodel */" in PROJECT,
    "The Xcode model version group must include and select Model9.",
)


SWIFT_PROOF = r'''
import CoreData
import Foundation

func loadModel(_ path: String) throws -> NSManagedObjectModel {
    guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) else {
        throw NSError(domain: "OutboxReceiptMigration", code: 1)
    }
    for entity in model.entities { entity.managedObjectClassName = "NSManagedObject" }
    return model
}

func addStore(
    _ coordinator: NSPersistentStoreCoordinator,
    url: URL,
    migrate: Bool
) throws -> NSPersistentStore {
    var options: [AnyHashable: Any] = [NSPersistentHistoryTrackingKey: false]
    if migrate {
        options[NSMigratePersistentStoresAutomaticallyOption] = true
        options[NSInferMappingModelAutomaticallyOption] = true
    }
    return try coordinator.addPersistentStore(
        ofType: NSSQLiteStoreType,
        configurationName: nil,
        at: url,
        options: options
    )
}

let environment = ProcessInfo.processInfo.environment
guard let model7Path = environment["MODEL7_MOM"],
      let model8Path = environment["MODEL8_MOM"],
      let storePath = environment["STORE_PATH"] else {
    fatalError("Missing migration environment")
}
let storeURL = URL(fileURLWithPath: storePath)
let model7 = try loadModel(model7Path)
let sourceCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model7)
let sourceStore = try addStore(sourceCoordinator, url: storeURL, migrate: false)
let source = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
source.persistentStoreCoordinator = sourceCoordinator

try source.performAndWait {
    func insert(_ recordName: String, operation: String, acknowledged: Bool, revision: String) {
        let entry = NSEntityDescription.insertNewObject(
            forEntityName: "ICCloudSyncOutboxEntry",
            into: source
        )
        entry.setValue("account", forKey: "accountRecordName")
        entry.setValue(acknowledged, forKey: "acknowledged")
        entry.setValue(recordName.hasPrefix("episode_") ? "episode" : "subscription", forKey: "category")
        entry.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "changedAt")
        entry.setValue(operation, forKey: "operation")
        entry.setValue(Data(recordName.utf8), forKey: "payloadData")
        entry.setValue(recordName, forKey: "recordName")
        entry.setValue(revision, forKey: "revision")
    }
    insert("subscription_active", operation: "save", acknowledged: true, revision: "pair-r1")
    insert("subscription_tombstone", operation: "delete", acknowledged: false, revision: "pair-r1")
    insert("episode_pending", operation: "save", acknowledged: false, revision: "episode-r1")
    try source.save()
}
try sourceCoordinator.remove(sourceStore)

let model8 = try loadModel(model8Path)
guard let outbox = model8.entitiesByName["ICCloudSyncOutboxEntry"],
      let acknowledgedRevision = outbox.attributesByName["acknowledgedRevision"],
      let acknowledgedOperation = outbox.attributesByName["acknowledgedOperation"],
      acknowledgedRevision.isOptional,
      acknowledgedOperation.isOptional,
      acknowledgedRevision.attributeType == .stringAttributeType,
      acknowledgedOperation.attributeType == .stringAttributeType else {
    fatalError("Model8 receipt attributes are missing or incompatible")
}
let targetCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model8)
let targetStore = try addStore(targetCoordinator, url: storeURL, migrate: true)
let target = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
target.persistentStoreCoordinator = targetCoordinator

try target.performAndWait {
    let request = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
    let entries = try target.fetch(request)
    precondition(entries.count == 3)
    let byName = Dictionary(uniqueKeysWithValues: entries.map {
        ($0.value(forKey: "recordName") as! String, $0)
    })
    let active = byName["subscription_active"]!
    let tombstone = byName["subscription_tombstone"]!
    let episode = byName["episode_pending"]!
    for entry in entries {
        precondition(entry.value(forKey: "acknowledgedRevision") == nil)
        precondition(entry.value(forKey: "acknowledgedOperation") == nil)
        precondition((entry.value(forKey: "payloadData") as? Data)?.isEmpty == false)
    }
    // Model7's acknowledged half remains acknowledged only through the both-nil legacy rule.
    precondition(active.value(forKey: "acknowledged") as? Bool == true)
    precondition(tombstone.value(forKey: "acknowledged") as? Bool == false)
    precondition(episode.value(forKey: "revision") as? String == "episode-r1")

    episode.setValue("episode-r1", forKey: "acknowledgedRevision")
    episode.setValue("save", forKey: "acknowledgedOperation")
    try target.save()
}
try targetCoordinator.remove(targetStore)

print("Model7 to Model8 outbox receipt migration passed")
'''


def run(command: list[str], *, environment: dict[str, str] | None = None) -> None:
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise SystemExit(result.stdout)
    if result.stdout.strip():
        print(result.stdout.strip())


with tempfile.TemporaryDirectory(prefix="instacast-outbox-model8-") as temporary_directory:
    temporary = Path(temporary_directory)
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    compiled = {}
    for name, source in (("Model7", MODEL7), ("Model8", MODEL8)):
        destination = temporary / f"{name}.mom"
        run([
            "xcrun", "momc", "--sdkroot", sdk_path, str(source), str(destination)
        ])
        compiled[name] = destination
    environment = os.environ.copy()
    environment.update({
        "MODEL7_MOM": str(compiled["Model7"]),
        "MODEL8_MOM": str(compiled["Model8"]),
        "STORE_PATH": str(temporary / "DataStore6.sqlite"),
    })
    run(["xcrun", "swift", "-e", SWIFT_PROOF], environment=environment)

print("iCloud outbox ACK Model8 migration runtime checks passed")
