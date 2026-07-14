#!/usr/bin/env python3
"""Pins incremental widget exports when the changed episode row is already deleted."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "WidgetDataExporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("- (void)_exportListsAffectedByEpisodeHashes:")
require(start != -1, "Missing incremental widget list exporter.")
brace = SOURCE.find("{", start)
depth = 0
end = None
for index in range(brace, len(SOURCE)):
    if SOURCE[index] == "{":
        depth += 1
    elif SOURCE[index] == "}":
        depth -= 1
        if depth == 0:
            end = index
            break
require(end is not None, "Unterminated incremental widget list exporter.")
body = SOURCE[brace + 1:end]

require("requestedEpisodeHashes" in body and
        "intersectsSet:requestedEpisodeHashes" in body,
        "A deleted episode must still invalidate every snapshot file that currently contains its hash.")
require("if (episodes.count == 0) return" not in body,
        "Missing Core Data rows are the deletion signal, not a reason to keep stale widget rows.")
require("objectHash IN %@" in body and body.count("executeFetchRequest:episodeRequest") == 1,
        "Incremental updates must resolve all surviving changed episodes in one indexed fetch.")

print("Widget deleted-episode snapshot regression checks passed")
