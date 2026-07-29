#!/usr/bin/env python3
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"
MANAGER = "\n".join(
    (ROOT / "Classes" / name).read_text()
    for name in [
        "ICiCloudSyncTypes.swift",
        "ICiCloudSyncManager.swift",
        "ICiCloudSyncManager+LocalChanges.swift",
        "ICiCloudSyncManager+EngineRecords.swift",
        "ICiCloudSyncManager+RemoteApply.swift",
        "ICiCloudSyncManager+Metadata.swift",
    ]
)
EPISODES_CONTROLLER = (ROOT / "Classes" / "EpisodesTableViewController.m").read_text()
SUBSCRIPTION_MANAGER = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = MANAGER.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = MANAGER.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


def method_bodies(signature: str) -> str:
    bodies = []
    search_start = 0
    while True:
        start = MANAGER.find(signature, search_start)
        if start == -1:
            return "\n".join(bodies)
        brace = MANAGER.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        depth = 0
        for index in range(brace, len(MANAGER)):
            if MANAGER[index] == "{":
                depth += 1
            elif MANAGER[index] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(MANAGER[brace + 1:index])
                    search_start = index + 1
                    break
        else:
            raise AssertionError(f"Unterminated method: {signature}")


# The outbox must live in the same Core Data transaction as the user's edit. A separate
# plist would leave a kill window after unsubscribeFeed saved `subscribed = NO`, and that
# feed is physically removed before the sync manager starts on the next launch.
current_version = plistlib.loads((MODEL_DIR / ".xccurrentversion").read_bytes())
model_name = current_version.get("_XCCurrentVersionName")
require(model_name == "Model9.xcdatamodel", "The durable local outbox needs the current versioned Core Data model.")
model_path = MODEL_DIR / model_name / "contents"
require(model_path.exists(), "The current Core Data model version is missing.")
model = ET.parse(model_path).getroot()
old_model = ET.parse(MODEL_DIR / "Model.xcdatamodel" / "contents").getroot()


def entity_xml(entity: ET.Element, excluding_attributes=None) -> bytes:
    clone = ET.fromstring(ET.tostring(entity))
    for attribute in list(clone.findall("attribute")):
        if attribute.get("name") in (excluding_attributes or set()):
            clone.remove(attribute)
    clone.tail = None
    return ET.tostring(clone)


old_entities = {entity.get("name"): entity for entity in old_model.findall("entity")}
new_entities = {entity.get("name"): entity for entity in model.findall("entity")}
for entity_name, old_entity in old_entities.items():
    allowed_attributes = {
        "AppleWatchEpisodeState": {"watchLastEventRevision"},
        "EpisodeList": {"usePodcastArtwork"},
    }.get(entity_name, set())
    require(
        new_entities.get(entity_name) is not None
        and entity_xml(new_entities[entity_name], allowed_attributes) == entity_xml(old_entity),
        f"The current model must remain a lightweight additive migration; existing entity changed: {entity_name}",
    )
watch_revision_attributes = [
    attribute
    for attribute in new_entities["AppleWatchEpisodeState"].findall("attribute")
    if attribute.get("name") == "watchLastEventRevision"
]
require(
    len(watch_revision_attributes) == 1
    and watch_revision_attributes[0].get("attributeType") == "Integer 64"
    and watch_revision_attributes[0].get("optional") == "YES",
    "The Watch event revision must remain one optional additive attribute in the current model.",
)
project = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()
require(
    "Model9.xcdatamodel" in project
    and "currentVersion = F900B0A17E2D4B00A10B0001 /* Model9.xcdatamodel */;" in project,
    "The Xcode version group must compile Model9 as current; otherwise builds rewrite .xccurrentversion.",
)
outbox_entities = [entity for entity in model.findall("entity") if entity.get("name") == "ICCloudSyncOutboxEntry"]
require(len(outbox_entities) == 1, "The Core Data model must contain ICCloudSyncOutboxEntry.")
outbox_entity = outbox_entities[0]
require(outbox_entity.get("syncable") == "NO", "The local outbox itself must never be iCloud-synced by Core Data.")
attributes = {attribute.get("name"): attribute for attribute in outbox_entity.findall("attribute")}
for attribute in ["accountRecordName", "recordName", "category", "operation", "acknowledged",
                  "acknowledgedRevision", "acknowledgedOperation", "revision", "changedAt", "payloadData"]:
    require(attribute in attributes, f"Outbox attribute is missing: {attribute}")
require(
    any(
        {constraint.get("value") for constraint in unique.findall("constraint")}
        == {"accountRecordName", "recordName"}
        for constraints in outbox_entity.findall("uniquenessConstraints")
        for unique in constraints.findall("uniquenessConstraint")
    ),
    "Outbox entries must be unique per CloudKit account and record name.",
)

# Capture is category-history based, not current-toggle based. It runs synchronously for
# main-context user edits so the outbox row joins the same eventual context save/rollback.
core_data_change = method_body("@objc nonisolated func coreDataDidChange")
require(
    "ICiCloudSyncEpisodesEnabled" not in core_data_change
    and "ICiCloudSyncSubscriptionsEnabled" not in core_data_change,
    "Current OFF switches must not discard changes after a category has participated in sync.",
)
require(
    "episodesSyncHasParticipatedKey" in core_data_change
    and "subscriptionsSyncHasParticipatedKey" in core_data_change,
    "The observer must capture only categories that have participated in sync.",
)
require(
    "MainActor.assumeIsolated" in core_data_change
    and "journalLocalOutboxChanges" in core_data_change,
    "Main-context user changes must be journaled synchronously into the same Core Data transaction.",
)
require(
    "deletedFeedURLs" in core_data_change,
    "Deleted feeds must preserve their URL synchronously before their managed object disappears.",
)

journal = (
    method_body("func journalLocalOutboxChanges")
    + method_body("func journalLocalOutboxObjects")
    + method_bodies("func persistLocalOutboxMutations")
)
for state_field in ['"played"', '"position"', '"starred"']:
    require(state_field in journal, f"Episode outbox snapshots must include {state_field}, including false/zero resets.")
require(
    'static let subscriptionTombstone = "ICSubscriptionTombstone"' in MANAGER
    and 'static let subscriptionTombstone = "subscriptionTombstone_"' in MANAGER,
    "Subscription tombstones need a dedicated record type/prefix that released clients ignore.",
)
require(
    '"deleted": true' in journal
    and "subscriptionTombstoneRecordName(forFeedURL:" in journal
    and "operation: Self.localOutboxSaveOperation" in journal
    and "operation: Self.localOutboxDeleteOperation" in journal,
    "Unsubscribe/resubscribe must journal an authoritative save plus the inverse physical delete for old clients.",
)
require(
    "committedValues(forKeys:" in journal and '"sourceURL_"' in journal,
    "Feed redirects must tombstone the committed old URL, not changedValuesForCurrentEvent's new URL.",
)
require(
    "syncRelevantRedirectedFeedURLs" in core_data_change,
    "Background-context feed redirects must copy the committed old URL before hopping queues.",
)
require(
    "localOutboxCaptureAccountRecordName" in core_data_change
    and "localOutboxUnboundAccountRecordName" in MANAGER,
    "Edits before the first verified account must enter a durable unbound scope.",
)
require(
    "localOutboxAwaitingAccountSwitchKey" in MANAGER
    and "localOutboxPendingAccountRecordName" in MANAGER
    and "bindPendingAccountLocalOutboxEntries" in MANAGER,
    "Edits made while a switched account is offline/unverified need a separate scope that binds to that new account.",
)
require(
    "NSFetchRequest<NSManagedObject>" in journal and "recordName IN" in journal,
    "A notification batch must coalesce entries with one fetch, not one fetch per changed podcast/episode.",
)
require(
    "Data(contentsOf:" not in journal and "writeSyncMetadataValue" not in journal,
    "Atomic capture must not perform separate file I/O on the main thread.",
)

# A committed outbox is drained only after the context save. OFF categories remain stored,
# account mismatch remains stored, and inverse/older CKSyncEngine operations are replaced.
did_save = method_body("@objc nonisolated func coreDataDidSave")
schedule_drain = method_body("func scheduleLocalOutboxDrain")
require(
    "scheduleLocalOutboxDrain" in did_save and "drainLocalOutbox" in schedule_drain,
    "Cloud work must begin only after Core Data committed the outbox.",
)
drain = method_body("func drainLocalOutbox")
require(
    "accountRecordName" in drain
    and "episodesSyncEnabled" in drain
    and "subscriptionsSyncEnabled" in drain,
    "Drain must be gated by the verified account and the entry's category.",
)
require(
    "removePendingRecordChanges" in drain
    and "addPendingSaves" in drain
    and "addPendingDeletes" in drain,
    "Only the newest paired save/delete intent for a subscription may remain in CKSyncEngine.",
)

# Batch materialization must prefer the durable snapshot over whatever Core Data happens
# to contain later. The mutation revision travels inside the encrypted payload, requiring
# no production CloudKit schema field.
materialize = method_body("nonisolated static func materializeRecordsForSyncEngineCallback")
require(
    "localOutboxEntriesByRecordName" in materialize
    and materialize.find("localOutboxEntriesByRecordName") < materialize.find("episodeStatesByObjectHash"),
    "Outbox snapshots must be loaded in one batch and take precedence over live Core Data.",
)
require(
    "localMutationRevisionPayloadKey" in materialize,
    "Every outbox save must carry its revision inside the encrypted payload.",
)
require(
    "RecordKind.subscriptionTombstone" in materialize,
    "A tombstone outbox save must materialize as the dedicated CloudKit record type.",
)
next_batch = method_body("nonisolated func nextRecordZoneChangeBatch")
require(
    "staleDeleteChanges" in next_batch
    and "entry.operation == Self.localOutboxDeleteOperation" in next_batch,
    "A delete selected before an intent flip must be revalidated against the latest outbox operation.",
)

# Cloud success acknowledges exactly the submitted revision. An old in-flight ack must
# preserve and requeue a newer local edit of the same record.
sent_changes = method_body("func handleSentRecordZoneChanges")
require("acknowledgeLocalOutboxOperationsInBackground" in sent_changes,
        "Successful CloudKit saves and deletes must acknowledge the local outbox off MainActor.")
ack_operations = method_body("nonisolated static func acknowledgeLocalOutboxOperationsInBackground")
require(
    "currentRevision == sentAttempt.revision" in ack_operations
    and "currentOperation == sentAttempt.operation" in ack_operations,
    "An ACK may receipt only its exact submitted revision and operation.",
)
require(
    'forKey: "acknowledgedRevision"' in ack_operations
    and 'forKey: "acknowledgedOperation"' in ack_operations
    and "localOutboxEntryIsAcknowledged" in ack_operations
    and "context.delete(" not in ack_operations,
    "A subscription pair must remain durable until both inverse operations are acknowledged.",
)
require(
    "needsOutboxDrain" in ack_operations,
    "A stale ack must requeue the newer current outbox revision.",
)
require(
    "deleteRevisionsByRecordName" in sent_changes
    and "pendingDeleteAttempt" in sent_changes
    and "acknowledgeDeleteAttempts" in sent_changes,
    "Physical-delete acknowledgements must peek the exact sent revision and consume it only after durable local ACK.",
)

# Live and parked remote data must share the same outbox/LWW decision. A tombstone uses
# SubscriptionManager so playback, loading, cache and Up Next cleanup are not bypassed.
episode_apply = method_body("func applyPendingEpisodeStateBatchInBackground")
subscription_apply = method_body("func applyPendingSubscriptionBatchInBackground(")
subscription_consume = method_body("func consumeSubscriptionApplyBatchResult(")
subscription_cleanup_drain = method_body("func performPendingSubscriptionCleanupIntentDrain(")
remote_view_merge = method_body("func performSynchronousRemoteViewContextMerge(")
pending_episodes = method_body("func applyPendingEpisodeStates")
pending_subscriptions = method_body("func applyPendingSubscriptions")
require("localOutboxEntityName" in episode_apply
        and "episodeOutboxRevisionResolvedByMetadata" in episode_apply,
        "Remote episode apply must consult the exact durable local outbox revision first.")
require("func remoteDecision" in subscription_apply,
        "Remote subscription apply must consult the local outbox first.")
require(
    "applyPendingSubscriptionBatchInBackground" in pending_subscriptions
    and "applySubscriptionPayload(payload, to:" not in pending_subscriptions,
    "Parked subscriptions must not bypass the live LWW/outbox path.",
)
require(
    "subscriptionOutboxRecordNames" in subscription_apply,
    "Parked subscription conflicts must preload both halves of the logical outbox intent.",
)
require(
    "applyPendingEpisodeStateBatchInBackground" in pending_episodes
    and "remoteOriginGate.register" in episode_apply
    and "remoteOriginGate.register" in subscription_apply
    and "performSynchronousRemoteViewContextMerge" in subscription_consume
    and "NSManagedObjectContext.mergeChanges" in remote_view_merge
    and "isApplyingRemoteChange = true" in remote_view_merge
    and "remoteAppliedObjectIDs.subtract(originObjectIDs)" in subscription_consume
    and "isApplyingRemoteChange = true" not in pending_episodes
    and "isApplyingRemoteChange = true" not in pending_subscriptions,
    "Applying parked remote payloads must not be recaptured as new local outbox mutations.",
)
require(
    "drainPendingSubscriptionCleanupIntentsIfNeeded" in subscription_consume
    and "performUnsubscribeSideEffects" in subscription_cleanup_drain
    and "stop]" in SUBSCRIPTION_MANAGER
    and "cancelLoadingForFeed" in SUBSCRIPTION_MANAGER
    and "removeCacheForFeeds" in SUBSCRIPTION_MANAGER
    and "resetAutoCacheForFeeds" in SUBSCRIPTION_MANAGER
    and "eraseEpisodesFromUpNext" in SUBSCRIPTION_MANAGER
    and "_removePendingAutoDownloadFeedUIDs" in SUBSCRIPTION_MANAGER,
    "Remote subscription tombstones must run the complete unsubscribe cleanup.",
)
fetched_changes = method_body("func handleFetchedRecordZoneChanges")
require(
    "try await Self.localOutboxEntries" in fetched_changes
    and fetched_changes.find("stagePendingSubscriptionStates")
    < fetched_changes.find("try await Self.localOutboxEntries")
    < fetched_changes.find("processFetchedDeletionBatch"),
    "Legacy physical deletes must be parked, then preload logical outbox intent before they are applied.",
)
require(
    "performSynchronousRemoteApplyBatch {" in fetched_changes
    and fetched_changes.find("performSynchronousRemoteApplyBatch {")
    < fetched_changes.find("await Task.yield()")
    and "isApplyingRemoteChange = true" not in fetched_changes
    and "isApplyingRemoteChange = false" not in fetched_changes,
    "Remote objects must be committed while origin suppression is active before yielding to UI edits.",
)
require(
    "await applyPendingSubscriptions()" not in fetched_changes,
    "Subscription pairs must remain parked until didFetchChanges provides a complete logical fetch.",
)
event_handler = method_body("func handleEventOnMain")
require(
    "case .didFetchChanges" in event_handler
    and "await applyPendingSubscriptions()" in event_handler,
    "The complete-fetch callback must resolve and apply parked subscription winners.",
)
require(
    "mergeLocalOutboxSnapshotsIntoCache" in fetched_changes
    and "mergeLocalOutboxSnapshotsIntoCache" in pending_subscriptions,
    "An outbox read that suspends must not overwrite a newer user edit cached during the await.",
)
remote_delete = method_body("func applyRemoteDeletion")
remote_delete += method_body("func observeRemoteSubscriptionDeletionAgainstOutbox")
require(
    "localSubscriptionOutboxIntent" in remote_delete
    and "scheduleLocalOutboxDrain" in remote_delete,
    "A newer local subscribe/unsubscribe intent must win over a legacy physical delete.",
)
require(
    "localOutboxRevisionsToRearm" in remote_delete
    and "replacingAcknowledged(false)" in remote_delete,
    "A remote delete must re-arm a previously acknowledged save half instead of leaving a partial intent uncovered.",
)

# A fetched older overwrite can arrive after CloudKit acknowledged only one half of a
# logical pair. Keeping local state is insufficient: the conflicting physical operation
# must become unacknowledged and be sent again, and REARM must beat a same-batch ACK.
outbox_decision = method_body("func remoteOutboxDecision")
keep_local_start = outbox_decision.rfind("scheduleLocalOutboxDrain()")
require(
    "replacingAcknowledged(false)" in outbox_decision[:keep_local_start]
    and "localOutboxRevisionsToRearm" in outbox_decision[:keep_local_start],
    "A local LWW win must re-arm an already acknowledged physical half before draining.",
)
resolved_outbox = method_body("func deleteResolvedLocalOutboxEntries")
require(
    resolved_outbox.find("revisionsToRearm[recordName]")
    < resolved_outbox.find("revisionsToAcknowledge[recordName]"),
    "When ACK and REARM target the same revision, REARM must win.",
)

# Same-account sign-in naturally sees scoped rows; another account never does. Explicit
# zone deletion removes only the current account's rows before a fresh local backfill.
reconcile = method_body("func reconcileAvailableICloudAccount")
require(
    "bindUnboundLocalOutboxEntries" in reconcile
    and "localOutboxHasVerifiedAccountKey" in reconcile
    and "continueEnabledSyncAfterAccountVerification" in reconcile,
    "Only the first verified account may bind and resume the unbound durable outbox.",
)
delete_cloud = method_body("@objc func deleteAllICloudDataWithCompletion")
require("deleteLocalOutboxEntries" in delete_cloud, "Deleting all iCloud data must clear the current account's outbox scope.")

# The actual 4500-row user action must create small Core Data transactions. Chunking only
# the later CloudKit queue is too late: ObjectsDidChange otherwise serializes and inserts
# every outbox snapshot synchronously in one main-context save.
require(
    "kBulkEpisodeMutationBatchSize" in EPISODES_CONTROLLER,
    "Bulk played/unplayed changes need an explicit bounded transaction size.",
)
bulk_start = EPISODES_CONTROLLER.find("- (void) _setAllAsConsumed:")
require(bulk_start != -1, "Missing bulk played/unplayed action.")
bulk_end = EPISODES_CONTROLLER.find("- (void) _archiveAllPlayed", bulk_start)
require(bulk_end != -1, "Could not isolate bulk played/unplayed action.")
bulk = EPISODES_CONTROLLER[bulk_start:bulk_end]
require(
    "dispatch_async(dispatch_get_main_queue()" in bulk
    and "kBulkEpisodeMutationBatchSize" in bulk
    and "[DMANAGER saveReturningError]" in bulk,
    "Bulk episode edits must save bounded batches and yield to the main run loop between them.",
)
require(
    "beginLocalOutboxBatch" in bulk
    and "endLocalOutboxBatch" in EPISODES_CONTROLLER[
        EPISODES_CONTROLLER.find("- (void)_finishBulkEpisodeMutationWithCacheEpisodes:"):
        EPISODES_CONTROLLER.find("- (void) _clearCacheOfAllPlayed")
    ],
    "A local mass edit must coalesce CloudKit drain work until all small transactions finish.",
)
require(
    "NSManagedObjectID" in bulk
    and "existingObjectWithID" in bulk
    and "isDeleted" in bulk,
    "Bulk batches must re-resolve object IDs so concurrent sync deletion cannot access invalid managed-object faults.",
)
require(
    "saveReturningError" in bulk,
    "A failed bulk transaction must stop and report the local save error instead of continuing with an uncommitted outbox.",
)
subscription_header = (ROOT / "Classes" / "Model" / "SubscriptionManager.h").read_text()
require(
    "autoDownloadEpisodesInFeedAsynchronously" in subscription_header
    and "autoDownloadEpisodesInFeedAsynchronously" in bulk
    and "autoDownloadEpisodesInFeed:feed" not in bulk,
    "Post-bulk auto-download work must use the existing utility-queue path, never synchronously walk all feed episodes.",
)

print("iCloud local outbox regression checks passed")
