#!/usr/bin/env python3
"""Pins type-safe handling of a syntactically valid migration marker at startup."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def braced_block(source: str, start: int) -> str:
    brace = source.find("{", start)
    require(brace >= 0, "Missing block body")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError("Unterminated block")


implementation = DATABASE.find("@implementation DatabaseManager")
initializer_start = DATABASE.find("- (id) init", implementation)
require(initializer_start >= 0, "DatabaseManager initializer is missing")
initializer = braced_block(DATABASE, initializer_start)

migration_start = initializer.find("if (migrationInProgress)")
require(migration_start >= 0, "Database startup migration-marker branch is missing")
migration = braced_block(initializer, migration_start)

marker_read = migration.find("_readDataStoreMigrationMarkerWithError")
type_gate = migration.find("BOOL markerHasValidTypes")
require(marker_read >= 0 and type_gate > marker_read,
        "Startup must validate the parsed migration marker before using its values.")

required_type_checks = [
    "[marker[ICDataStoreMigrationPhaseKey] isKindOfClass:NSString.class]",
    "[marker[ICDataStoreMigrationSourcePathKey] isKindOfClass:NSString.class]",
    "[marker[ICDataStoreMigrationTargetPathKey] isKindOfClass:NSString.class]",
    "[marker[ICDataStoreMigrationFormatVersionKey] isKindOfClass:NSNumber.class]",
    "[marker[ICDataStoreMigrationGenerationKey] isKindOfClass:NSNumber.class]",
    "[marker[ICDataStoreMigrationEntityCountsKey] isKindOfClass:NSDictionary.class]",
    "[marker[ICDataStoreMigrationTargetStoreUUIDKey] isKindOfClass:NSString.class]",
]
for check in required_type_checks:
    require(check in migration, f"Migration marker startup gate is missing: {check}")

failure_gate = migration.find("if (!markerHasValidTypes)", type_gate)
require(failure_gate > type_gate,
        "A marker with valid plist syntax but wrong field types must enter an explicit failure path.")
failure = braced_block(migration, failure_gate)
require("self.initializationError" in failure and "return self;" in failure,
        "A malformed marker must produce initializationError instead of continuing into startup.")
for destructive_call in [
    "_writeDataStoreMigrationMarker",
    "_removePreparedDataStoreAtURL",
    "removeItemAtURL",
    "_deleteObsoleteDataStores",
]:
    require(destructive_call not in failure,
            f"Malformed-marker failure must preserve marker/source/target; found {destructive_call}.")

first_path_use = migration.find("_dataStoreURLForRelativePath", marker_read)
first_phase_use = migration.find("isEqualToString", marker_read)
first_number_use = migration.find("integerValue", marker_read)
require(type_gate < failure_gate < first_path_use,
        "sourcePath/targetPath must be NSString-validated before path resolution.")
require(type_gate < failure_gate < first_phase_use,
        "phase must be NSString-validated before isEqualToString:.")
require(type_gate < failure_gate < first_number_use,
        "formatVersion/generation must be NSNumber-validated before integerValue.")

prepare_start = DATABASE.find("+ (BOOL)_prepareDataStoreMigrationWithError:", implementation)
require(prepare_start >= 0, "Database migration preparation method is missing")
prepare = braced_block(DATABASE, prepare_start)
prepared_type_gate = prepare.find("BOOL preparedMarkerHasValidTypes")
committing_branch = prepare.find("ICDataStoreMigrationPhaseCommitting", prepared_type_gate)
first_prepared_validation = prepare.find("_validatePreparedStoreAtURL", prepared_type_gate)
require(-1 < prepared_type_gate < committing_branch < first_prepared_validation,
        "The asynchronous preparation path must type-check phase-specific fields before validating a prepared store.")
for check in [
    "[markerTargetStoreUUID isKindOfClass:NSString.class]",
    "[markerEntityCounts isKindOfClass:NSDictionary.class]",
]:
    require(check in prepare[prepared_type_gate:first_prepared_validation],
            f"Prepared migration-marker gate is missing: {check}")
require("if (!preparedMarkerHasValidTypes)" in prepare[prepared_type_gate:first_prepared_validation],
        "Malformed ready/committing marker fields need an explicit non-destructive error path.")
require("expectedStoreUUID:markerTargetStoreUUID" in prepare,
        "The committing path must pass only the already NSString-validated target UUID.")

print("Database migration-marker type regression checks passed")
