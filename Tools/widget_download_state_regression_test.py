#!/usr/bin/env python3
"""Pins widgets to the thread-safe authoritative download snapshot."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "WidgetDataExporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("cachedEpisodeObjectHashes" in SOURCE,
        "Widget exports must use the immutable hash snapshot instead of main-context managed objects.")
require('valueForKey:@"objectHash"' not in SOURCE,
        "A background widget export must never iterate CacheManager.cachedEpisodes managed objects.")
require('predicateWithFormat:@"downloaded == YES"' not in SOURCE,
        "Widget stats cannot query a transient Core Data attribute from a background store context.")
require("downloadedCountSnapshot" in SOURCE and
        "downloadedSizeSnapshot" in SOURCE,
        "Count and bytes should come from one authoritative CacheManager snapshot before background export.")
require('@(episode.downloaded)' not in SOURCE,
        "Widget episode payloads must not serialize the transient Core Data downloaded flag.")
require("cachedEpisodeHashes:(NSSet<NSString *> *)cachedEpisodeHashes" in SOURCE and
        "[cachedEpisodeHashes containsObject:episode.objectHash]" in SOURCE,
        "Every widget episode payload must derive its downloaded badge from the authoritative hash snapshot.")

print("Widget download-state regression checks passed")
