#!/usr/bin/env python3
"""Prevents managed-object callbacks from opening the app database during store migration."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "Classes" / "Model"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


for filename in (
    "CDEpisodeList.m",
    "CDPlaylist.m",
    "CDPlaylistEpisode.m",
    "CDSmartPlaylist.m",
):
    source = (MODEL_DIR / filename).read_text()
    for signature in ("- (void) awakeFromFetch", "- (void) awakeFromInsert"):
        body = method_body(source, signature)
        require(
            "DMANAGER" not in body and "sharedDatabaseManager" not in body,
            f"{filename} {signature} recursively opens DatabaseManager while Core Data migrates the store.",
        )
        require(
            "NSMainQueueConcurrencyType" in body,
            f"{filename} {signature} must identify UI-owned objects from their existing context without a global singleton.",
        )

episode_list = (MODEL_DIR / "CDEpisodeList.m").read_text()
for signature in ("- (NSUInteger) numberOfEpisodes", "- (void) calculateNumberOfEpisodesCompletion:"):
    body = method_body(episode_list, signature)
    require(
        "DMANAGER.objectContext" not in body and "sharedDatabaseManager" not in body,
        f"CDEpisodeList {signature} must not initialize DatabaseManager merely to classify its existing context.",
    )
    require(
        "NSMainQueueConcurrencyType" in body,
        f"CDEpisodeList {signature} must classify its existing context without consulting DatabaseManager.",
    )

print("Database migration managed-object reentrancy regression checks passed")
