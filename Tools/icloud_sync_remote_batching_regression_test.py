#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
EPISODE = (ROOT / "Classes" / "Model" / "CDEpisode.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
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


fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
require("processFetchedModificationBatch" in fetched,
        "Fetched changes must use an explicit bounded modification-batch path.")
require("processFetchedDeletionBatch" in fetched,
        "Fetched deletions must be bounded and yield just like modifications.")

modification_batch = method_body(REMOTE, "func processFetchedModificationBatch")
require("resolvedEpisodesForRemoteBatch" in modification_batch,
        "Each remote chunk must resolve all episode hashes with one IN fetch.")
require("prepareSyncItemMetadataContextBatch" in modification_batch
        and "syncItemMetadataSnapshot" in modification_batch
        and "upsertSyncItemMetadata" in modification_batch,
        "Each remote chunk must prefetch and update its indexed episode clocks in the same Core Data transaction.")
require("mergePendingEpisodeStates" not in modification_batch
        and fetched.find("stagePendingEpisodeStates") < fetched.find("processFetchedModificationBatch"),
        "Episode payloads must use bounded indexed staging before each chunk, never a growing plist merge.")
require("persistKnownRecordSystemFields" in fetched,
        "Known CloudKit system fields must be persisted off-main in batches.")

flush = method_body(REMOTE, "func flushRemoteApplyBatchBeforeYield")
require("saveReturningError" in flush and "flushPendingPayloads" not in flush,
        "Every durable Core Data chunk must commit indexed metadata before a yield without serializing a growing plist.")
require("flushEpisodeLocalModifiedDates" not in flush and "flushSubscriptionMetadata" not in flush,
        "Indexed clocks/fingerprints must join the Core Data save, not a second post-commit plist flush.")

pending_episodes = method_body(REMOTE, "func applyPendingEpisodeStates")
pending_subscriptions = method_body(REMOTE, "func applyPendingSubscriptions")
require("pendingEpisodeStateBatch" in pending_episodes,
        "Pending episode replay must fetch bounded indexed rows.")
require("pendingSubscriptionStateBatch" in pending_subscriptions and
        "removePendingSubscriptionStates" in pending_subscriptions,
        "Pending subscription replay must page indexed rows and remove only committed payloads.")
for body, label in [(pending_episodes, "episode"), (pending_subscriptions, "subscription")]:
    require("performSynchronousRemoteApplyBatch {" in body and "await Task.yield()" in body,
            f"Pending {label} replay must commit and yield between chunks.")

reset = method_body(REMOTE, "func resetForICloudAccountTransition")
require("flushPendingPayloads" not in reset and "pendingPayloadsWriteWorkItem" not in reset,
        "Account transitions must not depend on the retired delayed full-plist writer.")
account_reconciliation = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require("deleteAllPendingSubscriptionStates" in account_reconciliation and
        "shouldResetPendingRemoteStates" in account_reconciliation,
        "A changed account must remove the old account's durable pending subscription rows.")
require("flushEpisodeLocalModifiedDates" not in reset
        and "episodeLocalModifiedDatesWriteWorkItem" not in reset,
        "Account transitions must not depend on delayed whole-dictionary clock writers after clocks moved into Core Data transactions.")

require("ICScheduleTranscriptCacheRemovalForEpisodeHash" in EPISODE,
        "Consumed setters must enqueue coalesced transcript cleanup instead of scanning synchronously.")
cleanup = method_body(EPISODE, "static void ICScheduleTranscriptCacheRemovalForEpisodeHash")
require("dispatch_async" in cleanup and "contentsOfDirectoryAtPath" not in cleanup,
        "The episode setter path must not enumerate the transcript directory on the main thread.")

known_batch = method_body(METADATA, "nonisolated static func persistKnownRecordSystemFields")
require("Task.detached(priority: .utility)" in known_batch
        and "newBackgroundContext()" in known_batch
        and "context.save()" in known_batch,
        "Known-record archival and indexed persistence must run off the main actor.")

sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
persist_sent = sent.find("try await Self.persistKnownRecordSystemFields(")
device_loop = sent.find("for record in event.savedRecords")
acknowledge_saves = sent.find("acknowledgeLocalOutboxRecords(event.savedRecords)")
checkpoint_saves = sent.find("recordInitialUploadRecordsSaved(event.savedRecords.map")
require(persist_sent != -1 and "rememberServerRecord(record)" not in sent,
        "A sent page must archive known system fields off-main as one indexed batch, never one atomic main-actor file write per record.")
require(persist_sent < acknowledge_saves and persist_sent < checkpoint_saves,
        "Known system fields must be durable before sent records are acknowledged or their backfill checkpoint advances.")
post_await_guard = sent[persist_sent:device_loop]
require("generation == cloudAccountGeneration" in post_await_guard
        and "syncEngine === self.syncEngine" in post_await_guard,
        "The sent callback must revalidate account generation and engine identity after the archival await.")

# Remote subscription apply formerly touched four growing dictionaries per feed, causing
# quadratic read/serialize/write work. A pending chunk now preloads exact + canonical row
# names once and every winner mutates those objects before the same bounded Core Data save.
require("prepareSyncItemMetadataContextBatch" in pending_subscriptions
        and "subscriptionRecordName(forFeedURL:" in pending_subscriptions
        and "subscriptionTombstoneRecordName(forFeedURL:" in pending_subscriptions,
        "A subscription chunk must prefetch both canonical pair identities once.")
for removed_api in [
    "func subscriptionRecordURLs()",
    "func subscriptionLocalModifiedDates()",
    "func subscriptionLocalStates()",
    "func subscriptionPayloadHashes()",
    "func scheduleSubscriptionMetadataWrite",
    "func flushSubscriptionMetadata",
]:
    require(removed_api not in METADATA,
            f"The quadratic whole-plist subscription metadata API must stay removed: {removed_api}")

print("iCloud remote batching regression checks passed")
