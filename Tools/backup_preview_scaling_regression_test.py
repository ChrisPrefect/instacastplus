#!/usr/bin/env python3
"""Pins background, indexed analysis of large backup previews."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("analysisInProgress" in SOURCE,
        "The import screen needs an explicit loading state while preview analysis is running.")
require("newExportBackgroundContext" in SOURCE and "performBlock:" in SOURCE,
        "Backup preview Core Data reads must run on the isolated read-only background context.")
require('initWithEntityName:@"Feed"' in SOURCE and 'initWithEntityName:@"Episode"' in SOURCE,
        "Preview analysis must batch-fetch feeds and matching episodes instead of faulting relationships per item.")
require('guid IN %@' in SOURCE,
        "Episode preview lookups must use bounded indexed GUID batches.")
require("episodeStatesByFeedURL" in SOURCE and "bookmarkPositionsByEpisode" in SOURCE,
        "Episode and bookmark comparisons must use prebuilt lookup indexes, not nested scans.")
require("ICBackupPreviewStringValue" in SOURCE and "ICBackupPreviewNumberValue" in SOURCE,
        "Optional dictionary-fetch values must reject NSNull instead of messaging it as NSString/NSNumber.")
require("MIN([existingState[@\"position\"] integerValue], episode.position)" in SOURCE and
        "[existingState[@\"consumed\"] boolValue] && episode.consumed" in SOURCE,
        "Duplicate local feed/GUID rows must aggregate the state that any imported row would change.")
require("dispatch_get_main_queue()" in SOURCE and "applyAnalysisResult" in SOURCE,
        "Only the finished scalar preview result may return to the main thread for UI updates.")
require("QOS_CLASS_USER_INITIATED" in SOURCE,
        "Visible preview work should not sit behind unrelated utility jobs while the user waits.")

analysis_start = SOURCE.find("- (void)analyzeBackup")
analysis_end = SOURCE.find("- (void)initializeSelectedCategories", analysis_start)
require(analysis_start != -1 and analysis_end != -1, "Missing analyzeBackup method.")
analysis = SOURCE[analysis_start:analysis_end]
require("feedWithSourceURL" not in analysis and "feed.episodes" not in analysis and "DMANAGER.bookmarks" not in analysis,
        "The UI analysis path must not call linear main-context helpers or traverse full relationships.")
require("UIActivityIndicatorView" in SOURCE and '"Analyzing backup…".ls' in SOURCE,
        "The import button must explain the temporary loading state instead of appearing unresponsive.")
require("analysisError" in SOURCE
        and '"The backup could not be analyzed. No data was changed. Check the available storage and try again.".ls' in SOURCE
        and '"Try Again".ls' in SOURCE,
        "A failed preview read must provide a visible retry path without enabling an unsafe import.")

print("Backup preview scaling regression checks passed")
