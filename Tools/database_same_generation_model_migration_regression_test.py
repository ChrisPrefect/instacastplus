#!/usr/bin/env python3
"""Pins the in-place lightweight migration for a new model in DataStore6."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise SystemExit(f"Unterminated method: {signature}")


prepare = method_body("+ (BOOL)_prepareDataStoreMigrationWithError:(NSError**)error\n{")
target_exists = prepare[prepare.find("else if ([fileManager fileExistsAtPath:targetURL.path])"):]
require(
    "_lightweightMigrateCurrentDataStoreAtURL" in target_exists,
    "An existing DataStore6 with Model7 must be migrated before it is rejected as incompatible.",
)
prepared_target = prepare.find("if ([phase isEqualToString:ICDataStoreMigrationPhaseCommitting] ||")
require(
    prepared_target >= 0,
    "Ready and committing targets must share the same identity-preserving validation path.",
)
committing = prepare[prepared_target:]
require(
    "_lightweightMigrateCurrentDataStoreAtURL" in committing
    and "markerIdentityMatches" in committing
    and "compatibleWithStoreMetadata" in committing,
    "An interrupted committing Model7 target must migrate in place without rebuilding from its older source.",
)
require(
    committing.find("_lightweightMigrateCurrentDataStoreAtURL")
    < committing.find("if ([phase isEqualToString:ICDataStoreMigrationPhaseReady])"),
    "Prepared-target migration must happen before the structurally invalid ready-target rebuild path.",
)

migrate = method_body(
    "+ (BOOL)_lightweightMigrateCurrentDataStoreAtURL:(NSURL*)storeURL\n"
    "                                    sourceMetadata:(NSDictionary*)sourceMetadata\n"
    "                                             error:(NSError**)error\n{"
)
for token, purpose in [
    ("_compatibleSourceModelForMetadata", "accept only a bundled predecessor model"),
    ("_entityCountsAtStoreURL", "count source and target entities"),
    ("NSMigratePersistentStoresAutomaticallyOption", "enable lightweight migration"),
    ("NSInferMappingModelAutomaticallyOption", "infer the additive mapping"),
    ("NSPersistentHistoryTrackingKey", "keep persistent history disabled"),
    ("removePersistentStore", "close the migration coordinator before launch"),
    ("_validatePreparedStoreAtURL", "verify model compatibility, counts, and SQLite integrity"),
    ("NSStoreUUIDKey", "preserve the existing store identity"),
]:
    require(token in migrate, f"Same-generation migration must {purpose}.")

require(
    "DATA_STORE_GENERATION 6" in SOURCE,
    "An additive Model8 migration must not force another full database-generation copy.",
)

print("Same-generation Core Data model migration regression checks passed")
