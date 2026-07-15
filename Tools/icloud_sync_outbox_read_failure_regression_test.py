#!/usr/bin/env python3
"""Pins fail-closed iCloud outbox reads and their transactional ACK boundary."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def method_body(source, signature):
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


def declaration(source, signature):
    start = source.find(signature)
    require(start != -1, f"Missing declaration: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing declaration body: {signature}")
    return source[start:brace]


# Fault-injection contract: a failed read never means an empty, successful read. The
# caller must retain unresolved work and must not run its apply/ACK/complete action.
def fault_injected_operation(read_succeeds, action):
    unresolved = False
    if not read_succeeds:
        unresolved = True
        return unresolved, False
    action()
    return unresolved, True


for operation in ["drain", "live apply", "pending apply", "ack"]:
    actions = []
    unresolved, completed = fault_injected_operation(False, lambda: actions.append(operation))
    require(unresolved and not completed and not actions,
            f"Injected {operation} read failure must fail closed.")


# The shared reader must propagate context, fetch, and malformed-row failures.
outbox_read_decl = declaration(LOCAL, "nonisolated static func localOutboxEntries")
outbox_read = method_body(LOCAL, "nonisolated static func localOutboxEntries")
require("async throws -> [ICCloudSyncOutboxSnapshot]" in outbox_read_decl,
        "The shared local outbox read must throw instead of representing failure as an empty array.")
require("try await context.perform" in outbox_read and "try context.fetch(request)" in outbox_read,
        "Context/fetch failures must propagate through the asynchronous outbox reader.")
require("(try? context.fetch(request)) ?? []" not in outbox_read,
        "A failed outbox fetch must never become an empty successful read.")


# (a) Drain must expose success, report the persistence error, and stop every caller
# before send/complete. Account changes and cancellation after the await remain gates.
drain_decl = declaration(LOCAL, "func drainLocalOutbox()")
drain = method_body(LOCAL, "func drainLocalOutbox()")
require("async -> Bool" in drain_decl and "try await Self.localOutboxEntries" in drain,
        "Outbox drain must return a success result backed by the throwing reader.")
require("handleLocalPersistenceFailure(error)" in drain and "return false" in drain,
        "A drain read failure must become a visible unresolved retry, not empty success.")
require("generation == cloudAccountGeneration" in drain
        and "defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName" in drain
        and "!Task.isCancelled" in drain,
        "Drain must revalidate account generation, identity and cancellation after its read await.")
for signature in ["func performManualSync() async throws", "func performLowPrioritySync() async"]:
    sync_path = method_body(MANAGER, signature)
    drain_call = sync_path.find("await drainLocalOutbox()")
    send_call = sync_path.find("sendChangesAndApplyCallbackOutcomes")
    require(drain_call != -1 and send_call != -1 and drain_call < send_call,
            f"{signature} must drain before sending.")
    require("!hasUnresolvedSyncFailures" in sync_path[drain_call:send_call],
            f"{signature} must stop after a failed drain instead of allowing Complete.")


# (b) Live payloads are staged durably before the throwing outbox read, then the read
# must succeed before any remote apply. Parked replay follows the same fail-closed rule.
fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
first_outbox_read = fetched.find("try await Self.localOutboxEntries")
require(first_outbox_read != -1,
        "Live remote apply must use the throwing outbox reader.")
require(fetched.find("stagePendingSubscriptionStates") < first_outbox_read,
        "Fetched subscription deletions must be parked before an outbox read can fail.")
later_outbox_read = fetched.find("try await Self.localOutboxEntries", first_outbox_read + 1)
require(later_outbox_read != -1
        and fetched.find("stagePendingEpisodeStates") < later_outbox_read
        and fetched.find("stagePendingSubscriptionStates", first_outbox_read + 1) < later_outbox_read,
        "Fetched modifications must be parked before their outbox read can fail.")
require(fetched.count("handleLocalPersistenceFailure(error)") >= 4,
        "A live outbox read failure must enter the normal unresolved retry path.")

episode_pending = method_body(REMOTE, "func applyPendingEpisodeStates() async")
episode_worker = method_body(REMOTE, "func applyPendingEpisodeStateBatchInBackground")
outbox_read = episode_worker.find("context.fetch(outboxRequest)")
episode_mutation = episode_worker.find("episode.consumed")
require(outbox_read != -1 and episode_mutation != -1 and outbox_read < episode_mutation,
        "Pending episodes must read the outbox inside their atomic worker before mutation.")
require("context.rollback()" in episode_worker[outbox_read:],
        "A worker outbox-read failure must roll back and retain the staged payload.")
require("generation == cloudAccountGeneration" in episode_pending
        and "episodesSyncEnabled" in episode_pending
        and "defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName" in episode_pending,
        "Pending episode orchestration must revalidate generation, toggle and account.")

pending = method_body(REMOTE, "func applyPendingSubscriptions() async")
subscription_worker = method_body(
    REMOTE,
    "nonisolated static func applyPendingSubscriptionBatchInBackground",
)
read = subscription_worker.find("context.fetch(outboxRequest)")
apply = subscription_worker.find("func applyChange", read)
require(read != -1 and apply != -1 and read < apply,
        "Pending subscriptions must read the outbox in their atomic worker before applying parked data.")
require("context.rollback()" in subscription_worker[read:],
        "Pending subscriptions must retain parked data after an outbox read failure.")
require("generation == cloudAccountGeneration" in pending
        and "subscriptionsSyncEnabled" in pending
        and "subscriptionApplyIsValid" in subscription_worker,
        "Pending subscriptions must revalidate generation, toggle and account around the suspended read.")


# (c) ACK and remote-resolution fetches throw. Revision maps and CKSyncEngine changes
# are consumed only after the corresponding Core Data save succeeds.
ack_decl = declaration(REMOTE, "nonisolated static func acknowledgeLocalOutboxOperationsInBackground")
ack = method_body(REMOTE, "nonisolated static func acknowledgeLocalOutboxOperationsInBackground")
require("async throws" in ack_decl and "try context.fetch(request)" in ack,
        "CloudKit ACK must fail closed when its outbox fetch fails.")
require("(try? context.fetch(request)) ?? []" not in ack,
        "CloudKit ACK must not treat a fetch error as an absent outbox row.")
require("try context.save()" in ack and "removePendingRecordChanges" not in ack,
        "The private ACK transaction must commit before MainActor may touch CKSyncEngine state.")
ack_consume = method_body(REMOTE, "func consumeLocalOutboxAcknowledgementResult")
require("removePendingRecordChanges" in ack_consume
        and "currentRevision == acknowledgedAttempt.revision" in ack_consume
        and "currentOperation == acknowledgedAttempt.operation" in ack_consume,
        "Post-save ACK consumption must preserve a newer local revision with the same record name.")

sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
require(sent.count("try await Self.acknowledgeLocalOutboxOperationsInBackground(") == 1,
        "Save and delete ACKs must share one awaited private transaction.")
require("handleLocalPersistenceFailure(error)" in sent,
        "Sent callbacks must keep failed ACKs unresolved and retryable.")

require("func pendingDeleteAttempt(" in MANAGER
        and "func acknowledgeDeleteAttempts(" in MANAGER
        and "func takeDeleteAttempt(" not in MANAGER,
        "Delete-attempt revisions must be peeked and consumed only after durable local ACK.")
pending_delete_attempt = method_body(MANAGER, "func pendingDeleteAttempt(")
delete_attempt_commit = method_body(MANAGER, "func acknowledgeDeleteAttempts(")
require("removeFirst" not in pending_delete_attempt
        and "removeValue" not in pending_delete_attempt
        and "revisions.removeFirst()" in delete_attempt_commit,
        "Reading a delete-attempt revision must be non-consuming until local ACK commits it.")
delete_ack = sent.find("try await Self.acknowledgeLocalOutboxOperationsInBackground(")
delete_attempt_ack = sent.find("syncEngineCallbackGate.acknowledgeDeleteAttempts(")
delete_checkpoint = sent.find("recordInitialUploadRecordsResolved(resolvedInitialUploadDeleteRecordIDs)")
require(delete_ack != -1 and delete_attempt_ack != -1 and delete_checkpoint != -1
        and delete_ack < delete_attempt_ack < delete_checkpoint,
        "Delete attempts and initial checkpoints must advance only after durable local ACK.")

resolve_decl = declaration(REMOTE, "func deleteResolvedLocalOutboxEntries")
resolve = method_body(REMOTE, "func deleteResolvedLocalOutboxEntries")
consume = method_body(REMOTE, "func consumeResolvedLocalOutboxEntries")
require("throws -> LocalOutboxResolutionCommit" in resolve_decl
        and "try context.fetch(request)" in resolve,
        "Remote outbox resolution must expose fetch failure and a later commit token.")
for revision_map in [
    "localOutboxRevisionsToDelete",
    "localOutboxRevisionsToAcknowledge",
    "localOutboxRevisionsToRearm",
]:
    require(f"{revision_map} = [:]" not in resolve,
            f"{revision_map} must survive a resolution fetch/save failure.")
    require(f"{revision_map}[recordName] == revision" in consume,
            f"{revision_map} must consume only the exact successfully-saved revision.")
require("removePendingRecordChanges" not in resolve
        and "removePendingRecordChanges" in consume,
        "Resolution may remove CKSyncEngine pending work only in its post-save commit.")

flush = method_body(REMOTE, "func flushRemoteApplyBatchBeforeYield")
prepare = flush.find("try deleteResolvedLocalOutboxEntries()")
save = flush.find("saveReturningError")
commit = flush.find("consumeResolvedLocalOutboxEntries")
require(prepare != -1 and save != -1 and commit != -1 and prepare < save < commit,
        "A remote batch must prepare, save, then consume its exact resolution maps once.")

subscription_consume = method_body(REMOTE, "func consumeSubscriptionApplyBatchResult(")
prepare = subscription_worker.find("removedOutboxRevisions")
unsubscribe = subscription_worker.find("func unsubscribe", prepare)
save = subscription_worker.rfind("context.save()")
commit = subscription_consume.find("for (recordName, removedRevision)")
require(prepare != -1 and unsubscribe != -1 and save != -1 and commit != -1
        and prepare < unsubscribe < save,
        "Subscription cleanup must commit its exact outbox resolution with the unsubscribe.")
require("localOutboxSnapshotCache.removeValue" in subscription_consume[commit:],
        "Committed subscription resolution maps must be consumed only after the worker save.")

print("iCloud outbox read failure regression checks passed")
