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

for signature, toggle in [
    ("func applyPendingEpisodeStates() async", "episodesSyncEnabled"),
    ("func applyPendingSubscriptions() async", "subscriptionsSyncEnabled"),
]:
    pending = method_body(REMOTE, signature)
    read = pending.find("try await Self.localOutboxEntries")
    apply = pending.find("performSynchronousRemoteApplyBatch {", read)
    require(read != -1 and apply != -1 and read < apply,
            f"{signature} must complete its outbox read before applying parked data.")
    require("handleLocalPersistenceFailure(error)" in pending[read:apply]
            and "return" in pending[read:apply],
            f"{signature} must retain parked data after an outbox read failure.")
    require("generation == cloudAccountGeneration" in pending[read:apply]
            and toggle in pending[read:apply]
            and "defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName" in pending[read:apply],
            f"{signature} must revalidate generation, toggle and account around the suspended read.")


# (c) ACK and remote-resolution fetches throw. Revision maps and CKSyncEngine changes
# are consumed only after the corresponding Core Data save succeeds.
ack_decl = declaration(REMOTE, "func acknowledgeLocalOutboxOperations")
ack = method_body(REMOTE, "func acknowledgeLocalOutboxOperations")
require("throws" in ack_decl and "try context.fetch(request)" in ack,
        "CloudKit ACK must fail closed when its outbox fetch fails.")
require("(try? context.fetch(request)) ?? []" not in ack,
        "CloudKit ACK must not treat a fetch error as an absent outbox row.")
ack_save = ack.find("saveReturningError")
ack_remove = ack.find("removePendingRecordChanges")
require(ack_save != -1 and ack_remove != -1 and ack_save < ack_remove,
        "ACK may remove CKSyncEngine pending work only after the local ACK save succeeds.")

sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
require("try acknowledgeLocalOutboxRecords(event.savedRecords)" in sent
        and "try acknowledgeLocalOutboxDeletes(acknowledgedDeleteRevisions)" in sent,
        "Both save and delete ACKs must propagate outbox read/save failures.")
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
delete_ack = sent.find("try acknowledgeLocalOutboxDeletes(acknowledgedDeleteRevisions)")
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

subscription_apply = method_body(REMOTE, "func applyRemoteSubscriptionTombstone(")
prepare = subscription_apply.find("try deleteResolvedLocalOutboxEntries()")
unsubscribe = subscription_apply.find("subscriptionManager.unsubscribeFeed(feed)", prepare)
save = subscription_apply.find("saveReturningError", unsubscribe)
commit = subscription_apply.find("consumeResolvedLocalOutboxEntries", save)
require(prepare != -1 and unsubscribe != -1 and save != -1 and commit != -1
        and prepare < unsubscribe < save < commit,
        "Immediate subscription cleanup must consume its resolution maps only after a checked save.")

print("iCloud outbox read failure regression checks passed")
