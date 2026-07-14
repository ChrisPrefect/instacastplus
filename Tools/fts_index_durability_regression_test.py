#!/usr/bin/env python3
"""Pins crash-safe handoff between durable Core Data saves and async FTS writes."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "Model" / "ICFTSController.h").read_text()
FTS = (ROOT / "Classes" / "Model" / "ICFTSController.m").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
FTS_IMPLEMENTATION = FTS[FTS.find("@implementation ICFTSController"):]


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
                return source[brace:index + 1]
    raise AssertionError(f"Unterminated method: {signature}")


require(
    "indexNeedsRebuild" in HEADER
    and "dirtyMarkerURL" in FTS
    and 'URLByAppendingPathExtension:@"dirty"' in FTS,
    "FTS needs a durable sibling marker that survives termination while an index write is pending.",
)
open_index = method_body(FTS, "- (void) open")
health = method_body(FTS, "- (BOOL)indexNeedsRebuild")
mark_dirty = method_body(FTS_IMPLEMENTATION, "- (BOOL)_markIndexDirty:")
mark_clean = method_body(FTS_IMPLEMENTATION, "- (BOOL)_markIndexClean:")
prepare_external = method_body(FTS_IMPLEMENTATION, "- (BOOL)prepareForExternalStoreMutation:")
require(
    "indexRequiresAuthoritativeRebuild" in FTS
    and "sqlite_master" in open_index
    and open_index.find("sqlite_master") < open_index.find("CREATE VIRTUAL TABLE")
    and "_markIndexDirty:" in open_index
    and open_index.find("_markIndexDirty:") < open_index.find("CREATE VIRTUAL TABLE")
    and "indexRequiresAuthoritativeRebuild" in health,
    "A missing or schema-less current-version index must be durably unhealthy before open creates fresh empty FTS tables.",
)
require(
    "fileExistsAtPath:self.dirtyMarkerURL.path" in mark_dirty
    and "fileExistsAtPath:self.dirtyMarkerURL.path" in mark_clean
    and "indexNeedsRebuild" not in mark_dirty
    and "indexNeedsRebuild" not in mark_clean,
    "The durable marker lifecycle must not confuse a missing-index health flag with an already-created marker file.",
)
require(
    "externalStoreMutationPending = YES" in prepare_external,
    "An external batch mutation must reserve the dirty state before the store changes, not only when its later rebuild is queued.",
)

stage = method_body(FTS, "- (void)stageChangesForManagedObjectContext:")
require(
    "_markIndexDirty:" in stage
    and stage.find("setObject:changeSet") < stage.find("_markIndexDirty:"),
    "Will-save staging must persist the dirty marker before Core Data can commit, while retaining the staged change as a clean-up barrier.",
)

commit = method_body(FTS, "- (void)commitStagedChangesForManagedObjectContext:")
require(
    "_markIndexDirty:" in commit
    and "pendingCommittedWrites += 1" in commit
    and commit.find("_markIndexDirty:") < commit.find("dispatch_async(self.writeQueue"),
    "A successful Core Data save must synchronously mark FTS dirty before its async index transaction is queued.",
)
require(
    "_finishCommittedWriteSucceeded:" in commit,
    "Every queued post-save transaction must report whether it actually committed.",
)

finish_write = method_body(FTS, "- (void)_finishCommittedWriteSucceeded:")
require(
    "pendingCommittedWrites -= 1" in finish_write
    and "incrementalWriteFailed = YES" in finish_write
    and "pendingCommittedWrites == 0" in finish_write
    and "stagedChangesByContext.count == 0" in finish_write
    and "!self.externalStoreMutationPending" in finish_write
    and "!self.incrementalWriteFailed" in finish_write
    and "!self.rebuildingIndex" in finish_write
    and "_markIndexClean:" in finish_write,
    "The dirty marker may clear only after every queued transaction committed; one failure must keep it durable.",
)

rebuild = method_body(FTS, "- (void) rebuildIndexWithManagedObjectContext:")
require(
    "_markIndexDirty:" in rebuild
    and rebuild.find("_markIndexDirty:") < rebuild.find("dispatch_async(self.writeQueue"),
    "A versioned rebuild must be marked dirty before its asynchronous work starts.",
)
require(
    "requestedRebuildGeneration" in FTS
    and "rebuildGeneration = ++self.requestedRebuildGeneration" in rebuild
    and "self.externalStoreMutationPending = NO" in rebuild
    and "if (!self.rebuildingIndex)" in rebuild
    and "rebuildGeneration == self.requestedRebuildGeneration" in rebuild,
    "Overlapping startup/reset rebuild requests must serialize by generation without clearing shared pending mutations.",
)
clean = rebuild.rfind("_markIndexClean:")
publish = rebuild.rfind("self.rebuildingIndex = NO")
empty_check = rebuild.rfind("pendingFeedMutations.count == 0")
latest_generation = rebuild.rfind("rebuildGeneration == self.requestedRebuildGeneration")
require(
    empty_check >= 0
    and "stagedChangesByContext.count == 0" in rebuild
    and "indexRequiresAuthoritativeRebuild = NO" in rebuild
    and "!self.externalStoreMutationPending" in rebuild
    and latest_generation < clean
    and clean > empty_check
    and publish > clean,
    "Rebuild must clear the marker atomically only after the final mutation drain and before reopening incremental writes.",
)

migration = method_body(DATABASE, "- (void) _migrateFTS")
reset = method_body(DATABASE, "- (void)resetAllUserDataWithCompletion:")
require(
    "indexNeedsRebuild" in migration
    and "if (!error)" in migration,
    "Startup must rebuild a dirty current-version index; schema version and durable health state are independent.",
)
require(
    "ftsIndexingOperationCount" in DATABASE
    and "_beginFTSIndexing" in migration
    and "_endFTSIndexing" in migration
    and "_beginFTSIndexing" in reset
    and "_endFTSIndexing" in reset,
    "Overlapping startup/reset rebuilds must retain the search activity indicator until the last operation completes.",
)

print("FTS index durability regression checks passed")
