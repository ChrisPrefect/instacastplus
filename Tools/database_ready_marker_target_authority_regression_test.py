#!/usr/bin/env python3
"""Pins a verified ready target as newer than its retained legacy migration source."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    implementation = DATABASE.find("@implementation DatabaseManager")
    start = DATABASE.find(signature, implementation)
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


prepare = method_body("+ (BOOL)_prepareDataStoreMigrationWithError:")
prepared_validation = prepare.find("if ([phase isEqualToString:ICDataStoreMigrationPhaseCommitting] ||")
ready_in_validation = prepare.find("[phase isEqualToString:ICDataStoreMigrationPhaseReady]", prepared_validation)
identity_validation = prepare.find("expectedCounts:nil", ready_in_validation)
ready_rebuild = prepare.find("if ([phase isEqualToString:ICDataStoreMigrationPhaseReady])", identity_validation)
require(
    -1 < prepared_validation < ready_in_validation < identity_validation < ready_rebuild,
    "A ready target must first be accepted by store identity, integrity, and current-model validation without comparing stale row counts.",
)

authoritative_branch = prepare[prepared_validation:ready_rebuild]
require(
    "expectedCounts:markerEntityCounts" not in authoritative_branch,
    "Rows legitimately written after a ready marker must not make the app rebuild from the older source store.",
)
require(
    "_lightweightMigrateCurrentDataStoreAtURL:targetURL" in authoritative_branch,
    "A ready target from an older app model must be upgraded in place instead of being replaced by its legacy source.",
)

print("Database ready-marker target-authority regression checks passed")
