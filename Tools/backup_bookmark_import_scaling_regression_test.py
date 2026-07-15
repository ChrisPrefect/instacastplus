#!/usr/bin/env python3
"""Pins linear, background, batched bookmark backup import."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("+ (NSInteger)importBookmarksFromBackup:")
end = SOURCE.find("#pragma mark - Up Next", start)
require(start != -1 and end != -1, "Missing bookmark import method.")
method = SOURCE[start:end]

require("error:(NSError **)error" in method and "newBackgroundContext" in method and "performBlockAndWait" in method,
        "Bookmark import must run on a private Core Data queue and return real failures.")
require('initWithEntityName:@"Bookmark"' in method and "NSDictionaryResultType" in method,
        "Existing bookmarks must be fetched as one lightweight snapshot.")
require("bookmarkPositionsByEpisode" in method and "ICBackupBookmarkExistsInIndex" in method,
        "Duplicate checks must use a feed/GUID/position index instead of nested bookmark scans.")
require("DMANAGER.bookmarks" not in method and "for (CDBookmark *existing" not in method,
        "The quadratic main-context duplicate scan must not return.")
require("bookmarkSaveBatchSize" in method and "pendingBookmarkCount" in method and "[context save:&saveError]" in method,
        "Large imports must commit small durable batches and count only saved bookmarks.")
require("normalizedFeedURLStringForURLString" in method and "equivalentFeedURLStringsForURLString" in SOURCE,
        "Bookmark preview and import must share central feed URL identity rules.")
require("bookmarkImportError" in SOURCE and "terminalError = phaseError" in SOURCE,
        "Fetch/save errors must terminate the metadata import instead of producing a success summary.")

metadata_loop = SOURCE[SOURCE.find("NSInteger metadataTotal"):SOURCE.find("PHASE D: Downloads")]
bookmark_branch_start = metadata_loop.find(
    "else if (cat == ICBackupImportBookmarks || cat == ICBackupImportDownloads"
)
bookmark_branch_end = metadata_loop.find(
    "\n            } else {\n                runOnMain", bookmark_branch_start
)
bookmark_branch = metadata_loop[bookmark_branch_start:bookmark_branch_end]
require(bookmark_branch_start >= 0 and "count = importBlock(&phaseError);" in bookmark_branch
        and "runOnMain(^{\n                    count = importBlock(&phaseError);" not in bookmark_branch,
        "The bookmark phase must execute on the import worker, not inside runOnMain.")

print("Backup bookmark import scaling regression checks passed")
