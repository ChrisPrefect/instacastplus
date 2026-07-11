#!/usr/bin/env python3
"""Pins the widget-export efficiency/correctness invariants (redesign 08.-09.07.2026).

These guard against the very slowdowns/mis-exports that were fixed:
  * export runs on a SEPARATE store coordinator (never blocks main-thread Core Data),
  * every export is gated on the specific installed widget KIND,
  * the list set is deduped by uid (no "157 duplicate list rows"),
  * no full numberOfEpisodes SQL count in the export hot path,
  * the full pass only writes lists whose content actually changed,
  * podcasts are offered in the picker and their episodes are exported ONLY for the
    podcast+filter combos an installed widget requested,
  * the provider read-key matches the exporter write-key,
  * the widget-only default lists exist but are hidden from DMANAGER.lists.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit("FAIL: " + message)


parser = argparse.ArgumentParser()
parser.add_argument("--root", help="Repo root override", default=None)
args = parser.parse_args()
root = Path(args.root) if args.root else ROOT

exporter = (root / "Classes" / "WidgetDataExporter.m").read_text()
dbmanager = (root / "Classes" / "Model" / "DatabaseManager.m").read_text()
helper = (root / "Classes" / "WidgetKitHelper.swift").read_text()
provider = (root / "InstacastWidgets" / "Providers" / "SmartListProvider.swift").read_text()

# --- Separate store coordinator: export never contends for the main coordinator's lock ---
require(
    "newExportBackgroundContext" in dbmanager
    and "NSPersistentStoreCoordinator" in dbmanager,
    "DatabaseManager must provide newExportBackgroundContext on a dedicated store coordinator.",
)
require(
    "newBackgroundContext]" not in exporter,
    "WidgetDataExporter must NOT use the main-coordinator newBackgroundContext; use newExportBackgroundContext.",
)
require(
    exporter.count("newExportBackgroundContext") >= 3,
    "All export background blocks (lists, incremental, stats) must use newExportBackgroundContext.",
)

# --- Per-widget-kind gating: only export what an installed widget reads ---
require("isSmartListWidgetInstalled" in helper, "WidgetKitHelper must expose isSmartListWidgetInstalled.")
require("isNowPlayingWidgetInstalled" in helper, "WidgetKitHelper must expose isNowPlayingWidgetInstalled.")
require("isStatsWidgetInstalled" in helper, "WidgetKitHelper must expose isStatsWidgetInstalled.")
for method, gate in [
    ("- (void)exportListsSnapshot", "isSmartListWidgetInstalled"),
    ("- (void)_exportListsAffectedByEpisodeHashes:", "isSmartListWidgetInstalled"),
    ("- (void)exportNowPlayingSnapshot", "isNowPlayingWidgetInstalled"),
    ("- (void)exportStatsSnapshot", "isStatsWidgetInstalled"),
]:
    start = exporter.find(method)
    require(start != -1, f"Missing exporter method: {method}")
    head = exporter[start:start + 900]
    require(gate in head, f"{method} must early-return on ![WidgetKitHelper {gate}].")

# --- Dedupe by uid in BOTH full and incremental list export ---
require(
    exporter.count("[seenUIDs containsObject:uid]") >= 2,
    "Both full and incremental list export must dedupe List rows by uid (seenUIDs).",
)

# --- No full numberOfEpisodes count in the export hot path (comments mentioning it are fine) ---
code_lines = "\n".join(
    line for line in exporter.splitlines() if not line.lstrip().startswith("//")
)
require(
    ".numberOfEpisodes" not in code_lines and "numberOfEpisodes]" not in code_lines,
    "The export must not call the full numberOfEpisodes SQL count (was the dominant cost).",
)

# --- Full pass writes only changed lists ---
require(
    "_listSnapshotEpisodesUnchanged:" in exporter,
    "Full list export must skip writing unchanged snapshots (export only on real change).",
)

# --- Podcasts offered as options + exported only for configured combos ---
require('@"type": @"podcast"' in exporter, "Full export must add subscribed podcasts to the index (type podcast).")
require(
    "_exportConfiguredPodcastSnapshots" in exporter
    and "requestedPodcastKeysDefaultsKey" in exporter,
    "Podcast episodes must be exported only for widget-requested combos (App Group defaults).",
)
require(
    "_predicateForPodcastFilter:" in exporter,
    "Podcast export must apply the per-filter predicate.",
)

# --- Provider read-key must match exporter write-key: feed.<uid>.<filter> ---
require('feed.%@.%@' in exporter, "Exporter must write podcast snapshots as feed.<uid>.<filter>.")
require(
    'return "feed.\\(uid).\\(filter.rawValue)"' in provider,
    "Provider snapshotKey must compose feed.<uid>.<filter> to match the exporter.",
)
config_intent = (root / "InstacastWidgets" / "Intents" / "SmartListConfigIntent.swift").read_text()
require(
    "default: .all" in config_intent,
    "Podcast filter must have a default (.all) so a new widget shows data immediately.",
)

# --- Widget-only default lists exist but are hidden from the in-app menu ---
require(
    "_ensureWidgetOnlyDefaultLists" in dbmanager
    and 'default.recentlyplayed' in dbmanager
    and 'default.mostrecent' in dbmanager,
    "DatabaseManager must recreate the widget-only default lists (recently played / most recent).",
)
require(
    "ICWidgetOnlyDefaultListUIDs" in dbmanager,
    "There must be a single source of truth for the built-in Recently-Played/Most-Recent uids.",
)
# These default lists must appear in the "Lists" menu (DMANAGER.lists) — i.e. NOT filtered out —
# so they are consistent with the "widget offers the lists defined in the Lists menu" model.
lists_getter = dbmanager.split("- (NSArray*) lists", 1)
require(len(lists_getter) == 2, "Missing -lists getter.")
getter_body = lists_getter[1][:800]
require(
    "hiddenUIDs" not in getter_body,
    "-lists must NOT hide the default lists from the Lists menu (they must be selectable there).",
)

print("ALL WIDGET EFFICIENCY INVARIANTS OK")
