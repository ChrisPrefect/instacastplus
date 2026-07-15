#!/usr/bin/env python3
"""Shared source inspection for the EpisodeState off-main regression tests."""

from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SWIFT_PATHS = sorted((ROOT / "Classes").glob("ICiCloudSyncManager*.swift"))
SWIFT_SOURCES = {path: path.read_text() for path in SWIFT_PATHS}


@dataclass(frozen=True)
class SwiftFunction:
    name: str
    declaration: str
    body: str
    path: Path
    start: int


def _matching_brace(source: str, opening_brace: int) -> int:
    depth = 0
    for index in range(opening_brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise AssertionError("Unterminated Swift block")


def _parse_functions() -> list[SwiftFunction]:
    functions: list[SwiftFunction] = []
    pattern = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(")
    for path, source in SWIFT_SOURCES.items():
        for match in pattern.finditer(source):
            opening_brace = source.find("{", match.end())
            if opening_brace == -1:
                continue
            try:
                closing_brace = _matching_brace(source, opening_brace)
            except AssertionError:
                continue
            line_start = source.rfind("\n", 0, match.start()) + 1
            functions.append(
                SwiftFunction(
                    name=match.group(1),
                    declaration=source[line_start:opening_brace],
                    body=source[opening_brace + 1:closing_brace],
                    path=path,
                    start=match.start(),
                )
            )
    return functions


FUNCTIONS = _parse_functions()
FUNCTIONS_BY_NAME: dict[str, list[SwiftFunction]] = {}
for function in FUNCTIONS:
    FUNCTIONS_BY_NAME.setdefault(function.name, []).append(function)


def function(name: str) -> SwiftFunction:
    matches = FUNCTIONS_BY_NAME.get(name, [])
    if not matches:
        raise AssertionError(f"Missing Swift function: {name}")
    if len(matches) != 1:
        raise AssertionError(f"Expected one Swift function named {name}, found {len(matches)}")
    return matches[0]


def called_function_names(body: str) -> set[str]:
    return {
        match.group(1)
        for match in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", body)
        if match.group(1) in FUNCTIONS_BY_NAME
    }


@lru_cache(maxsize=None)
def reachable_function_names(root_name: str) -> set[str]:
    pending = [root_name]
    visited: set[str] = set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        for candidate in FUNCTIONS_BY_NAME.get(name, []):
            pending.extend(called_function_names(candidate.body) - visited)
    return visited


@lru_cache(maxsize=None)
def transitive_source(root_name: str) -> str:
    chunks: list[str] = []
    for name in sorted(reachable_function_names(root_name)):
        for item in FUNCTIONS_BY_NAME.get(name, []):
            chunks.append(item.declaration)
            chunks.append(item.body)
    return "\n".join(chunks)


def episode_background_worker_candidates() -> list[SwiftFunction]:
    candidates: list[SwiftFunction] = []
    for item in FUNCTIONS:
        if "nonisolated" not in item.declaration or "static" not in item.declaration:
            continue
        closure = transitive_source(item.name)
        has_private_context = bool(
            re.search(r"new[A-Za-z0-9_]*BackgroundContext\(\)", closure)
            or ".privateQueueConcurrencyType" in closure
        )
        has_episode_fetch = (
            'entityName: "Episode"' in closure
            or "NSFetchRequest<CDEpisode>" in closure
        )
        has_episode_state = all(token in closure for token in ("consumed", "starred", "position"))
        has_atomic_metadata = "SyncItemMetadata" in closure or "syncItemMetadata" in closure
        if (
            has_private_context
            and has_episode_fetch
            and has_episode_state
            and has_atomic_metadata
            and "context.perform" in closure
            and "context.save()" in closure
        ):
            candidates.append(item)
    return candidates


def common_episode_background_worker() -> SwiftFunction | None:
    roots = (
        "handleFetchedRecordZoneChanges",
        "applyPendingEpisodeStates",
        "handleSentRecordZoneChanges",
    )
    reachable = [reachable_function_names(root) for root in roots]
    shared = [
        candidate
        for candidate in episode_background_worker_candidates()
        if all(candidate.name in names for names in reachable)
    ]
    outermost = [
        candidate
        for candidate in shared
        if not any(
            candidate.name in reachable_function_names(other.name)
            for other in shared
            if other.name != candidate.name
        )
    ]
    if len(outermost) == 1:
        return outermost[0]
    return None


def brace_block_ranges(body: str, prefix_pattern: str) -> list[tuple[int, int]]:
    ranges: list[tuple[int, int]] = []
    for match in re.finditer(prefix_pattern, body):
        opening_brace = body.find("{", match.end())
        if opening_brace == -1:
            continue
        ranges.append((opening_brace, _matching_brace(body, opening_brace)))
    return ranges


def index_is_inside(index: int, ranges: list[tuple[int, int]]) -> bool:
    return any(start <= index <= end for start, end in ranges)
