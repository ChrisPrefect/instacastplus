#!/usr/bin/env python3
"""Runtime-proves published Model4→Model7 and Model6→Model7 migration."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIRECTORY = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"

SWIFT_PROOF = r'''
import CoreData
import Foundation

func loadStore(container: NSPersistentContainer, description: NSPersistentStoreDescription) throws {
    let semaphore = DispatchSemaphore(value: 0)
    var loadError: Error?
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in
        loadError = error
        semaphore.signal()
    }
    semaphore.wait()
    if let loadError { throw loadError }
}

func genericModel(at path: String) throws -> NSManagedObjectModel {
    guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) else {
        throw NSError(domain: "MigrationProof", code: 1)
    }
    for entity in model.entities {
        entity.managedObjectClassName = "NSManagedObject"
    }
    return model
}

let environment = ProcessInfo.processInfo.environment
guard let publishedModel4Path = environment["PUBLISHED_MODEL4_MOM"],
      let model6Path = environment["MODEL6_MOM"],
      let model7Path = environment["MODEL7_MOM"],
      let storeDirectory = environment["MIGRATION_STORE_DIRECTORY"] else {
    fatalError("Missing migration proof paths")
}

for (label, sourcePath) in [("publishedModel4", publishedModel4Path), ("Model6", model6Path)] {
    let storeURL = URL(fileURLWithPath: storeDirectory)
        .appendingPathComponent("\(label).sqlite")
    let sourceModel = try genericModel(at: sourcePath)
    guard let bookmarkEntity = sourceModel.entitiesByName["Bookmark"] else {
        fatalError("\(label) has no Bookmark entity")
    }
    let sourceContainer = NSPersistentContainer(
        name: "SystemFieldsSource\(label)",
        managedObjectModel: sourceModel
    )
    let sourceDescription = NSPersistentStoreDescription(url: storeURL)
    sourceDescription.type = NSSQLiteStoreType
    try loadStore(container: sourceContainer, description: sourceDescription)

    let bookmark = NSManagedObject(entity: bookmarkEntity, insertInto: sourceContainer.viewContext)
    bookmark.setValue("bookmark-\(label)", forKey: "uid")
    bookmark.setValue("Bookmark \(label)", forKey: "title")
    if let outboxEntity = sourceModel.entitiesByName["ICCloudSyncOutboxEntry"] {
        let outbox = NSManagedObject(entity: outboxEntity, insertInto: sourceContainer.viewContext)
        outbox.setValue("account-\(label)", forKey: "accountRecordName")
        outbox.setValue(false, forKey: "acknowledged")
        outbox.setValue("episode", forKey: "category")
        outbox.setValue(Date(timeIntervalSince1970: 42), forKey: "changedAt")
        outbox.setValue("save", forKey: "operation")
        outbox.setValue(Data([1, 2, 3]), forKey: "payloadData")
        outbox.setValue("record-\(label)", forKey: "recordName")
        outbox.setValue("revision-\(label)", forKey: "revision")
    }
    try sourceContainer.viewContext.save()
    for store in sourceContainer.persistentStoreCoordinator.persistentStores {
        try sourceContainer.persistentStoreCoordinator.remove(store)
    }

    let targetModel = try genericModel(at: model7Path)
    let targetContainer = NSPersistentContainer(
        name: "SystemFieldsTarget\(label)",
        managedObjectModel: targetModel
    )
    let targetDescription = NSPersistentStoreDescription(url: storeURL)
    targetDescription.type = NSSQLiteStoreType
    targetDescription.shouldMigrateStoreAutomatically = true
    targetDescription.shouldInferMappingModelAutomatically = true
    try loadStore(container: targetContainer, description: targetDescription)

    let bookmarkRequest = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
    bookmarkRequest.predicate = NSPredicate(format: "uid == %@", "bookmark-\(label)")
    guard let migratedBookmark = try targetContainer.viewContext.fetch(bookmarkRequest).first,
          migratedBookmark.value(forKey: "title") as? String == "Bookmark \(label)" else {
        fatalError("\(label) user data did not survive migration")
    }
    if label == "Model6" {
        let outboxRequest = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
        outboxRequest.predicate = NSPredicate(format: "recordName == %@", "record-Model6")
        guard try targetContainer.viewContext.count(for: outboxRequest) == 1 else {
            fatalError("Model6 outbox row did not survive Model7 migration")
        }
    }

    guard let systemFieldsEntity = targetModel.entitiesByName["ICCloudKnownRecordSystemFields"] else {
        fatalError("Model7 system-field entity is missing")
    }
    let systemFields = NSManagedObject(
        entity: systemFieldsEntity,
        insertInto: targetContainer.viewContext
    )
    systemFields.setValue("account-\(label)", forKey: "accountRecordName")
    systemFields.setValue("known-\(label)", forKey: "recordName")
    systemFields.setValue(Data([4, 5, 6]), forKey: "systemFieldsData")
    try targetContainer.viewContext.save()
    let systemFieldsRequest = NSFetchRequest<NSManagedObject>(
        entityName: "ICCloudKnownRecordSystemFields"
    )
    systemFieldsRequest.predicate = NSPredicate(format: "recordName == %@", "known-\(label)")
    guard try targetContainer.viewContext.count(for: systemFieldsRequest) == 1 else {
        fatalError("Model7 system-field row was not writable after \(label) migration")
    }
    for store in targetContainer.persistentStoreCoordinator.persistentStores {
        try targetContainer.persistentStoreCoordinator.remove(store)
    }
}

print("iCloud system-field published-Model4/Model6 migration runtime proof passed")
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
        raise AssertionError(
            f"Command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}"
        )
    if result.stdout.strip():
        print(result.stdout.strip())


with tempfile.TemporaryDirectory(prefix="instacast-system-fields-migration-") as temporary_directory:
    temporary = Path(temporary_directory)
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    compiled_models = {}
    for source_name in ["Model6", "Model7"]:
        output = temporary / f"{source_name}.mom"
        run([
            "xcrun",
            "momc",
            "--sdkroot",
            sdk_path,
            str(MODEL_DIRECTORY / f"{source_name}.xcdatamodel"),
            str(output),
        ])
        compiled_models[source_name] = output
    published_model4 = temporary / "PublishedModel4.mom"
    run([
        "xcrun",
        "momc",
        "--sdkroot",
        sdk_path,
        str(ROOT / "Resources" / "Models" / "Model4.xcdatamodeld" / "Model.xcdatamodel"),
        str(published_model4),
    ])

    proof_environment = os.environ.copy()
    proof_environment.update({
        "PUBLISHED_MODEL4_MOM": str(published_model4),
        "MODEL6_MOM": str(compiled_models["Model6"]),
        "MODEL7_MOM": str(compiled_models["Model7"]),
        "MIGRATION_STORE_DIRECTORY": str(temporary),
    })
    run(["xcrun", "swift", "-e", SWIFT_PROOF], environment=proof_environment)
