#!/usr/bin/env python3
"""Pins kill-safe copying of a legacy Core Data SQLite/WAL/SHM store."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


init_start = DATABASE.find("- (id) init")
init_end = DATABASE.find("- (NSError*)_databaseInitializationErrorWithUnderlyingError:", init_start)
require(init_start != -1 and init_end != -1, "DatabaseManager init boundary is missing.")
initializer = DATABASE[init_start:init_end]

# Simulated crash state: the destination main SQLite file exists, its WAL/SHM may not, and
# the untouched previous-version triplet still exists. A durable marker must make the next
# launch discard that destination before the ordinary destination-exists gate can accept it.
marker_declaration = initializer.find("migrationMarkerURL")
marker_recovery = initializer.find("fileExistsAtPath:migrationMarkerURL.path")
partial_cleanup = initializer.find("_removeIncompleteCopiedStoreAtURL:_databaseURL", marker_recovery)
destination_gate = initializer.find("fileExistsAtPath:[_databaseURL path]", partial_cleanup)
require(-1 < marker_declaration <= marker_recovery < partial_cleanup < destination_gate,
        "An interrupted upgrade must remove the partial destination triplet before its main SQLite file can be accepted.")

marker_write = initializer.find("writeToURL:migrationMarkerURL")
main_copy = initializer.find("copyItemAtURL:urlOfLastDataStoreFile toURL:_databaseURL")
require(-1 < marker_write < main_copy,
        "The durable in-progress marker must be written before the first destination file is copied.")
require("NSDataWritingAtomic" in initializer[marker_write - 300:main_copy],
        "The migration marker must be created atomically so a process kill cannot leave an ambiguous marker.")

store_open = initializer.find("NSManagedObjectContext* startupContext = self.objectContext;")
completion_save = initializer.find("saveReturningError", store_open)
marker_remove = initializer.find("removeItemAtURL:migrationMarkerURL", completion_save)
source_cleanup = initializer.find("[self _deleteObsoleteDataStores]", marker_remove)
require(-1 < store_open < completion_save < marker_remove < source_cleanup,
        "The source store may be deleted only after the copied target opened, saved, and had its in-progress marker cleared.")

migrate_start = DATABASE.find("- (void) _migrateDatabase")
migrate_end = DATABASE.find("- (void) _deleteObsoleteDataStores", migrate_start)
require(migrate_start != -1 and migrate_end != -1, "Database migration boundary is missing.")
require("_deleteObsoleteDataStores" not in DATABASE[migrate_start:migrate_end],
        "Schema/data migration must not delete the source before the target completion save is confirmed.")

print("Database upgrade-copy kill-safety regression checks passed")
