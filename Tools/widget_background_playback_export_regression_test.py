#!/usr/bin/env python3
import argparse
import subprocess
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def read_source(source_spec: Optional[str]) -> str:
    if source_spec and ":" in source_spec and not Path(source_spec).exists():
        ref, path = source_spec.split(":", 1)
        return subprocess.check_output(["git", "show", f"{ref}:{path}"], cwd=ROOT, text=True)
    path = Path(source_spec) if source_spec else ROOT / "Classes" / "WidgetDataExporter.m"
    return path.read_text()


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    candidates = []
    for marker in ("\n- (", "\n+ (", "\n#pragma mark"):
        index = source.find(marker, start + len(signature))
        if index > start:
            candidates.append(index)
    end = min(candidates) if candidates else len(source)
    return source[start:end]


parser = argparse.ArgumentParser()
parser.add_argument("--source", help="Path or git ref:path to WidgetDataExporter.m")
args = parser.parse_args()

source = read_source(args.source)

interface = source.split("@implementation WidgetDataExporter", 1)[0]
implementation = source.split("@implementation WidgetDataExporter", 1)[1]
start_observing = method_body(implementation, "- (void)startObserving")
core_data_did_change = method_body(implementation, "- (void)_coreDataDidChange:(NSNotification *)note")
core_data_affects_lists = method_body(implementation, "- (BOOL)_coreDataChangeAffectsLists:(NSNotification *)note")
export_lists = method_body(implementation, "- (void)exportListsSnapshot")
defer_export = method_body(implementation, "- (BOOL)_deferHeavyListsExportInBackgroundPlayback")
flush_deferred = method_body(implementation, "- (void)_flushDeferredExportsOnForeground:(NSNotification *)note")
stats_during_playback = method_body(implementation, "- (void)_refreshStatsDuringPlaybackIfNeeded")

require(
    "@property (nonatomic) BOOL pendingListsExport;" in interface
    and "@property (nonatomic) BOOL pendingStatsRefresh;" in interface,
    "Widget exporter must remember heavy list/stat exports deferred during background playback.",
)

require(
    "_flushDeferredExportsOnForeground:" in start_observing
    and "UIApplicationWillEnterForegroundNotification" in start_observing
    and "UIApplicationDidBecomeActiveNotification" in start_observing,
    "Deferred widget exports must flush when the app returns to foreground/active.",
)

require(
    "_coreDataChangeAffectsLists:note" in core_data_did_change
    and core_data_did_change.find("_coreDataChangeAffectsLists:note") < core_data_did_change.find("dispatch_async(dispatch_get_main_queue()"),
    "Core Data list-affecting keys must be inspected synchronously before changedValuesForCurrentEvent is cleared.",
)

require(
    '"consumed", @"starred", @"archived", @"feed", @"episodeLists"' in method_body(implementation, "+ (NSSet *)_relevantEpisodeKeys")
    and '"position"' not in method_body(implementation, "+ (NSSet *)_relevantEpisodeKeys")
    and "obj.changedValuesForCurrentEvent" in core_data_affects_lists,
    "Playback-position saves must not trigger heavy list exports; only list membership keys should.",
)

require(
    "NSInsertedObjectsKey" in core_data_affects_lists
    and "NSDeletedObjectsKey" in core_data_affects_lists
    and "[obj isKindOfClass:[CDEpisode class]]" in core_data_affects_lists
    and "[obj isKindOfClass:[CDFeed class]]" in core_data_affects_lists
    and "[obj isKindOfClass:[CDList class]]" in core_data_affects_lists,
    "Episode/feed/list inserts and deletes must still refresh widget list snapshots.",
)

require(
    "if (![NSThread isMainThread])" in export_lists
    and "dispatch_async(dispatch_get_main_queue(), ^{ [self exportListsSnapshot]; });" in export_lists,
    "exportListsSnapshot must evaluate UIApplication background/playback state on the main thread.",
)

require(
    "[self _deferHeavyListsExportInBackgroundPlayback]" in export_lists
    and export_lists.find("[self _deferHeavyListsExportInBackgroundPlayback]") < export_lists.find("dispatch_async(self.listsExportQueue"),
    "Heavy list export must be deferred before the background Core Data scan is queued.",
)

require(
    "self.listsExportRunning" in export_lists
    and "self.listsExportQueuedAgain = YES" in export_lists
    and "self.listsExportRunning = NO" in export_lists
    and "[self exportListsSnapshot]" in export_lists.split("self.listsExportRunning = NO", 1)[1],
    "Bursting widget export triggers must coalesce to one in-flight pass plus one trailing rerun.",
)

require(
    "UIApplicationStateActive" in defer_export
    and "pm.playingEpisode == nil || pm.isPaused" in defer_export
    and "self.pendingListsExport = YES" in defer_export
    and '"background-playback"' in defer_export,
    "List exports must defer only while active playback keeps the app alive in the background.",
)

require(
    "self.pendingListsExport = NO" in flush_deferred
    and "[self exportListsSnapshot]" in flush_deferred
    and "self.pendingStatsRefresh = NO" in flush_deferred
    and "[self exportStatsSnapshot]" in flush_deferred,
    "Foreground flush must run both deferred list and stats exports.",
)

require(
    "applicationState != UIApplicationStateActive" in stats_during_playback
    and "self.pendingStatsRefresh = YES" in stats_during_playback
    and stats_during_playback.find("applicationState != UIApplicationStateActive") < stats_during_playback.find("NSDate *now"),
    "Playback stats refresh must defer before running throttled Core Data counts in background playback.",
)


# --- Incremental lists export (User-Vorgabe 08.07.) ------------------------------------
# A changed episode only re-exports the lists it belongs(ed) to (per-list count + limit-14
# fetch) instead of a full all-lists scan per trigger. Playback transitions and small
# consumed/starred toggles use this path; the full exportListsSnapshot stays as periodic
# reconciliation and remains gated during background playback.
incremental = method_body(implementation, "- (void)_exportListsAffectedByEpisodeHashes:")
episode_finish = method_body(implementation, "- (void)_episodeDidFinish:")
episode_change = method_body(implementation, "- (void)_playbackDidChangeEpisode:")
core_data = method_body(implementation, "- (void)_coreDataDidChange:")
require(
    "_exportListsAffectedByEpisodeHashes" in episode_finish
    and "exportListsSnapshot" not in episode_finish
    and "_debouncedListsExport" not in episode_finish,
    "Episode finish must use the incremental per-episode export, never a full lists scan.",
)
require(
    "_exportListsAffectedByEpisodeHashes" in episode_change,
    "Episode change must use the incremental per-episode export.",
)
require(
    "_exportListsAffectedByEpisodeHashes:episodeHashes" in core_data
    and "_debouncedListsReload" in core_data,
    "Small episode updates go incremental; structural changes keep the throttled full reload.",
)
require(
    "_deferHeavyListsExportInBackgroundPlayback" not in incremental,
    "The incremental path is the cheap one — it must not be deferred in background playback.",
)
require(
    "evaluatesEpisodeNow" in incremental and "_episodeHashesInSnapshotFileForListUID" in incremental,
    "Affected lists = episode currently in the snapshot file OR newly matching the list filter.",
)
require(
    "sortedEpisodesWithLimit:kMaxEpisodesPerList" in method_body(implementation, "- (void)_buildSnapshotForList:")
    and "_episodeDictForEpisode" in method_body(implementation, "- (void)_buildSnapshotForList:"),
    "The per-list builder must stay in sync with the full pass (limit + shared episode dict).",
)
