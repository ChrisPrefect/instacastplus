#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return (ROOT / path).read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature, next_marker=None):
    # Brace-matching extraction: the old "cut at the next private member" heuristic broke
    # when the manager was split into files and member access became internal.
    require(signature in source, f"{signature} is missing.")
    start = source.find(signature)
    brace = source.find("{", start)
    require(brace != -1, f"{signature} has no body.")
    depth = 0
    for index in range(brace, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


MANAGER = "\n".join(read("Classes/" + _n) for _n in ["ICiCloudSyncManager.swift", "ICiCloudSyncTypes.swift", "ICiCloudSyncManager+EngineRecords.swift", "ICiCloudSyncManager+RemoteApply.swift", "ICiCloudSyncManager+LocalChanges.swift", "ICiCloudSyncManager+Metadata.swift"])

# New clients publish versioned tombstones under a record type that released clients do
# not recognize, plus a physical active-record delete that those clients do recognize.
require('static let subscriptionTombstone = "ICSubscriptionTombstone"' in MANAGER,
        "Subscription tombstones need their own CloudKit record type for old-client compatibility.")
require('static let subscriptionTombstone = "subscriptionTombstone_"' in MANAGER,
        "Subscription tombstones need a non-overlapping record-name prefix.")

journal = method_body(MANAGER, "func journalLocalOutboxObjects")
require("subscriptionTombstoneRecordName(forFeedURL:" in journal,
        "Local subscription changes must journal the tombstone-side operation.")
require(journal.count("operation: Self.localOutboxSaveOperation") >= 3
        and journal.count("operation: Self.localOutboxDeleteOperation") >= 2,
        "Subscribe and unsubscribe must each persist inverse save/delete operations.")
require(journal.count("revision: revision") >= 4,
        "Both halves of a logical subscription change must carry the same revision.")

materialize = method_body(MANAGER, "nonisolated static func materializeRecordsForSyncEngineCallback")
require("RecordKind.subscriptionTombstone" in materialize,
        "The tombstone outbox save must materialize using the dedicated record type.")

inventory = method_body(MANAGER, "func refreshCloudInventory(reason:")
require('configuration.desiredKeys = shouldInspectPayloads ? ["payload"] : []' in inventory
        and "isTransitionalSubscriptionTombstone" in MANAGER
        and "transitionalSubscriptionInventoryRecords" in inventory,
        "Inventory must identify same-type tombstones once, then exclude them by system metadata without repeated payload downloads.")

# Enabling subscription sync must NEVER delete local subscriptions. Deletions that piled
# up in the cloud while sync was off arrive in the catch-up fetch and must be suppressed
# until the first complete fetch has run; only live deletions after that are applied.
enable = method_body(MANAGER, "private func applySubscriptionsSyncEnabled", next_marker="\n    @objc func ")
require('defaults.set(true, forKey: Self.suppressSubscriptionDeletionsKey)' in enable,
        "Enabling subscription sync must arm the deletion-suppression flag.")
require('defaults.removeObject(forKey: Self.suppressSubscriptionDeletionsKey)' in enable,
        "Disabling subscription sync must clear the deletion-suppression flag.")

deletion = method_body(MANAGER, "func applyRemoteDeletion")
deletion_with_outbox = deletion + method_body(MANAGER, "func observeRemoteSubscriptionDeletionAgainstOutbox")
require("suppressSubscriptionDeletionsKey" in deletion,
        "Remote subscription deletions must respect the suppression flag.")
require("unsubscribeFeed" not in deletion,
        "A physical delete must not perform destructive unsubscribe side effects before pair resolution.")
require("RecordKind.subscriptionTombstone" in deletion
        and "return" in deletion,
        "Deleting a tombstone record during resubscribe must never unsubscribe the feed.")
require("localSubscriptionOutboxIntent" in deletion_with_outbox and "scheduleLocalOutboxDrain" in deletion_with_outbox,
        "A newer durable local intent must win over a physical delete from an old client.")

apply_subscription = method_body(MANAGER, "func applyRemoteSubscription(")
apply_tombstone = method_body(MANAGER, "func applyRemoteSubscriptionTombstone")
require("remoteOutboxDecision" in apply_subscription and "remoteOutboxDecision" in apply_tombstone,
        "Active records and tombstones must share the same logical LWW decision.")
require("suppressSubscriptionDeletionsKey" in apply_tombstone
        and "restoreDurableSubscriptionOutboxIntent" in apply_tombstone,
        "The first-enable union phase must defend local subscriptions against tombstone modifications too.")
require("localMetadata?.localState" in apply_subscription
        and "subscriptionSyncItemMetadata" in apply_subscription
        and "restoreDurableSubscriptionOutboxIntent" in apply_subscription,
        "A newer local unsubscribe must repair a tombstone intent, never be guessed as a subscribe.")

local_metadata = method_body(MANAGER, "func journalLocalOutboxObjects")
require("let now = Date()" in local_metadata
        and "changedAt: now" in local_metadata
        and "localModifiedAt: now" in local_metadata,
        "Subscription indexed metadata and its outbox pair must use exactly the same mutation time.")

event_handler = method_body(MANAGER, "func handleEventOnMain")
require("suppressSubscriptionDeletionsKey" in event_handler and "didFetchChanges" in event_handler,
        "The suppression flag must be cleared only after a complete fetch (didFetchChanges), not after send-only runs.")
require("await applyPendingSubscriptions()" in event_handler,
        "Subscription pair winners must be applied only after the complete CloudKit fetch.")

# CloudKit exposes modifications and deletions as separately unordered arrays. Stage
# deletes first within one callback so an extant record payload supersedes its physical
# inverse, and defer every active/tombstone payload until didFetchChanges can select one
# LWW winner per feed. Applying both states destroys playback/download/Up-Next state even
# when the final subscription state happens to be correct.
fetched = method_body(MANAGER, "func handleFetchedRecordZoneChanges")
require(fetched.find("processFetchedDeletionBatch") < fetched.find("processFetchedModificationBatch"),
        "Fetched deletes must be staged before modifications from the same unordered callback.")
first_subscription_stage = fetched.find("stagePendingSubscriptionStates")
second_subscription_stage = fetched.find("stagePendingSubscriptionStates", first_subscription_stage + 1)
require(first_subscription_stage != -1
        and first_subscription_stage < fetched.find("processFetchedDeletionBatch"),
        "A physical subscription deletion must be durably staged before local deletion bookkeeping.")
require(second_subscription_stage != -1
        and second_subscription_stage < fetched.find("processFetchedModificationBatch"),
        "A subscription modification must be durably staged before local apply/token advancement.")
deletion_writes = method_body(MANAGER, "func pendingSubscriptionDeletionStateWrites")
require("legacyPhysicalDelete" in deletion_writes and "syncItemMetadataSnapshot" in deletion_writes,
        "A released-client physical delete must be reconstructed from indexed feed metadata.")
modification_batch = method_body(MANAGER, "func processFetchedModificationBatch")
require("mergePendingSubscriptions" not in modification_batch
        and "RecordKind.subscription" in modification_batch
        and "applyRemoteNonEpisodeRecord" in modification_batch,
        "Active/tombstone payloads must stay parked in the row store for fetch-wide logical coalescing.")
pending_winners = method_body(MANAGER, "func resolvedPendingSubscriptionChanges")
require("updatedAt" in pending_winners and "isTombstone" in pending_winners
        and "snapshots: candidates.flatMap" in pending_winners,
        "Pending subscription pairs need timestamp LWW plus a deterministic state tie-breaker.")
pending_subscriptions = method_body(MANAGER, "func applyPendingSubscriptions")
require("resolvedPendingSubscriptionChanges" in pending_subscriptions,
        "Pending apply must reduce active/tombstone records to one logical change per feed.")
require("pendingSubscriptionStateBatch" in pending_subscriptions
        and "removePendingSubscriptionStates" in pending_subscriptions,
        "Pending pair replay must page durable rows and remove the exact committed pair only.")
require("applyRemoteSubscriptionTombstone" in pending_subscriptions,
        "A dedicated tombstone record parked across a fetch must never be replayed as an active subscription.")
require("applyPendingLegacySubscriptionDeletion" in pending_subscriptions,
        "A lone released-client physical deletion must still propagate after pair resolution.")

# Frozen-when-off invariants: nothing may be applied while a category is disabled.
pending_episodes = method_body(MANAGER, "func applyPendingEpisodeStates")
require("guard episodesSyncEnabled" in pending_episodes,
        "Pending episode states must not be applied while episode sync is off.")
require("isICloudAccountSignedOut" in pending_episodes,
        "Pending episode states must not be applied while the iCloud account is signed out.")
pending_subscriptions = method_body(MANAGER, "func applyPendingSubscriptions")
require("guard subscriptionsSyncEnabled" in pending_subscriptions,
        "Pending subscriptions must not be applied (or subscribed over the network) while subscription sync is off.")
require("isICloudAccountSignedOut" in pending_subscriptions,
        "Pending subscriptions must not be applied while the iCloud account is signed out.")
