#!/usr/bin/env python3
"""Pins Phase 2: every live episode/subscription metadata path uses indexed rows."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


# The growing whole-library dictionaries are migration input only. Production state must
# have no full-cache/work-item owner left that can accidentally revive their O(n²) writes.
for obsolete in [
    "episodeLocalModifiedDatesCache",
    "episodeLocalModifiedDatesWriteWorkItem",
    "subscriptionRecordURLsCache",
    "subscriptionLocalModifiedDatesCache",
    "subscriptionLocalStatesCache",
    "subscriptionPayloadHashesCache",
    "dirtySubscriptionMetadataKeys",
    "subscriptionMetadataWriteWorkItem",
]:
    require(obsolete not in MANAGER and obsolete not in METADATA,
            f"Live sync must not retain the obsolete whole-plist state: {obsolete}")

for obsolete_signature in [
    "func subscriptionRecordURLs()",
    "func subscriptionRecordURL(for",
    "func setSubscriptionRecordURL",
    "func episodeLocalModifiedDates()",
    "func episodeLocalModifiedDate(for",
    "func setEpisodeLocalModifiedDate",
    "func setEpisodeLocalModifiedDates",
    "func subscriptionLocalModifiedDates()",
    "func subscriptionLocalModifiedDate(for",
    "func setSubscriptionLocalModifiedDate",
    "func subscriptionLocalStates()",
    "func subscriptionLocalState(for",
    "func setSubscriptionLocalState",
    "func mergeSubscriptionLocalStates",
    "func applySubscriptionLocalChanges",
    "func subscriptionPayloadHashes()",
    "func mergeSubscriptionPayloadHashes",
    "func removeSubscriptionPayloadHashes",
    "func scheduleSubscriptionMetadataWrite",
    "func flushSubscriptionMetadata",
]:
    require(obsolete_signature not in METADATA,
            f"Legacy plist API must be migration-only: {obsolete_signature}")

# Main-context changes must prepare one indexed batch and mutate metadata together with the
# feed/episode and outbox rows. There must be no post-transaction plist bookkeeping.
prepare = body(METADATA, "nonisolated static func prepareSyncItemMetadataContextBatch")
require("recordName IN %@" in prepare and "remoteApplyBatchSize" in prepare,
        "Context transactions need bounded indexed prefetches, never per-item fetches.")
context_upsert = body(METADATA, "nonisolated static func upsertSyncItemMetadata(\n        _ writes")
require("metadataBatch.context" in context_upsert
        and "context.save()" not in context_upsert,
        "The context-scoped metadata helper must join its caller's Core Data transaction.")

journal = body(LOCAL, "func journalLocalOutboxObjects")
require("metadataWrites" in journal and "persistLocalOutboxMutations" in journal,
        "Local episode/subscription journaling must create indexed metadata writes.")
persist = body(LOCAL, "func persistLocalOutboxMutations")
require("metadataWrites" in persist and "prepareSyncItemMetadataContextBatch" in persist
        and "metadataBatch: inout ICCloudSyncItemMetadataContextBatch" in LOCAL
        and "upsertSyncItemMetadata" in LOCAL,
        "Outbox and item metadata must be prevalidated and mutated in the same context.")

# Initial pages persist their clocks/fingerprints off-main before any CKSyncEngine IDs are
# exposed, and re-check the account/generation after the suspension point.
initial = body(MANAGER, "func applyInitialUploadPlan")
metadata_save = initial.find("upsertSyncItemMetadata")
first_queue = min(position for position in [
    initial.find("applyInitialEpisodeQueue"),
    initial.find("applyInitialSubscriptionQueue"),
] if position >= 0)
require(0 <= metadata_save < first_queue,
        "Initial upload metadata must be durable before record IDs enter CKSyncEngine.")
require("initialUploadPlanIsCurrent" in initial[metadata_save:first_queue],
        "Initial upload must revalidate account/generation after the metadata await.")

# CKSyncEngine's <=250 callback page may perform one bounded indexed lookup. It must never
# deserialize the complete clocks/URL dictionaries merely to materialize a handful of IDs.
callback = body(ENGINE, "nonisolated static func materializeRecordsForSyncEngineCallback")
require("syncItemMetadataByRecordNameForSyncEngineCallback" in callback,
        "Callback materialization must use the indexed metadata lookup for its current page.")
callback_lookup = body(ENGINE, "nonisolated static func syncItemMetadataByRecordNameForSyncEngineCallback")
require("recordName IN %@" in callback_lookup
        and "maximumRecordZoneChangesPerBatch" in callback_lookup
        and "performAndWait" in callback_lookup,
        "The delegate callback needs one synchronous indexed lookup bounded to its <=250 page.")
snapshot = body(ENGINE, "nonisolated static func syncEngineCallbackSnapshot")
for obsolete in ["subscriptionRecordURLs", "episodeLocalModifiedDates", "subscriptionLocalModifiedDates"]:
    require(obsolete not in snapshot,
            f"Callback snapshots must not read the whole legacy dictionary: {obsolete}")

# Remote chunks preload metadata once, apply conflicts, update metadata, then save/yield.
modifications = body(REMOTE, "func applyPendingEpisodeStateBatchInBackground")
require("prepareSyncItemMetadataContextBatch" in modifications
        and "upsertSyncItemMetadata" in modifications,
        "Remote episode chunks must read/write indexed clocks in their Core Data transaction.")
require("episodeSyncItemMetadataIdentityWrite" in modifications
        and "updating: []" in modifications
        and modifications.find("updating: []") < modifications.find("episode.consumed"),
        "A corrupt/colliding episode metadata identity must abort the whole chunk before any episode object is mutated.")
single_remote = body(REMOTE, "func applyRemoteRecord")
require("applyPendingEpisodeStateBatchInBackground" in single_remote,
        "Server-conflict episode apply must validate/insert its identity before mutating local state.")
pending_episodes = body(REMOTE, "func applyPendingEpisodeStates")
require("applyPendingEpisodeStateBatchInBackground" in pending_episodes,
        "Pending episode replay must validate all row identities before mutating a chunk.")
pending_subscriptions = body(REMOTE, "func applyPendingSubscriptions")
subscription_worker = body(
    REMOTE,
    "nonisolated static func applyPendingSubscriptionBatchInBackground",
)
require("applyPendingSubscriptionBatchInBackground" in pending_subscriptions
        and "prepareSyncItemMetadataContextBatch" in subscription_worker
        and "metadataBatch: &metadataBatch" in subscription_worker
        and "func updateMetadata" in subscription_worker
        and "upsertSyncItemMetadata" in subscription_worker,
        "Remote subscription chunks must use one indexed batch, not N+1 metadata reads.")
require("func ensureMetadataMapping" in subscription_worker
        and "subscriptionRecordName(forFeedURL:" in subscription_worker
        and "subscriptionTombstoneRecordName(forFeedURL:" in subscription_worker
        and "widersprüchliche Identität" in subscription_worker,
        "A malformed CloudKit record must not map one record hash onto another feed before subscription side effects run.")

# Identity is not opened until pending/unbound rows and legacy files are safely bound to the
# verified CloudKit user. Cleanup paths remove account-scoped rows too.
reconcile = body(REMOTE, "func reconcileAvailableICloudAccount")
verified = reconcile.find("setICloudAccountIdentityVerified(true)")
for operation in ["bindSyncItemMetadata", "migrateLegacySyncItemMetadataIfNeeded"]:
    require(0 <= reconcile.find(operation) < verified,
            f"{operation} must finish before the verified-account capture gate opens.")

delete_all = body(MANAGER, "@objc func deleteAllICloudDataWithCompletion")
app_reset = body(MANAGER, "@objc func prepareForLocalAppResetWithCompletion")
require("deleteSyncItemMetadata" in delete_all,
        "Delete-all must remove indexed item metadata.")
require("deleteSyncItemMetadata" in app_reset,
        "A local app reset must remove indexed item metadata before completion.")

prune = body(METADATA, "func pruneEpisodeLocalModifiedDatesIfNeeded")
require("pruneEpisodeSyncItemMetadata" in prune,
        "Episode metadata pruning must delete bounded indexed rows, not filter a full map.")
prune_rows = body(METADATA, "nonisolated static func pruneEpisodeSyncItemMetadata")
require("let currentCursor = cursor" in prune_rows
        and "if let currentCursor" in prune_rows,
        "A background Core Data closure must capture an immutable page cursor, not the loop's concurrently mutated variable.")

print("iCloud indexed-metadata Phase-2 integration regression checks passed")
