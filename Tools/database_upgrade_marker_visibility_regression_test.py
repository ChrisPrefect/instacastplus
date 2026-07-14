#!/usr/bin/env python3
"""Pins interrupted database upgrades to the visible migration startup path."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = DATABASE.find("+ (BOOL) dataStoreNeedsMigration\n")
end = DATABASE.find("- (id) init", start)
require(start != -1 and end != -1, "Database migration preflight boundary is missing.")
preflight = DATABASE[start:end]

# Simulated restart after a kill: the current-version SQLite file may already exist and look
# schema-compatible, while the durable marker says its SQLite/WAL/SHM copy is incomplete.
# The scene must still enter the migration UI before DatabaseManager performs recovery work.
marker_path = preflight.find('stringByAppendingString:@".migration-in-progress"')
marker_check = preflight.find("fileExistsAtPath:migrationMarkerURL.path", marker_path)
visible_migration = preflight.find("return YES;", marker_check)
current_store_gate = preflight.find("fileExistsAtPath:[storeURL path]")
require(-1 < marker_path < marker_check < visible_migration < current_store_gate,
        "An in-progress marker must select the visible migration path before the current store is accepted.")

print("Database upgrade-marker visibility regression checks passed")
