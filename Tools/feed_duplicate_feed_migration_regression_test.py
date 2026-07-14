#!/usr/bin/env python3
"""Pins lossless startup consolidation of duplicate subscribed feeds."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
MODEL = (
    ROOT
    / "Resources"
    / "Models"
    / "Model5.xcdatamodeld"
    / "Model6.xcdatamodel"
    / "contents"
).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require('relationship name="episodes"' in MODEL and 'deletionRule="Cascade"' in MODEL,
        "The active model must keep the Feed-to-Episode cascade risk visible to this test.")
require('relationship name="properties"' in MODEL and 'deletionRule="Cascade"' in MODEL,
        "The active model must keep the Feed-to-Property cascade risk visible to this test.")

migration = method_body("- (void) _migrateRemoveDuplicateFeeds")
require("normalizedFeedURLStringForURLString" in migration,
        "Duplicate grouping must normalize case and harmless trailing-slash URL variants.")
require("duplicate.episodes" in migration and "episode.feed = keeper" in migration,
        "Every episode must be reparented before deleting its duplicate feed.")
require("duplicate.properties" in migration and "property.feed = keeper" in migration,
        "Podcast settings absent on the keeper must survive the duplicate-feed cascade.")
require("duplicate.episodeLists" in migration and "includedFeeds" in migration,
        "Custom list feed membership must move to the keeper before duplicate deletion.")
require("duplicate.categories" in migration and "category.feed = keeper" in migration,
        "Feed categories must survive the duplicate-feed cascade.")

reparent_episode = migration.find("episode.feed = keeper")
reparent_property = migration.find("property.feed = keeper")
merge_lists = migration.find("includedFeeds")
reparent_category = migration.find("category.feed = keeper")
delete_feed = migration.find("deleteObject:duplicate")
require(min(reparent_episode, reparent_property, merge_lists, reparent_category) >= 0 and
        max(reparent_episode, reparent_property, merge_lists, reparent_category) < delete_feed,
        "All cascade-owned/user-facing relationships must be preserved before deleting the feed row.")
require("deleteObject:episode" not in migration and "deleteEpisodes:" not in migration,
        "Startup migration must not hard-delete duplicate episode identities without lifecycle cleanup.")

print("Duplicate-feed migration regression checks passed")
