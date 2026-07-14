#!/usr/bin/env python3
"""Pins durable incremental removal of auto-download history values."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "ICCacheHistory.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.index(signature)
    brace = SOURCE.index("{", start)
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


reset_episode = body("- (void)resetValuesForEpisode:")
reset_batch = body("- (void)resetValuesForEpisodes:")
delete_hashes = body("- (NSError*)_deleteEpisodeHashes:")

require("didAutoDownload:NO" in reset_episode,
        "Single-episode reset must use the same durable incremental mutation path.")
require("dispatch_async(self.persistenceQueue" in reset_batch and
        "mutationGenerations" in reset_batch and "pendingValues" in reset_batch,
        "A feed-wide reset must be ordered off-main and reject stale completions.")
require("BEGIN IMMEDIATE TRANSACTION" in delete_hashes and
        "DELETE FROM" in delete_hashes and "COMMIT" in delete_hashes,
        "Feed-wide reset must durably delete all requested hashes in one transaction.")

print("Download cache-history persistence regression checks passed")
