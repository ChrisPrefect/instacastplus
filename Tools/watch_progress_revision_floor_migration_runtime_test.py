#!/usr/bin/env python3
"""Runtime proof that legacy Watch rows participate in the monotone floor predicate."""

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

let environment = ProcessInfo.processInfo.environment
guard let oldModelPath = environment["OLD_MODEL_MOM"],
      let newModelPath = environment["NEW_MODEL_MOM"],
      let storePath = environment["MIGRATION_STORE"] else {
    fatalError("Missing migration proof paths")
}
guard let oldModel = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: oldModelPath)),
      let oldEntity = oldModel.entitiesByName["AppleWatchEpisodeState"] else {
    fatalError("Could not load the legacy Watch model")
}
oldEntity.managedObjectClassName = "NSManagedObject"

let storeURL = URL(fileURLWithPath: storePath)
let oldContainer = NSPersistentContainer(name: "LegacyWatchFloor", managedObjectModel: oldModel)
let oldDescription = NSPersistentStoreDescription(url: storeURL)
oldDescription.type = NSSQLiteStoreType
try loadStore(container: oldContainer, description: oldDescription)

let legacyState = NSManagedObject(entity: oldEntity, insertInto: oldContainer.viewContext)
legacyState.setValue("legacy-episode", forKey: "episodeHash")
legacyState.setValue("legacy-selection", forKey: "uid")
try oldContainer.viewContext.save()
for store in oldContainer.persistentStoreCoordinator.persistentStores {
    try oldContainer.persistentStoreCoordinator.remove(store)
}

guard let newModel = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: newModelPath)),
      let newEntity = newModel.entitiesByName["AppleWatchEpisodeState"] else {
    fatalError("Could not load Model6")
}
newEntity.managedObjectClassName = "NSManagedObject"

let newContainer = NSPersistentContainer(name: "CurrentWatchFloor", managedObjectModel: newModel)
let newDescription = NSPersistentStoreDescription(url: storeURL)
newDescription.type = NSSQLiteStoreType
newDescription.shouldMigrateStoreAutomatically = true
newDescription.shouldInferMappingModelAutomatically = true
try loadStore(container: newContainer, description: newDescription)

let fetch = NSFetchRequest<NSManagedObject>(entityName: "AppleWatchEpisodeState")
fetch.predicate = NSPredicate(format: "episodeHash == %@ AND uid == %@", "legacy-episode", "legacy-selection")
guard let migratedState = try newContainer.viewContext.fetch(fetch).first else {
    fatalError("Legacy Watch state was lost during lightweight migration")
}
guard (migratedState.value(forKey: "watchLastEventRevision") as? NSNumber)?.int64Value == 0 else {
    fatalError("Migrated Watch revision did not materialize as zero")
}

let update = NSBatchUpdateRequest(entityName: "AppleWatchEpisodeState")
update.predicate = NSPredicate(
    format: "episodeHash == %@ AND uid == %@ AND watchLastEventRevision < %@",
    "legacy-episode",
    "legacy-selection",
    NSNumber(value: 42)
)
update.propertiesToUpdate = ["watchLastEventRevision": NSNumber(value: 42)]
update.resultType = .updatedObjectIDsResultType
guard let result = try newContainer.viewContext.execute(update) as? NSBatchUpdateResult,
      let updatedObjectIDs = result.result as? [NSManagedObjectID],
      updatedObjectIDs == [migratedState.objectID] else {
    fatalError("The monotone predicate did not update exactly the migrated Watch row")
}

let migratedObjectID = migratedState.objectID
newContainer.viewContext.reset()
let persistedState = try newContainer.viewContext.existingObject(with: migratedObjectID)
guard (persistedState.value(forKey: "watchLastEventRevision") as? NSNumber)?.int64Value == 42 else {
    fatalError("The migrated Watch revision floor was not persisted")
}

print("Watch progress revision-floor lightweight migration runtime proof passed")
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
        raise AssertionError(f"Command failed ({result.returncode}): {' '.join(command)}\n{result.stdout}")
    if result.stdout.strip():
        print(result.stdout.strip())


with tempfile.TemporaryDirectory(prefix="instacast-watch-floor-migration-") as temporary_directory:
    temporary = Path(temporary_directory)
    old_mom = temporary / "Legacy.mom"
    new_mom = temporary / "Model6.mom"
    store = temporary / "WatchFloor.sqlite"
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    run(
        [
            "xcrun",
            "momc",
            "--sdkroot",
            sdk_path,
            str(MODEL_DIRECTORY / "Model.xcdatamodel"),
            str(old_mom),
        ]
    )
    run(
        [
            "xcrun",
            "momc",
            "--sdkroot",
            sdk_path,
            str(MODEL_DIRECTORY / "Model6.xcdatamodel"),
            str(new_mom),
        ]
    )
    proof_environment = os.environ.copy()
    proof_environment.update(
        {
            "OLD_MODEL_MOM": str(old_mom),
            "NEW_MODEL_MOM": str(new_mom),
            "MIGRATION_STORE": str(store),
        }
    )
    run(["xcrun", "swift", "-e", SWIFT_PROOF], environment=proof_environment)
