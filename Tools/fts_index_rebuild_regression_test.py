from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    candidates = [
        index
        for marker in ("\n- (", "\n+ (", "\n#pragma mark")
        if (index := source.find(marker, start + len(signature))) != -1
    ]
    end = min(candidates) if candidates else len(source)
    return source[start:end]


header = (ROOT / "Classes" / "Model" / "ICFTSController.h").read_text()
fts = (ROOT / "Classes" / "Model" / "ICFTSController.m").read_text()
database_manager = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
feed_episodes = (ROOT / "Classes" / "FeedEpisodesTableViewController.m").read_text()
episode_list = (ROOT / "Classes" / "Model" / "CDEpisodeList.m").read_text()

require(
    "rebuildIndexWithManagedObjectContext" in header,
    "The FTS controller needs an explicit authoritative rebuild API.",
)
rebuild = method_body(fts, "- (void) rebuildIndexWithManagedObjectContext:")
migration = method_body(database_manager, "- (void) _migrateFTS")

require(
    "dispatch_async(self.writeQueue" in rebuild,
    "The rebuild must run on the utility write queue so it neither blocks UI nor races incremental index writes.",
)
require(
    "performBlockAndWait" in rebuild
    and 'initWithEntityName:@"Feed"' in rebuild
    and 'initWithEntityName:@"Episode"' in rebuild
    and "fetchBatchSize" in rebuild
    and "fetchLimit" in rebuild
    and 'sourceURL_ > %@' in rebuild
    and 'objectHash > %@' in rebuild,
    "The rebuild must use bounded keyset pages; fetchBatchSize alone still returns one array containing every episode.",
)
require(
    "pageFeedUIDs" in rebuild
    and "pageEpisodeUIDs" in rebuild
    and "indexedEpisodeUIDs" not in rebuild
    and "_insertFeedSnapshot" in rebuild
    and "_insertEpisodeSnapshot" in rebuild
    and "_replaceFeedSnapshot" not in rebuild
    and "_replaceEpisodeSnapshot" not in rebuild,
    "A fresh rebuild must deduplicate UIDs and insert directly; DELETE-before-every-INSERT makes FTS4 rebuilding quadratic.",
)
for signature in ("- (void) addFeed:", "- (void) removeFeed:", "- (void) addEpisode:", "- (void) removeEpisode:"):
    mutation = method_body(fts, signature)
    require(
        "_recordPending" in mutation,
        f"{signature} must coalesce by UID during rebuild before capturing title/fulltext snapshots.",
    )
require(
    "pendingFeedMutations" in fts
    and "pendingEpisodeMutations" in fts
    and "stageChangesForManagedObjectContext" in header
    and "commitStagedChangesForManagedObjectContext" in header,
    "Concurrent rebuild changes must stay as compact last-write-wins mutations staged until their owning context saves.",
)
objects_did_change = method_body(
    database_manager,
    "- (void) managedObjectContextObjectsDidChangeNotification:",
)
context_will_save = method_body(
    database_manager,
    "- (void) managedObjectContextWillSaveNotification:",
)
context_did_save = method_body(
    database_manager,
    "- (void) managedObjectContextDidSaveNotification:",
)
primary_store_filter = method_body(
    database_manager,
    "- (BOOL)_managedObjectContextUsesPrimaryPersistentStore:",
)
require(
    "NSManagedObjectContextWillSaveNotification" in database_manager
    and "NSManagedObjectContextDidSaveNotification" in database_manager
    and "persistentStoreCoordinator" in primary_store_filter
    and "parentContext == nil" in primary_store_filter
    and "_managedObjectContextUsesPrimaryPersistentStore" in context_will_save
    and "_managedObjectContextUsesPrimaryPersistentStore" in context_did_save
    and "stageChangesForManagedObjectContext" in context_will_save
    and "commitStagedChangesForManagedObjectContext" in context_did_save,
    "FTS changes from root main/background contexts must be staged before save and committed only from a durable did-save notification; child saves are not durable.",
)
require(
    "ftsController" not in objects_did_change
    and "flushPendingChanges" not in header
    and "flushPendingChanges" not in database_manager,
    "An objects-did-change event or failed save must never publish or discard an FTS mutation.",
)
pending_drain = method_body(fts, "- (NSError*)_drainPendingMutationsWithManagedObjectContext:")
require(
    'sourceURL_ IN %@ AND sourceURL_ > %@' in pending_drain
    and 'objectHash IN %@ AND objectHash > %@' in pending_drain,
    "Pending mutation pages must keyset through duplicate Core Data UIDs so duplicates cannot consume the fetch limit and hide another requested UID.",
)
stage_changes = method_body(fts, "- (void)stageChangesForManagedObjectContext:")
commit_staged = method_body(fts, "- (void)commitStagedChangesForManagedObjectContext:")
require(
    'changedValues[@"sourceURL_"]' in stage_changes
    and 'changedValues[@"subscribed"]' in stage_changes
    and 'changedValues[@"objectHash"]' in stage_changes
    and 'changedValues[@"feed"]' in stage_changes
    and "committedValuesForKeys" in stage_changes
    and "reindexEpisodeFeedUIDs" in fts,
    "Saved membership and identity transitions must delete old keys and reindex a podcast's episodes when its URL/subscription changes.",
)
deleted_changes = stage_changes.split(
    "for (NSManagedObject* object in context.deletedObjects)", 1
)[1].split("ICFTSSaveChangeSet* changeSet", 1)[0]
require(
    'committedValuesForKeys:@[@"sourceURL_"]' in deleted_changes
    and 'committedValuesForKeys:@[@"objectHash"]' in deleted_changes
    and deleted_changes.count("if (oldUID.length > 0)") == 2,
    "Deleting an identity-changed object in the same save must remove both its committed old key and its current key from FTS.",
)
require(
    "existingMutation = self.pendingFeedMutations[uid]" in commit_staged
    and "existingMutation.reindexEpisodes ||" in commit_staged,
    "A metadata-only save during rebuild must not clear an already-pending episode reindex for the same podcast.",
)
require(
    "NSString* uid = episode.objectHash" in fts
    and "NSString* uid = episode.guid" not in method_body(fts, "static NSDictionary* ICFTSEpisodeSnapshot")
    and "episodeObjectHashesForSearchTerm" in header
    and "episodeUIDsForSearchTerm" not in header
    and "episodeObjectHashesForSearchTerm" in feed_episodes
    and "objectHash IN" in feed_episodes
    and "episodeObjectHashesForSearchTerm" in episode_list
    and "objectHash IN" in episode_list,
    "FTS episode identity must be the globally feed-scoped object hash, not a podcast-local GUID.",
)
require(
    'objectHash != nil AND objectHash != \\"\\"' in rebuild
    and 'sourceURL_ != nil AND sourceURL_ != \\"\\"' in rebuild
    and "uid.length == 0" in fts,
    "Malformed empty identifiers must be excluded deliberately instead of colliding or making every versioned rebuild fail.",
)
require(
    '.rebuild"' in rebuild
    and "removeItemAtURL" in rebuild
    and "replaceItemAtURL" in rebuild,
    "Build into a cleaned sibling file and atomically replace the live index only after success.",
)
require(
    "while (!pendingMutationError)" in rebuild
    and "pendingFeedMutations.count == 0" in rebuild
    and "pendingEpisodeMutations.count == 0" in rebuild
    and rebuild.find("_drainPendingMutationsWithManagedObjectContext") < rebuild.find("self.rebuildingIndex = NO"),
    "Rebuild completion must atomically observe an empty committed mutation set; one final snapshot leaves a publication race.",
)
require(
    "CREATE VIRTUAL TABLE" in rebuild
    and "INSERT INTO feeds(feeds) VALUES('optimize')" in rebuild
    and "INSERT INTO episodes(episodes) VALUES('optimize')" in rebuild
    and 'executeUpdate:@"VACUUM"' in rebuild,
    "The fresh FTS database must be optimized and compacted before publication.",
)
require(
    "PRAGMA quick_check" in rebuild,
    "The rebuilt SQLite file must pass an integrity check before publication.",
)
require(
    "kDefaultFTSIndexVersion" in database_manager
    and "kFTSIndexVersion" in database_manager
    and "kFTSIndexVersion = 3" in database_manager
    and "integerForKey:kDefaultFTSIndexVersion" in migration,
    "FTS repair must be versioned so every existing broken index is rebuilt once.",
)
require(
    "kDefaultFTSMigrationDone" not in database_manager
    and "boolForKey:kDefaultFTSIndexVersion" not in migration,
    "The old one-shot Boolean cannot represent future index repair versions.",
)
require(
    "newExportBackgroundContext" in migration
    and "persistentStoreCoordinator = self.storeCoordinator" not in migration
    and "setParentContext:self.objectContext" not in migration,
    "FTS enumeration must use the separate read-only coordinator so the full scan cannot monopolize the UI coordinator.",
)
require(
    "rebuildIndexWithManagedObjectContext" in migration
    and "if (!error)" in migration
    and "setInteger:kFTSIndexVersion" in migration,
    "Publish the schema version only after the complete rebuild succeeds; failures must retry next launch.",
)
require(
    "- (void) indexFeeds:" not in fts and "- (void) indexFeeds:" not in header,
    "Remove the old append-only bulk index API so it cannot recreate duplicate/stale rows.",
)
