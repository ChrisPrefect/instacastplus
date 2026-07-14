#!/usr/bin/env python3
"""Pins rollback-safe storage isolation for the compressed FTS schema."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
SYNC_SETTINGS = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = DATABASE.find(signature, DATABASE.find("@implementation DatabaseManager"))
    require(start >= 0, f"Missing method: {signature}")
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


require('kCurrentFTSIndexFilename = @"FTSIndex-v3.sqlite"' in DATABASE,
        "The callback-dependent compressed schema needs its own versioned SQLite filename.")
require('kLegacyFTSIndexFilename = @"FTSIndex.sqlite"' in DATABASE,
        "Rollback cleanup must retain the exact filename understood by the previous build.")

initializer = method_body("- (id) init")
require("kCurrentFTSIndexFilename" in initializer and 'stringByAppendingPathComponent:@"FTSIndex.sqlite"' not in initializer,
        "The current FTS controller must never open or mutate the previous build's index file.")

migration = method_body("- (void) _migrateFTS")
require("_finalizeVersionedFTSMigration" in migration,
        "Both an already-current index and a newly successful rebuild must finalize rollback state and cleanup.")
success = migration.find("if (!error)")
version = migration.find("setInteger:kFTSIndexVersion", success)
finalize = migration.find("_finalizeVersionedFTSMigration", version)
require(-1 < success < version < finalize,
        "Legacy cleanup may run only after the compressed rebuild succeeded and v3 was published.")

cleanup = method_body("- (void)_finalizeVersionedFTSMigration")
legacy_marker = cleanup.find("kDefaultLegacyFTSMigrationDone")
durable_marker = cleanup.find("synchronize", legacy_marker)
legacy_delete = cleanup.find("removeItemAt", durable_marker)
require(-1 < legacy_marker < durable_marker < legacy_delete,
        "Rollback must durably request an old-build rebuild before deleting its readable legacy index.")
for suffix in ('@""', '@"-wal"', '@"-shm"', '@"-journal"', '@".dirty"', '@".rebuild"'):
    require(suffix in cleanup, f"Legacy FTS cleanup is missing sidecar suffix {suffix}.")
require("pathToDocuments" in cleanup and 'pathToSubfolder:@"Data"' in cleanup,
        "Legacy releases stored FTS files in both Documents and Documents/Data; cleanup must cover both.")

require('"FTSIndexVersion"' in SYNC_SETTINGS and '"FTSMigrationDone"' in SYNC_SETTINGS,
        "Both generations of device-local FTS migration state must be excluded from iCloud settings sync.")

print("FTS versioned-storage rollback regression checks passed")
