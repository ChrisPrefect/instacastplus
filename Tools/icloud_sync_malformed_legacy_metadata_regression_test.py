#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require('legacySyncItemMetadataErrorDomain = "ICiCloudSyncLegacyMetadata"' in MANAGER,
        "Malformed legacy metadata needs a distinct deterministic error classification.")

reader = method_body(METADATA, "nonisolated static func legacySyncItemMetadataWrites")
require("legacySyncItemMetadataError" in reader,
        "Malformed legacy plists, wrong dictionary types and contradictory identities need one explicit error.")
legacy_error = method_body(METADATA, "nonisolated static func legacySyncItemMetadataError")
require("NSUnderlyingErrorKey" in legacy_error
        and "underlyingError: error" in reader,
        "A malformed plist must retain its parser error for diagnostics.")

classifier = method_body(METADATA, "nonisolated static func isDeterministicLegacySyncItemMetadataError")
require("legacySyncItemMetadataErrorDomain" in classifier,
        "The retry layer must be able to identify deterministic legacy corruption exactly.")

migration_classifier = method_body(
    METADATA,
    "nonisolated static func isDeterministicSyncItemMetadataMigrationError",
)
require('domain == "ICiCloudSyncItemMetadata"' in migration_classifier
        and "code == 2" in migration_classifier
        and "code == 3" in migration_classifier,
        "Only indexed-row validation/identity collisions are deterministic migration corruption.")
migration = method_body(METADATA, "func migrateLegacySyncItemMetadataIfNeeded")
require("isDeterministicSyncItemMetadataMigrationError(error)" in migration
        and "legacySyncItemMetadataError(underlyingError: error)" in migration
        and "throw error" in migration,
        "Partial legacy migration must wrap deterministic row collisions while preserving retryable I/O/save errors.")


def is_deterministic_partial_migration_error(domain, code):
    return domain == "ICiCloudSyncItemMetadata" and code in (2, 3)


require(is_deterministic_partial_migration_error("ICiCloudSyncItemMetadata", 2)
        and is_deterministic_partial_migration_error("ICiCloudSyncItemMetadata", 3),
        "Malformed and contradictory indexed rows must stop automatic migration retries.")
require(not is_deterministic_partial_migration_error("ICiCloudSyncItemMetadata", 1)
        and not is_deterministic_partial_migration_error("ICiCloudSyncItemMetadata", 4)
        and not is_deterministic_partial_migration_error("NSCocoaErrorDomain", 3),
        "Context-open, source-removal and Core Data save/I/O failures must remain retryable.")

retry = method_body(MANAGER, "func scheduleSyncRetryAfterFailure(error:")
require("isDeterministicLegacySyncItemMetadataError" in retry
        and retry.find("isDeterministicLegacySyncItemMetadataError")
            < retry.find("scheduleSyncRetryAfterFailure(code:"),
        "Deterministic malformed metadata must stop before the exponential retry scheduler.")

display = method_body(METADATA, "func displayStatus(for error:")
require("isDeterministicLegacySyncItemMetadataError" in display
        and "localizedDescription" in display,
        "The UI must show the specific complete corruption/recovery message, not a generic iCloud failure.")

print("iCloud malformed legacy-metadata regression checks passed")
