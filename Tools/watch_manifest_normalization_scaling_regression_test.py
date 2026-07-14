#!/usr/bin/env python3
"""Pins linear Watch manifest normalization and bounded bulk diagnostics."""

from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "InstacastWatch" / "WatchManifestStore.swift").read_text()
EPISODE_COUNT = 4_500


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


@dataclass(frozen=True)
class Identity:
    episode_hash: str
    media_url: str
    local_file_url: str


identities = [Identity(f"episode-{index}", f"https://media/{index}", f"/old/{index}")
              for index in range(EPISODE_COUNT)]
changes = list(identities)

# This is the work performed by the old nested scan: every change compares every
# manifest row because all exact duplicates have to be updated.
nested_comparisons = 0
for change in changes:
    for episode in identities:
        nested_comparisons += 1
        _ = episode == change
require(nested_comparisons == EPISODE_COUNT * EPISODE_COUNT == 20_250_000,
        "The 4,500-row fixture must expose the former quadratic 20.25M comparisons.")

# The production contract: build the identity index once, then do one constant-time
# lookup per change while retaining support for exact duplicate rows.
index_visits = 0
indices_by_identity: dict[Identity, list[int]] = {}
for index, episode in enumerate(identities):
    index_visits += 1
    indices_by_identity.setdefault(episode, []).append(index)
lookup_count = 0
applied_count = 0
for change in changes:
    lookup_count += 1
    applied_count += len(indices_by_identity.get(change, []))
require(index_visits == EPISODE_COUNT and lookup_count == EPISODE_COUNT and
        applied_count == EPISODE_COUNT,
        "Normalization must do one index pass and one O(1) lookup per change.")

# Diagnostics are bulk facts, not an event/outbox write for every affected episode.
categories = ["rerooted" if index % 2 == 0 else "missing"
              for index in range(EPISODE_COUNT)]
diagnostic_events = list(dict.fromkeys(categories))
require(len(diagnostic_events) == 2,
        "A 4,500-change batch must emit at most one diagnostic per category.")

require("private struct WatchManifestNormalizationIdentity: Hashable" in SOURCE,
        "Normalization needs a hashable identity for constant-time change lookup.")
apply_body = block_after(SOURCE, "private func applyNormalizationResult(")
change_loop_position = apply_body.find("for change in result.changes")
index_position = apply_body.find("indicesByIdentity")
require(index_position != -1 and change_loop_position != -1 and index_position < change_loop_position,
        "Build one episode identity index before applying normalization changes.")
change_loop_and_after = apply_body[change_loop_position:]
require(("indicesByIdentity[identity]" in change_loop_and_after or
         "indicesByIdentity.removeValue(forKey: identity)" in change_loop_and_after) and
        "for index in nextEpisodes.indices where" not in change_loop_and_after,
        "Each normalization change must use the prebuilt index, not rescan all episodes.")

diagnostics_body = block_after(SOURCE, "private func logNormalizationChanges(")
per_change_body = block_after(diagnostics_body, "for change in changes")
require("WatchDiagnostics.log(" not in per_change_body,
        "Per-change work may aggregate metadata but must not send diagnostics.")
require(diagnostics_body.count("WatchDiagnostics.log(") == 2 and
        'metadata["changeCount"]' in diagnostics_body,
        "The batch must send at most one counted diagnostic for rerooted and missing files.")

print("Watch manifest normalization scaling regression checks passed")
