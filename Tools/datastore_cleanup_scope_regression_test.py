#!/usr/bin/env python3
"""Pins deletion to exact obsolete Core Data generation filenames."""

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


filenames = method_body("+ (NSSet<NSString*>*)_obsoleteDataStoreFilenames")
require(
    "generation < DATA_STORE_GENERATION" in filenames,
    "Cleanup must enumerate only generations older than the current store.",
)
for suffix in ('@""', '@"-wal"', '@"-shm"', '@"-journal"', '@".migration-in-progress"'):
    require(suffix in filenames, f"Cleanup must explicitly cover the known SQLite companion suffix {suffix}.")
require(
    '@"DataStore.sqlite"' in filenames,
    "The unversioned legacy store must be included explicitly.",
)

cleanup = method_body("- (void) _deleteObsoleteDataStores")
item_validation = method_body("+ (BOOL)_isRemovableObsoleteDataStoreItemAtURL:")
require(
    "_obsoleteDataStoreFilenames" in cleanup
    and "containsObject:file" in cleanup,
    "Cleanup must delete only exact names from the obsolete-generation set.",
)
require(
    'hasPrefix:@"DataStore"' not in cleanup
    and 'rangeOfString:@".sqlite"' not in cleanup,
    "Wildcard matching can delete user backups or a future store generation.",
)
require(
    "NSURLIsRegularFileKey" in item_validation
    and "NSURLIsSymbolicLinkKey" in item_validation
    and "_isRemovableObsoleteDataStoreItemAtURL" in cleanup,
    "Even an exact reserved name may be removed only when it is a regular, non-symlink file; directories must never be deleted recursively.",
)

print("DataStore cleanup scope regression checks passed")
