#!/usr/bin/env python3
"""Pins a backup-scoped, bounded GUID index for metadata import."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
IMPORT_UI = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("_buildGuidIndexForBackup:" in SOURCE and "categories:(ICBackupImportCategory)categories" in SOURCE,
        "GUID indexing must know the selected backup/categories instead of scanning the whole database.")
require("episodeLookupCategories" in SOURCE and "if (!(categories & episodeLookupCategories))" in SOURCE,
        "A settings-only import must skip episode indexing entirely.")
require("candidateGUIDs" in SOURCE and "episodeFetchBatchSize" in SOURCE and 'guid IN %@' in SOURCE,
        "Only backup-referenced GUIDs may be fetched, in bounded indexed batches.")
require('guid != nil AND feed.sourceURL_ != nil' not in SOURCE,
        "The importer must never rebuild its lookup by fetching every local episode.")
require("executeFetchRequest:request error:&fetchError" in SOURCE and
        "NSUnderlyingErrorKey: fetchError" in SOURCE and "if (guidIndexError)" in SOURCE,
        "A failed index fetch must stop the import with its real underlying error, not produce a partial index.")
require("terminalError:" in SOURCE and "completion(totalImported, queuedDownloadCount, finalError)" in SOURCE,
        "The index error must reach the public import completion instead of being reported as success.")
require("else if (error)" in IMPORT_UI and 'alertControllerWithTitle:@"Import Error".ls' in IMPORT_UI,
        "A non-cancellation import failure must stay visible in an error alert and must not say Import Complete.")

resolver_start = SOURCE.find("+ (NSString *)_resolvedFeedURLForBackupURL:")
resolver_end = SOURCE.find("#pragma mark - Episode Status", resolver_start)
resolver = SOURCE[resolver_start:resolver_end]
require("feedWithSourceURL" not in resolver,
        "An authoritative built index must not fall back to a per-miss linear main-context feed scan.")

finder_start = SOURCE.find("+ (CDEpisode *)findEpisodeWithGuid:")
finder = SOURCE[finder_start:]
require("if (_guidIndexByFeedURL)" in finder and "return nil;" in finder.split("if (_guidIndexByFeedURL)", 1)[1],
        "A miss in the authoritative backup index must remain a miss instead of faulting a full feed relationship.")

print("Backup import GUID-index scaling regression checks passed")
