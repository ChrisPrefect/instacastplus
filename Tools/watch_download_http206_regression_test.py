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


download = read("InstacastWatch/WatchDownloadManager.swift")
validation = function_body(download, "private func downloadValidationError(")

require(
    "isCompletePartialContentResponse" in download
    and 'value(forHTTPHeaderField: "Content-Range")' in download,
    "Watch download validation must inspect Content-Range before deciding whether HTTP 206 is incomplete.",
)

partial_error = validation.find("Download unvollständig: HTTP 206 Partial Content")
size_lookup = validation.find("FileManager.default.attributesOfItem")
require(
    partial_error != -1 and size_lookup != -1 and size_lookup < partial_error,
    "Watch download validation must measure the staged file before rejecting HTTP 206 as incomplete.",
)

require(
    "totalSize == actualSize" in download
    and "lowerBound == 0" not in download,
    "HTTP 206 validation must accept a resumed 206 by the reassembled file matching the resource's total size. "
    "Requiring the range to start at byte 0 (lowerBound == 0) rejects every resumed background download — exactly "
    "the case that produces 206 in the field — so that constraint must not return.",
)

require(
    "httpResponse.statusCode == 206" in validation
    and "isCompletePartialContentResponse(httpResponse, actualSize: size)" in validation,
    "HTTP 206 responses must be rejected only when their byte range does not cover the full downloaded file.",
)

print("Watch HTTP 206 download regression checks passed.")
