#!/usr/bin/env python3
"""Pins the authoritative source for an upgrade interrupted by the previous release."""

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
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(DATABASE)):
        if DATABASE[index] == "{":
            depth += 1
        elif DATABASE[index] == "}":
            depth -= 1
            if depth == 0:
                return DATABASE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


resolver = method_body("+ (NSURL*)_authoritativeSourceDataStoreURLWithError:")
require(
    "_urlOfLastDataStoreFile" in resolver
    and "_legacyMigrationSourceURLForTargetURL" in resolver,
    "Source selection must inspect the previous release's marker before accepting the highest existing generation.",
)
require(
    "visitedPaths" in resolver,
    "Recursive legacy-marker resolution must reject marker cycles instead of following untrusted paths forever.",
)

legacy_marker = method_body("+ (NSURL*)_legacyMigrationSourceURLForTargetURL:")
require(
    'stringByAppendingString:@".migration-in-progress"' in legacy_marker
    and "NSUTF8StringEncoding" in legacy_marker,
    "The last App Store release wrote the authoritative source as a plain UTF-8 target marker.",
)
require(
    'rangeOfString:@"/Documents/"' in legacy_marker
    and "pathToDocuments" in legacy_marker,
    "Legacy absolute marker paths must be rebased to the current app container after restore/reinstall.",
)
require(
    "_validatedLegacyDataStoreURL" in legacy_marker,
    "A legacy marker may only resolve to an exact supported older DataStore file inside Documents.",
)

prepare = method_body("+ (BOOL)_prepareDataStoreMigrationWithError:")
require(
    "_authoritativeSourceDataStoreURLWithError" in prepare,
    "DataStore6 preparation must use the marker-resolved authoritative source, not the partial predecessor target.",
)

validator = method_body("+ (NSURL*)_validatedLegacyDataStoreURL:")
generation_parser = method_body("+ (NSInteger)_dataStoreGenerationForURL:")
require(
    "URLIsSymbolicLinkKey" in validator
    and "regularExpressionWithPattern" in generation_parser,
    "Migration sources must be exact legacy DataStore files and must not be symbolic links.",
)

print("Legacy migration-marker source regression checks passed")
