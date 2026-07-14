#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


manager = read("Classes/Model/EpisodeLoadingManager.m")
header = read("Classes/Model/EpisodeLoadingManager.h")
importer = read("Classes/InstacastBackupImporter.m")
database_manager = read("Classes/Model/DatabaseManager.m")
subscription_manager = read("Classes/Model/SubscriptionManager.m")
icloud_manager = read("Classes/ICiCloudSyncManager.swift")
icloud_local_changes = read("Classes/ICiCloudSyncManager+LocalChanges.swift")


require("EpisodeLoadingManagerDidFailLoadingNotification" in header and
        "EpisodeLoadingManagerDidCancelLoadingNotification" in header,
        "Finish, failure, and cancellation must each have an explicit terminal event.")
require(".payload.plist" in manager and ".cursor.plist" in manager,
        "Each feed needs one immutable payload plus a small independent cursor sidecar.")
require("persistenceQueue" in manager,
        "Payload serialization and disk I/O must run on a dedicated background queue.")

queue_pending = method_body(manager, "- (void)queuePendingEpisodesForFeed:")
require("dispatch_async(self.persistenceQueue" in queue_pending,
        "Serializing thousands of episodes must not run on the caller/main thread.")
require("preparingFeedURLs" in queue_pending and "preparingFeedURLs" in method_body(manager, "- (BOOL)isLoadingFeed:"),
        "Callers must see a job as pending immediately while its payload is serialized off-main.")
require("_persistNewLoadInfo" in queue_pending,
        "A new job must durably write its payload and cursor before it can start.")
require(queue_pending.index("_persistNewLoadInfo") < queue_pending.index("_startNextPendingFeed"),
        "A crash-prone load may only start after durable job creation succeeds.")
before_persist = queue_pending[:queue_pending.index("_persistNewLoadInfo")]
require("_latestGenerations[feedURL] = generation" not in before_persist and
        "_pendingLoads[feedURL] = loadInfo" not in before_persist,
        "A replacement generation must not become current before its payload and cursor are durable.")
require("retryLoads" in queue_pending,
        "A failed, non-durable preparation must be retained separately from the last durable job for retry.")

require("[USER_DEFAULTS setObject:allLoads" not in manager and "- (void)_saveLoadingState" not in manager,
        "The full queue must never be rewritten into NSUserDefaults.")

load_batch = method_body(manager, "- (void)_loadNextBatchForFeedURL:")
require("[loadInfo[@\"episodes\"] mutableCopy]" not in load_batch and "removeObjectsInRange" not in load_batch,
        "Batching must advance an index, not copy and trim the entire remaining backlog.")
require("nextIndex" in load_batch and "subarrayWithRange" in load_batch,
        "A persisted cursor must select the next batch directly from the immutable payload.")
require("newBackgroundContext" in load_batch,
        "Episode hydration writes must run in a private Core Data context.")
require("save:&saveError" in load_batch,
        "Core Data save failures must be observed before advancing the job.")
require(load_batch.count("_isCurrentLoadInfo") >= 2,
        "The generation must be checked before saving and again before committing the cursor.")
require("_persistCursorForLoadInfo" in load_batch,
        "Only the tiny cursor sidecar should change after a successful batch.")
require(load_batch.index("save:&saveError") < load_batch.index("_persistCursorForLoadInfo"),
        "A failed batch must leave the durable cursor unchanged.")
require("initialLoadedCount + nextIndex" in load_batch and "loaded + parserEpisodes.count" not in load_batch,
        "Crash replay progress must be idempotent and clamped from base plus cursor.")

cancel_feed = method_body(manager, "- (void)_cancelLoadingForFeedURL:")
cancel_all = method_body(manager, "- (void)cancelAllLoading")
require("_deletePersistedJobForLoadInfo" in cancel_feed or "_deletePersistedJobForFeedURL" in cancel_feed,
        "Per-feed cancel must invalidate its durable job as well as memory state.")
require("queueGeneration" in cancel_all,
        "Global cancel must invalidate every already-prepared continuation generation.")
public_cancel = method_body(manager, "- (void)cancelLoadingForFeed:")
require("kFeedPropertyEpisodeLoadingComplete" in public_cancel and "saveReturningError" in public_cancel and
        public_cancel.index("saveReturningError") < public_cancel.index("_cancelLoadingForFeedURL"),
        "Canceling a still-subscribed feed must durably reconcile it as complete before deleting its only job.")
require(public_cancel.count("_cancelLoadingForFeedURL:feedURL") == 1,
        "A failed count or save must retain the durable episode-loading job for an explicit retry.")
require("previousLoadedCount" in public_cancel and "previousTotalExpectedEpisodes" in public_cancel and
        "previousLoadingComplete" in public_cancel,
        "A failed reconciliation save must restore the feed's prior in-memory loading state.")

finish = method_body(manager, "- (void)_finishLoadingForFeedURL:")
require("save:&saveError" in finish and "_deletePersistedJobForLoadInfo" in finish,
        "Finish must save the completed feed and then remove its durable job.")
require(finish.index("save:&saveError") < finish.index("_deletePersistedJobForLoadInfo"),
        "The invariant is job exists OR feed is durably complete; deletion cannot happen first.")

restore = method_body(manager, "- (void)restoreLoadingState")
require("_restorePersistedJobs" in restore,
        "Restart must scan independent cursor files and resume each exact cursor.")
require("restoringState" in restore and "restoringState" in method_body(manager, "- (BOOL)isLoading\n"),
        "Sync/startup callers must see loading as active until asynchronous state restoration finishes.")
require("removeObjectForKey:kUserDefaultsEpisodeLoadingQueueKey" in manager,
        "Legacy UserDefaults jobs must be migrated once and removed.")
require("self->_restoreScheduled = NO" in restore and
        restore.index("_restorePersistedJobs") < restore.index("self->_restoreScheduled = NO"),
        "A completed restore attempt must release its in-process gate so transient database/feed-check failures can be retried.")

retry = method_body(manager, "- (void)retryLoadingForFeed:")
require("retryLoads" in retry and "_persistedJobMatchesLoadInfo" in retry,
        "Retry must retain failed preparations and verify their own durable files before resuming.")
durable_match = method_body(manager, "- (BOOL)_persistedJobMatchesLoadInfo:(NSDictionary*)loadInfo\n{")
require("kLoadGenerationKey" in durable_match and "kLoadPayloadFilenameKey" in durable_match and
        "_readPropertyListAtURL" in durable_match,
        "A cursor's existence is insufficient: retry must match generation and payload and verify the payload is readable.")
progress = method_body(manager, "- (double)loadingProgressForFeed:")
require("MIN(1.0" in progress and "MAX(0.0" in progress,
        "Legacy/crash progress metadata must never render below 0% or above 100%.")

cancel_import = method_body(importer, "+ (void)cancelImport")
require("cancelAllLoading" not in cancel_import,
        "Canceling a backup import must not destroy unrelated podcast hydration jobs.")

subscribe = method_body(database_manager, "- (CDFeed*)subscribeFeed:(ICFeed*)parserFeed withOptions:")
require("saveReturningError" in subscribe and
        subscribe.index("saveReturningError") < subscribe.index("queuePendingEpisodesForFeed"),
        "A newly inserted feed must be durable before its background job can query it.")
hydrate = method_body(subscription_manager, "- (void) hydrateStubFeed:")
require("saveReturningError" in hydrate and
        hydrate.index("saveReturningError") < hydrate.index("queuePendingEpisodesForFeed"),
        "A hydrated iCloud stub must be saved before background episode loading starts.")

require("EpisodeLoadingManagerDidFailLoading" in icloud_manager,
        "iCloud hydration must observe durable episode-loader failures.")
require("EpisodeLoadingManagerDidCancelLoading" in icloud_manager,
        "iCloud hydration must observe explicit loader cancellation without a timeout.")
wait_for_loader = method_body(icloud_local_changes, "func waitForEpisodeLoader(feedID:")
require("asyncAfter" not in wait_for_loader,
        "Hydration must react to explicit finish/failure events, not a two-minute timeout workaround.")
hydrate_next_stub = method_body(icloud_local_changes, "func hydrateNextStubFeed()")
require("success," in hydrate_next_stub and
        "existingObject(with: nextID)" in hydrate_next_stub and
        "EpisodeLoadingManager.shared().isLoading(hydratedFeed)" in hydrate_next_stub,
        "Stub hydration may wait only for a loader job owned by the successfully hydrated feed resolved on the main actor.")
require("EpisodeLoadingManager.shared().isLoading {" not in hydrate_next_stub and
        "EpisodeLoadingManager.shared().isLoadingFeed" not in hydrate_next_stub,
        "An unrelated loader job or restore pass must not park the current stub hydration forever.")
require("func episodeLoadingDidFail" in icloud_local_changes,
        "A failed loader job must release iCloud hydration and surface as failed immediately.")
require("episodeLoaderWaitingFeedID" in icloud_manager and
        icloud_local_changes.count("episodeLoaderWaitingFeedID") >= 4,
        "Finish/failure from another queued podcast must not release the wrong iCloud hydration wait.")
require(manager.count('@"feedObjectIDURI"') >= 3 and
        icloud_local_changes.count('notification.userInfo?["feedObjectIDURI"] as? String') >= 3,
        "Episode-loader notifications must cross the Swift actor boundary as a stable sendable object-ID URI, not a managed object.")

print("Episode loading queue regression checks passed")
