#!/usr/bin/env python3
"""Pins kill-safe supported rewriting of a legacy Core Data store."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    implementation = DATABASE.find("@implementation DatabaseManager")
    start = DATABASE.find(signature, implementation)
    require(start != -1, f"Missing method: {signature}")
    brace = DATABASE.find("{", start)
    depth = 0
    for index in range(brace, len(DATABASE)):
        if DATABASE[index] == "{":
            depth += 1
        elif DATABASE[index] == "}":
            depth -= 1
            if depth == 0:
                return DATABASE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


preparation = method_body("+ (BOOL)_prepareDataStoreMigrationWithError:")
building_write = preparation.find("_writeDataStoreMigrationMarker:marker")
target_cleanup = preparation.find("_removePreparedDataStoreAtURL", building_write)
supported_migration = preparation.find("migratePersistentStore", target_cleanup)
count_compare = preparation.find("isEqualToDictionary", supported_migration)
ready_phase = preparation.find("ICDataStoreMigrationPhaseReady", count_compare)
ready_write = preparation.find("_writeDataStoreMigrationMarker:readyMarker", ready_phase)
require(-1 < building_write < target_cleanup < supported_migration < count_compare < ready_phase < ready_write,
        "A building marker must precede target creation, and ready may be written only after supported migration and exact count verification.")
require("copyItemAtURL" not in preparation,
        "Raw SQLite/WAL copying preserves obsolete tables and is not a supported Core Data migration.")
require("NSDataWritingAtomic" in DATABASE,
        "Building/ready marker transitions must be atomic across process kills.")

initializer = method_body("- (id) init")
ready_gate = initializer.find("ICDataStoreMigrationPhaseReady")
store_open = initializer.find("NSManagedObjectContext* startupContext = self.objectContext;")
completion_save = initializer.find("saveReturningError", store_open)
marker_remove = initializer.find("removeItemAtURL:migrationMarkerURL", completion_save)
source_cleanup = initializer.find("[self _deleteObsoleteDataStores]", marker_remove)
require(-1 < ready_gate < store_open < completion_save < marker_remove < source_cleanup,
        "The source must survive until a verified target opens, app migrations save, and the marker commits.")

migrate_start = DATABASE.find("- (void) _migrateDatabase")
migrate_end = DATABASE.find("- (void) _deleteObsoleteDataStores", migrate_start)
require(migrate_start != -1 and migrate_end != -1, "Database migration boundary is missing.")
require("_deleteObsoleteDataStores" not in DATABASE[migrate_start:migrate_end],
        "Schema/data migration must not delete the source before the target completion save is confirmed.")

print("Database supported-upgrade kill-safety regression checks passed")
