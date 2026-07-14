#!/usr/bin/env python3
"""Runtime-proof the supported, history-free clean DataStore migration path."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL4 = ROOT / "Resources" / "Models" / "Model4.xcdatamodeld" / "Model.xcdatamodel"
MODEL7 = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model7.xcdatamodel"

SWIFT_PROOF = r'''
import CoreData
import Foundation
import SQLite3

struct ProofFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw ProofFailure(description: message)
    }
}

func genericModel(at path: String) throws -> NSManagedObjectModel {
    guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) else {
        throw ProofFailure(description: "Could not load model at \(path)")
    }
    for entity in model.entities {
        entity.managedObjectClassName = "NSManagedObject"
    }
    return model
}

func sqliteError(_ database: OpaquePointer?) -> String {
    guard let database, let message = sqlite3_errmsg(database) else { return "unknown SQLite error" }
    return String(cString: message)
}

func withSQLite<T>(
    at url: URL,
    flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
    _ body: (OpaquePointer) throws -> T
) throws -> T {
    var database: OpaquePointer?
    let result = sqlite3_open_v2(url.path, &database, flags, nil)
    guard result == SQLITE_OK, let database else {
        let message = sqliteError(database)
        if database != nil { sqlite3_close(database) }
        throw ProofFailure(description: "Could not open \(url.lastPathComponent): \(message)")
    }
    defer { sqlite3_close(database) }
    return try body(database)
}

func executeSQL(_ sql: String, at url: URL) throws {
    try withSQLite(at: url) { database in
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? sqliteError(database)
            sqlite3_free(errorMessage)
            throw ProofFailure(description: "SQLite statement failed: \(message); SQL=\(sql)")
        }
    }
}

func queryStrings(_ sql: String, at url: URL) throws -> [String] {
    try withSQLite(at: url) { database in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ProofFailure(description: "Could not prepare SQLite query: \(sqliteError(database))")
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) {
                values.append(String(cString: value))
            }
            stepResult = sqlite3_step(statement)
        }
        try require(stepResult == SQLITE_DONE, "SQLite query failed: \(sqliteError(database))")
        return values
    }
}

func immutableMainFileEpisodeCount(at url: URL) throws -> Int64 {
    var database: OpaquePointer?
    let uri = "file:\(url.path)?immutable=1"
    let result = sqlite3_open_v2(uri, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    guard result == SQLITE_OK, let database else {
        let message = sqliteError(database)
        if database != nil { sqlite3_close(database) }
        throw ProofFailure(description: "Could not open immutable main store: \(message)")
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM ZEPISODE", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw ProofFailure(description: "Could not inspect immutable main store: \(sqliteError(database))")
    }
    defer { sqlite3_finalize(statement) }
    try require(sqlite3_step(statement) == SQLITE_ROW, "Immutable episode count returned no row")
    return sqlite3_column_int64(statement, 0)
}

func entityCounts(model: NSManagedObjectModel, context: NSManagedObjectContext) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for entity in model.entities where !entity.isAbstract {
        guard let name = entity.name else { continue }
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: name)
        request.includesSubentities = false
        counts[name] = try context.count(for: request)
    }
    return counts
}

func addStore(
    coordinator: NSPersistentStoreCoordinator,
    at url: URL,
    history: Bool,
    automaticMigration: Bool
) throws -> NSPersistentStore {
    var options: [AnyHashable: Any] = [
        NSPersistentHistoryTrackingKey: history,
        NSSQLitePragmasOption: ["journal_mode": "WAL", "wal_autocheckpoint": "0"],
    ]
    if automaticMigration {
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

func insertUserFixture(
    into context: NSManagedObjectContext,
    model: NSManagedObjectModel,
    label: String,
    includeBinaryRows: Bool
) throws -> Data? {
    func insert(_ entityName: String) throws -> NSManagedObject {
        guard let entity = model.entitiesByName[entityName] else {
            throw ProofFailure(description: "\(label) has no \(entityName) entity")
        }
        return NSManagedObject(entity: entity, insertInto: context)
    }

    let feed = try insert("Feed")
    feed.setValue("feed-\(label)", forKey: "uid")
    feed.setValue("Podcast Übergröße \(label)", forKey: "title")
    feed.setValue("https://example.test/\(label).xml", forKey: "sourceURL_")
    feed.setValue(true, forKey: "subscribed")

    let episode = try insert("Episode")
    episode.setValue("episode-\(label)", forKey: "uid")
    episode.setValue("guid-\(label)", forKey: "guid")
    episode.setValue("hash-\(label)", forKey: "objectHash")
    episode.setValue("Episode \(label)", forKey: "title")
    episode.setValue(String(repeating: "Volltext-\(label)-", count: 8_192), forKey: "fulltext")
    episode.setValue(3_601, forKey: "duration")
    episode.setValue(911, forKey: "position")
    episode.setValue(Date(timeIntervalSince1970: 1_700_000_000), forKey: "pubDate")
    episode.setValue(feed, forKey: "feed")

    let chapter = try insert("Chapter")
    chapter.setValue("chapter-\(label)", forKey: "uid")
    chapter.setValue("Kapitel Eins", forKey: "title")
    chapter.setValue(42.5, forKey: "timecode")
    chapter.setValue(episode, forKey: "episode")

    let medium = try insert("Medium")
    medium.setValue("medium-\(label)", forKey: "uid")
    medium.setValue("audio/mpeg", forKey: "mimeType")
    medium.setValue(9_876_543, forKey: "byteSize")
    medium.setValue("https://example.test/audio/\(label).mp3", forKey: "fileURL_")
    medium.setValue(episode, forKey: "episode")

    let category = try insert("Category")
    category.setValue("category-\(label)", forKey: "uid")
    category.setValue("Technik", forKey: "title")
    category.setValue(feed, forKey: "feed")

    let bookmark = try insert("Bookmark")
    bookmark.setValue("bookmark-\(label)", forKey: "uid")
    bookmark.setValue("Marker \(label)", forKey: "title")
    bookmark.setValue("guid-\(label)", forKey: "episodeGuid")
    bookmark.setValue(123.75, forKey: "position")

    guard includeBinaryRows else {
        try context.save()
        return nil
    }

    let payload = Data((0..<(512 * 1_024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let outbox = try insert("ICCloudSyncOutboxEntry")
    outbox.setValue("account-\(label)", forKey: "accountRecordName")
    outbox.setValue(false, forKey: "acknowledged")
    outbox.setValue("episode", forKey: "category")
    outbox.setValue(Date(timeIntervalSince1970: 1_700_000_001), forKey: "changedAt")
    outbox.setValue("save", forKey: "operation")
    outbox.setValue(payload, forKey: "payloadData")
    outbox.setValue("record-\(label)", forKey: "recordName")
    outbox.setValue("revision-\(label)", forKey: "revision")

    let systemFields = try insert("ICCloudKnownRecordSystemFields")
    systemFields.setValue("account-\(label)", forKey: "accountRecordName")
    systemFields.setValue("known-record-\(label)", forKey: "recordName")
    systemFields.setValue(payload, forKey: "systemFieldsData")
    try context.save()
    return payload
}

func validateUserFixture(
    in context: NSManagedObjectContext,
    label: String,
    expectedPayload: Data?
) throws {
    let episodeRequest = NSFetchRequest<NSManagedObject>(entityName: "Episode")
    episodeRequest.predicate = NSPredicate(format: "objectHash == %@", "hash-\(label)")
    guard let episode = try context.fetch(episodeRequest).first else {
        throw ProofFailure(description: "\(label) episode was lost")
    }
    try require(episode.value(forKey: "title") as? String == "Episode \(label)", "\(label) episode attributes changed")
    try require((episode.value(forKey: "fulltext") as? String)?.count ?? 0 > 100_000, "\(label) large text was truncated")

    guard let feed = episode.value(forKey: "feed") as? NSManagedObject else {
        throw ProofFailure(description: "\(label) Episode→Feed relationship was lost")
    }
    try require(feed.value(forKey: "uid") as? String == "feed-\(label)", "\(label) related feed changed")
    try require((feed.value(forKey: "episodes") as? Set<NSManagedObject>)?.count == 1, "\(label) Feed→Episodes inverse was lost")

    let chapters = episode.value(forKey: "chapters") as? Set<NSManagedObject>
    try require(chapters?.first?.value(forKey: "title") as? String == "Kapitel Eins", "\(label) chapter relationship was lost")
    let media = episode.value(forKey: "media") as? Set<NSManagedObject>
    try require(media?.first?.value(forKey: "byteSize") as? Int64 == 9_876_543, "\(label) medium relationship was lost")
    let categories = feed.value(forKey: "categories") as? Set<NSManagedObject>
    try require(categories?.first?.value(forKey: "uid") as? String == "category-\(label)", "\(label) category relationship was lost")

    let bookmarkRequest = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
    bookmarkRequest.predicate = NSPredicate(format: "uid == %@", "bookmark-\(label)")
    guard let bookmark = try context.fetch(bookmarkRequest).first else {
        throw ProofFailure(description: "\(label) bookmark was lost")
    }
    try require((bookmark.value(forKey: "position") as? NSNumber)?.doubleValue == 123.75, "\(label) bookmark value changed")

    if let expectedPayload {
        let outboxRequest = NSFetchRequest<NSManagedObject>(entityName: "ICCloudSyncOutboxEntry")
        outboxRequest.predicate = NSPredicate(format: "recordName == %@", "record-\(label)")
        guard let outbox = try context.fetch(outboxRequest).first else {
            throw ProofFailure(description: "\(label) binary outbox row was lost")
        }
        try require(outbox.value(forKey: "payloadData") as? Data == expectedPayload, "\(label) outbox BLOB changed")

        let fieldsRequest = NSFetchRequest<NSManagedObject>(entityName: "ICCloudKnownRecordSystemFields")
        fieldsRequest.predicate = NSPredicate(format: "recordName == %@", "known-record-\(label)")
        guard let fields = try context.fetch(fieldsRequest).first else {
            throw ProofFailure(description: "\(label) binary system-fields row was lost")
        }
        try require(fields.value(forKey: "systemFieldsData") as? Data == expectedPayload, "\(label) system-fields BLOB changed")
    }

    bookmark.setValue("Marker nach Reopen \(label)", forKey: "title")
    try context.save()
}

func sqliteObjectNames(at url: URL) throws -> Set<String> {
    Set(try queryStrings("SELECT name FROM sqlite_master WHERE type IN ('table', 'index')", at: url))
}

func obsoleteNames(in names: Set<String>) -> [String] {
    names.filter { name in
        name.hasPrefix("ANSCK") ||
        name == "ACHANGE" || name.hasPrefix("ACHANGE_") ||
        name == "ATRANSACTION" || name.hasPrefix("ATRANSACTION_") ||
        name == "ATRANSACTIONSTRING" || name.hasPrefix("ATRANSACTIONSTRING_")
    }.sorted()
}

func runFixture(
    label: String,
    sourceModelPath: String,
    currentModelPath: String,
    directory: URL,
    includeBinaryRows: Bool
) throws {
    let sourceURL = directory.appendingPathComponent("\(label)-source.sqlite")
    let targetURL = directory.appendingPathComponent("\(label)-DataStore6.sqlite")
    let sourceModel = try genericModel(at: sourceModelPath)
    let sourceCoordinator = NSPersistentStoreCoordinator(managedObjectModel: sourceModel)
    let sourceStore = try addStore(
        coordinator: sourceCoordinator,
        at: sourceURL,
        history: true,
        automaticMigration: false
    )
    let sourceContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    sourceContext.persistentStoreCoordinator = sourceCoordinator

    try executeSQL("PRAGMA wal_checkpoint(TRUNCATE)", at: sourceURL)
    let mainCountBeforeInsert = try immutableMainFileEpisodeCount(at: sourceURL)
    try require(mainCountBeforeInsert == 0, "\(label) main store was not clean before WAL proof")
    let expectedPayload = try sourceContext.performAndWait {
        try insertUserFixture(
            into: sourceContext,
            model: sourceModel,
            label: label,
            includeBinaryRows: includeBinaryRows
        )
    }
    try executeSQL(
        "CREATE TABLE ANSCKLEGACYBLOAT (Z_PK INTEGER PRIMARY KEY, ZDATA BLOB); " +
        "INSERT INTO ANSCKLEGACYBLOAT (Z_PK, ZDATA) VALUES (1, zeroblob(1048576));",
        at: sourceURL
    )

    let walURL = URL(fileURLWithPath: sourceURL.path + "-wal")
    let walSize = (try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber)?.int64Value ?? 0
    try require(walSize > 32, "\(label) fixture did not retain uncheckpointed WAL frames")
    let immutableEpisodeCount = try immutableMainFileEpisodeCount(at: sourceURL)
    try require(immutableEpisodeCount == 0, "\(label) episode was checkpointed instead of remaining WAL-only")
    let coreDataEpisodeCount = try sourceContext.performAndWait {
        try sourceContext.count(for: NSFetchRequest<NSFetchRequestResult>(entityName: "Episode"))
    }
    try require(coreDataEpisodeCount == 1, "\(label) Core Data could not read its WAL-only episode")

    let sourceNames = try sqliteObjectNames(at: sourceURL)
    for expectedObsoleteTable in ["ANSCKLEGACYBLOAT", "ACHANGE", "ATRANSACTION", "ATRANSACTIONSTRING"] {
        try require(sourceNames.contains(expectedObsoleteTable), "\(label) source fixture lacks \(expectedObsoleteTable)")
    }
    let sourceCounts = try sourceContext.performAndWait {
        try entityCounts(model: sourceModel, context: sourceContext)
    }

    let migratedStore = try sourceCoordinator.migratePersistentStore(
        sourceStore,
        to: targetURL,
        options: [
            NSPersistentHistoryTrackingKey: false,
            NSSQLitePragmasOption: ["journal_mode": "WAL", "wal_autocheckpoint": "0"],
        ],
        withType: NSSQLiteStoreType
    )
    try sourceCoordinator.remove(migratedStore)

    let currentModel = try genericModel(at: currentModelPath)
    let upgradeCoordinator = NSPersistentStoreCoordinator(managedObjectModel: currentModel)
    let upgradedStore = try addStore(
        coordinator: upgradeCoordinator,
        at: targetURL,
        history: false,
        automaticMigration: true
    )
    try upgradeCoordinator.remove(upgradedStore)

    let reopenModel = try genericModel(at: currentModelPath)
    let reopenCoordinator = NSPersistentStoreCoordinator(managedObjectModel: reopenModel)
    let reopenedStore = try addStore(
        coordinator: reopenCoordinator,
        at: targetURL,
        history: false,
        automaticMigration: false
    )
    let reopenContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    reopenContext.persistentStoreCoordinator = reopenCoordinator

    let targetCounts = try reopenContext.performAndWait {
        try entityCounts(model: reopenModel, context: reopenContext)
    }
    for (entityName, expectedCount) in sourceCounts {
        try require(targetCounts[entityName] == expectedCount, "\(label) count changed for \(entityName): \(expectedCount) → \(targetCounts[entityName] ?? -1)")
    }
    try reopenContext.performAndWait {
        try validateUserFixture(in: reopenContext, label: label, expectedPayload: expectedPayload)
    }
    try reopenCoordinator.remove(reopenedStore)

    let targetNames = try sqliteObjectNames(at: targetURL)
    try require(obsoleteNames(in: targetNames).isEmpty, "\(label) target retained obsolete objects: \(obsoleteNames(in: targetNames))")
    let quickCheck = try queryStrings("PRAGMA quick_check", at: targetURL)
    try require(quickCheck == ["ok"], "\(label) target failed SQLite quick_check")
    try require(FileManager.default.fileExists(atPath: sourceURL.path), "\(label) supported migration destroyed the rollback source")
    let rollbackEpisodeCount = try queryStrings("SELECT COUNT(*) FROM ZEPISODE", at: sourceURL)
    try require(rollbackEpisodeCount == ["1"], "\(label) rollback source no longer contains its WAL-backed episode")

    print("\(label): WAL \(walSize) bytes, \(sourceCounts.values.reduce(0, +)) modeled rows preserved, clean history-free reopen passed")
}

let environment = ProcessInfo.processInfo.environment
guard let model4Path = environment["PUBLISHED_MODEL4_MOM"],
      let model7Path = environment["CURRENT_MODEL7_MOM"],
      let storeDirectory = environment["MIGRATION_STORE_DIRECTORY"] else {
    fatalError("Missing clean migration proof paths")
}
let directory = URL(fileURLWithPath: storeDirectory, isDirectory: true)
try runFixture(
    label: "published-model4",
    sourceModelPath: model4Path,
    currentModelPath: model7Path,
    directory: directory,
    includeBinaryRows: false
)
try runFixture(
    label: "current-model7",
    sourceModelPath: model7Path,
    currentModelPath: model7Path,
    directory: directory,
    includeBinaryRows: true
)
print("DataStore clean migration runtime proof passed")
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


with tempfile.TemporaryDirectory(prefix="instacast-clean-datastore-migration-") as temporary_directory:
    temporary = Path(temporary_directory)
    sdk_path = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    model4_mom = temporary / "PublishedModel4.mom"
    model7_mom = temporary / "CurrentModel7.mom"
    for source, destination in [(MODEL4, model4_mom), (MODEL7, model7_mom)]:
        run([
            "xcrun",
            "momc",
            "--sdkroot",
            sdk_path,
            str(source),
            str(destination),
        ])

    proof_environment = os.environ.copy()
    proof_environment.update({
        "PUBLISHED_MODEL4_MOM": str(model4_mom),
        "CURRENT_MODEL7_MOM": str(model7_mom),
        "MIGRATION_STORE_DIRECTORY": str(temporary),
    })
    run(["xcrun", "swift", "-e", SWIFT_PROOF], environment=proof_environment)
