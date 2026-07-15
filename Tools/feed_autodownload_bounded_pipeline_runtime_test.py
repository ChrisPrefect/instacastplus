#!/usr/bin/env python3
"""Runtime-proves the grouped SQLite Core Data query used by auto-download."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model8.xcdatamodel"

SWIFT_PROOF = r'''
import CoreData
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let modelPath = environment["AUTODOWNLOAD_MODEL"],
      let storePath = environment["AUTODOWNLOAD_STORE"],
      let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: modelPath)) else {
    fatalError("Missing auto-download runtime proof paths")
}
for entity in model.entities { entity.managedObjectClassName = "NSManagedObject" }

let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
try coordinator.addPersistentStore(
    ofType: NSSQLiteStoreType,
    configurationName: nil,
    at: URL(fileURLWithPath: storePath)
)
let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
context.persistentStoreCoordinator = coordinator

try context.performAndWait {
    for feedIndex in 0..<20 {
        let feed = NSEntityDescription.insertNewObject(forEntityName: "Feed", into: context)
        feed.setValue("feed-\(feedIndex)", forKey: "uid")
        feed.setValue(true, forKey: "subscribed")
        feed.setValue(false, forKey: "parked")
        for dayOffset in 0..<3 {
            let episode = NSEntityDescription.insertNewObject(forEntityName: "Episode", into: context)
            episode.setValue("episode-\(feedIndex)-\(dayOffset)", forKey: "objectHash")
            episode.setValue(feedIndex == 0 && dayOffset == 0, forKey: "consumed")
            episode.setValue(feedIndex == 1 && dayOffset == 0, forKey: "archived")
            episode.setValue(
                Date(timeIntervalSince1970: 1_700_000_000 - Double(dayOffset * 86_400)),
                forKey: "pubDate"
            )
            episode.setValue(feed, forKey: "feed")
        }
    }
    try context.save()

    let feedUIDExpression = NSExpressionDescription()
    feedUIDExpression.name = "feedUID"
    feedUIDExpression.expression = NSExpression(forKeyPath: "feed.uid")
    feedUIDExpression.expressionResultType = .stringAttributeType

    let latestPubDateExpression = NSExpressionDescription()
    latestPubDateExpression.name = "latestPubDate"
    latestPubDateExpression.expression = NSExpression(
        forFunction: "max:",
        arguments: [NSExpression(forKeyPath: "pubDate")]
    )
    latestPubDateExpression.expressionResultType = .dateAttributeType

    let latestDatesRequest = NSFetchRequest<NSDictionary>(entityName: "Episode")
    latestDatesRequest.predicate = NSPredicate(
        format: "pubDate != nil AND feed.uid IN %@",
        (0..<20).map { "feed-\($0)" }
    )
    latestDatesRequest.resultType = .dictionaryResultType
    latestDatesRequest.propertiesToFetch = [feedUIDExpression, latestPubDateExpression]
    latestDatesRequest.propertiesToGroupBy = ["feed.uid"]

    let rows = try context.fetch(latestDatesRequest)
    precondition(rows.count == 20, "Expected 20 grouped feeds, got \(rows.count)")
    precondition(rows.allSatisfy {
        $0["feedUID"] is String && $0["latestPubDate"] is Date
    }, "Grouped rows returned unexpected value types")

    let calendar = Calendar.current
    let latestDayPredicates: [NSPredicate] = rows.compactMap { row in
        guard let feedUID = row["feedUID"] as? String,
              let latestPubDate = row["latestPubDate"] as? Date,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: latestPubDate)) else {
            return nil
        }
        return NSPredicate(
            format: "feed.uid == %@ AND pubDate >= %@ AND pubDate < %@",
            feedUID,
            calendar.startOfDay(for: latestPubDate) as NSDate,
            nextDay as NSDate
        )
    }
    let candidatesRequest = NSFetchRequest<NSManagedObject>(entityName: "Episode")
    candidatesRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
        NSPredicate(format: "consumed == NO AND archived == NO"),
        NSCompoundPredicate(orPredicateWithSubpredicates: latestDayPredicates),
    ])
    let candidateHashes = Set(try context.fetch(candidatesRequest).compactMap {
        $0.value(forKey: "objectHash") as? String
    })
    precondition(candidateHashes.count == 18, "Consumed/archived newest rows must not expose an older day")
    precondition(!candidateHashes.contains("episode-0-1") && !candidateHashes.contains("episode-1-1"),
                 "The scan regressed into progressively downloading older publication days")
}

print("Bounded feed auto-download Core Data runtime query passed")
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


with tempfile.TemporaryDirectory(prefix="instacast-autodownload-query-") as raw_directory:
    directory = Path(raw_directory)
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    compiled_model = directory / "Model7.mom"
    run([
        "xcrun",
        "momc",
        "--sdkroot",
        sdk_path,
        str(MODEL),
        str(compiled_model),
    ])
    environment = os.environ.copy()
    environment.update({
        "AUTODOWNLOAD_MODEL": str(compiled_model),
        "AUTODOWNLOAD_STORE": str(directory / "DataStore.sqlite"),
    })
    run(["xcrun", "swift", "-e", SWIFT_PROOF], environment=environment)
