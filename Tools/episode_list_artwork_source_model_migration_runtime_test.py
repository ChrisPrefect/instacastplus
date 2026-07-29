#!/usr/bin/env python3
"""Runtime-prove the additive Model8→Model9 episode-list artwork migration."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIRECTORY = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"
MODEL8 = MODEL_DIRECTORY / "Model8.xcdatamodel"
MODEL9 = MODEL_DIRECTORY / "Model9.xcdatamodel"


SWIFT_PROOF = r'''
import CoreData
import Foundation

func loadModel(_ path: String) throws -> NSManagedObjectModel {
    guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) else {
        throw NSError(domain: "EpisodeListArtworkMigration", code: 1)
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
let model8 = try loadModel(environment["MODEL8_MOM"]!)
let model9 = try loadModel(environment["MODEL9_MOM"]!)
let storeURL = URL(fileURLWithPath: environment["STORE_PATH"]!)

let sourceCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model8)
let sourceStore = try addStore(sourceCoordinator, url: storeURL, migrate: false)
let source = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
source.persistentStoreCoordinator = sourceCoordinator
try source.performAndWait {
    let list = NSEntityDescription.insertNewObject(forEntityName: "EpisodeList", into: source)
    list.setValue("Artwork migration", forKey: "name")
    list.setValue("artwork-migration", forKey: "uid")
    try source.save()
}
try sourceCoordinator.remove(sourceStore)

guard let artwork = model9.entitiesByName["EpisodeList"]?.attributesByName["usePodcastArtwork"],
      artwork.attributeType == .booleanAttributeType,
      artwork.defaultValue as? Bool == false else {
    fatalError("Model9 artwork attribute is missing or has the wrong default")
}

let targetCoordinator = NSPersistentStoreCoordinator(managedObjectModel: model9)
let targetStore = try addStore(targetCoordinator, url: storeURL, migrate: true)
let target = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
target.persistentStoreCoordinator = targetCoordinator
try target.performAndWait {
    let request = NSFetchRequest<NSManagedObject>(entityName: "EpisodeList")
    let lists = try target.fetch(request)
    precondition(lists.count == 1)
    let list = lists[0]
    precondition(list.value(forKey: "uid") as? String == "artwork-migration")
    precondition(list.value(forKey: "usePodcastArtwork") as? Bool == false)
    list.setValue(true, forKey: "usePodcastArtwork")
    try target.save()
}
try targetCoordinator.remove(targetStore)

print("Model8 to Model9 episode-list artwork migration passed")
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


with tempfile.TemporaryDirectory(prefix="instacast-artwork-model9-") as temporary_directory:
    temporary = Path(temporary_directory)
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    compiled = {}
    for name, source in (("Model8", MODEL8), ("Model9", MODEL9)):
        destination = temporary / f"{name}.mom"
        run(["xcrun", "momc", "--sdkroot", sdk_path, str(source), str(destination)])
        compiled[name] = destination
    environment = os.environ.copy()
    environment.update({
        "MODEL8_MOM": str(compiled["Model8"]),
        "MODEL9_MOM": str(compiled["Model9"]),
        "STORE_PATH": str(temporary / "DataStore6.sqlite"),
    })
    run(["xcrun", "swift", "-e", SWIFT_PROOF], environment=environment)

print("Episode-list artwork Model9 migration runtime checks passed")
