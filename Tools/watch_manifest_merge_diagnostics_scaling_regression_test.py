#!/usr/bin/env python3
"""Pins bounded Watch manifest merge diagnostics for 4,500-entry operations."""

from collections import Counter
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
ENTRY_COUNT = 4_500
MERGE_CATEGORY_COUNT = 3


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def block_after(source: str, marker: str) -> str:
    start = source.find(marker)
    require(start != -1, f"Missing source marker: {marker}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing block after: {marker}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated block after: {marker}")


categories = (
    "download-reset",
    "media-url-changed",
    "local-file-state-changed",
)
decisions = [categories[index % MERGE_CATEGORY_COUNT] for index in range(ENTRY_COUNT)]

# The old implementation emitted one reliable diagnostic (and therefore one
# offline outbox revision) for every relevant merge.
old_event_count = sum(1 for _ in decisions)
require(old_event_count == ENTRY_COUNT,
        "The deterministic fixture must expose 4,500 former per-entry events.")

# A replace or upsert operation accumulates counts and retains one sample per
# finite category. This makes the exact bound independent of entry count.
aggregates = Counter(decisions)
bulk_events = [(category, aggregates[category]) for category in categories
               if aggregates[category] > 0]
require(len(bulk_events) == MERGE_CATEGORY_COUNT and
        sum(count for _, count in bulk_events) == ENTRY_COUNT and
        all(count == 1_500 for _, count in bulk_events),
        "A mixed 4,500-entry operation must emit exactly three counted bulk events.")


def emitted_event_count(batch: list[str]) -> int:
    counts = Counter(batch)
    return sum(1 for category in categories if counts[category] > 0)


require(emitted_event_count(decisions) == 3 and
        emitted_event_count([categories[0]] * ENTRY_COUNT) == 1 and
        emitted_event_count([]) == 0,
        "The event bound must naturally shrink to one or zero for sparse operations.")

enum_marker = "private enum WatchManifestMergeDiagnosticCategory: String, CaseIterable"
require(enum_marker in SOURCE,
        "Merge diagnostics need a finite category set to enforce the event bound.")
category_body = block_after(SOURCE, enum_marker)
require(category_body.count("case ") == MERGE_CATEGORY_COUNT,
        "The production merge diagnostic bound must remain exactly three categories.")

record_body = block_after(SOURCE, "private nonisolated static func recordMergeDecision(")
require("WatchDiagnostics.log(" not in record_body and
        "diagnostics[category]" in record_body,
        "The per-entry merge pass may only update an in-memory category aggregate.")

log_body = block_after(SOURCE, "private func logMergeDecisions(")
require("for category in WatchManifestMergeDiagnosticCategory.allCases" in log_body and
        log_body.count("WatchDiagnostics.log(") == 1 and
        'metadata["changeCount"]' in log_body and
        'prefix: "sample."' in log_body,
        "Bulk logging must send once per finite category with a count and one bounded sample.")

replace_body = block_after(SOURCE, "func applyManifest(")
upsert_body = block_after(SOURCE, "func upsert(entries:")
planner_body = block_after(SOURCE, "private nonisolated static func buildManifestMergePlan(")
require(planner_body.count("recordMergeDecision(") == 2 and
        "WatchDiagnostics.log(" not in planner_body,
        "Both detached merge modes must aggregate decisions without emitting per-entry diagnostics.")
for operation, body in (("replace", replace_body), ("upsert", upsert_body)):
    require(body.count("recordMergeDecision(") == 0 and
            body.count("logMergeDecisions(") == 1 and
            body.find("currentManifestMergePlan(") < body.find("logMergeDecisions("),
            f"Manifest {operation} must receive its detached aggregate and flush it once.")

require("private func logMergeDecision(" not in SOURCE,
        "The former per-entry logging helper must not remain reachable.")

print("Watch manifest merge diagnostic scaling regression checks passed")
