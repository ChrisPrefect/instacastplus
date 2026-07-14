#!/usr/bin/env python3
"""Pins validation/replacement when a streaming import finds an existing target."""
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing method body: {signature}")
        if SOURCE.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


internal_import = body("- (void)_importFileAtURL:")
file_phase = internal_import.split("dispatch_async(_cacheDeletionQueue", 1)[1]
file_phase = file_phase.split("dispatch_async(dispatch_get_main_queue()", 1)[0]
require(
    "sourceFileSize" in file_phase
    and "existingDestinationIsComplete" in file_phase
    and "destinationFileSize == sourceFileSize" in file_phase
    and "NSFileTypeRegular" in file_phase,
    "An existing destination is a cache hit only when it is a non-empty complete regular file matching the validated source.",
)
require(
    "replaceItemAtURL:cachedURL" in file_phase
    and "withItemAtURL:url" in file_phase,
    "An empty/truncated existing destination must be atomically replaced by the validated stream source.",
)
require(
    "BOOL success = createdDestination || existingDestinationIsComplete" in file_phase,
    "File existence alone must never turn a failed streaming move into success.",
)
require(
    "if (!sourceIsRegularFile && !error)" in file_phase,
    "An empty or non-regular completed stream must fail with a concrete error instead of (NO, nil).",
)

print("Download existing-destination validation regression checks passed")
