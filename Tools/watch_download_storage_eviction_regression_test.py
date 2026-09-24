#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated function body: {signature}")


storage = read("InstacastWatch/WatchStorageManager.swift")
free_bytes = function_body(storage, "func freeBytes(")
total_bytes = function_body(storage, "func totalBytes(")
int64_volume_resource_value = function_body(storage, "private nonisolated static func int64VolumeResourceValue(")

require(
    "volumeAvailableCapacityForImportantUsageKey" not in storage
    and "int64VolumeResourceValue(for: .volumeAvailableCapacityKey)" in free_bytes
    and "volumeAvailableCapacity ??" not in free_bytes
    and "max(0," in free_bytes,
    "freeBytes() must read volumeAvailableCapacityKey as the underlying NSNumber Int64. "
    "On watchOS arm64_32 the typed URLResourceValues.volumeAvailableCapacity is Int-sized and "
    "truncated multi-GB values into negatives, making every storage check refuse downloads "
    "('Speicher voll', 0 loaded). volumeAvailableCapacityForImportantUsageKey is unavailable on watchOS.",
)

require(
    "int64VolumeResourceValue(for: .volumeTotalCapacityKey)" in total_bytes
    and "getResourceValue" in int64_volume_resource_value
    and "NSNumber" in int64_volume_resource_value
    and ".int64Value" in int64_volume_resource_value,
    "Watch storage capacity must be read from NSURL resource values as NSNumber.int64Value, not "
    "through Swift URLResourceValues Int properties that truncate on watchOS arm64_32.",
)

print("Watch 64-bit storage-capacity API checks passed")
