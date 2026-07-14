#!/usr/bin/env python3
"""Pins remote-origin suppression to synchronous iCloud mutation scopes.

ICiCloudSyncManager is MainActor-isolated but async methods are reentrant. A
remote apply must therefore never leave `isApplyingRemoteChange` set while it
awaits system-field/staging/outbox I/O, pending-row removal, or Task.yield:
genuine user edits delivered during any such suspension must enter the outbox.
"""
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function: {signature}")
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
    raise AssertionError(f"Unterminated function: {signature}")


def trailing_closure_bodies(source: str, callee: str) -> List[str]:
    bodies: List[str] = []
    pattern = re.compile(rf"{re.escape(callee)}\s*\{{")
    for match in pattern.finditer(source):
        brace = source.find("{", match.start())
        depth = 0
        for index in range(brace, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    bodies.append(source[brace + 1:index])
                    break
        else:
            raise AssertionError(f"Unterminated closure call: {callee}")
    return bodies


helper_signature = "func performSynchronousRemoteApplyBatch("
helper = function_body(REMOTE, helper_signature)
declaration = REMOTE[REMOTE.find(helper_signature):REMOTE.find("{", REMOTE.find(helper_signature))]
require(
    "_ mutations: () throws -> Void" in declaration
    and "async" not in declaration
    and "await" not in helper,
    "Remote-origin suppression must use a synchronous, non-async closure so no caller can "
    "suspend while isApplyingRemoteChange is set.",
)
require(
    "let wasApplyingRemoteChange = isApplyingRemoteChange" in helper
    and "isApplyingRemoteChange = true" in helper
    and "defer" in helper
    and "isApplyingRemoteChange = wasApplyingRemoteChange" in helper
    and "try mutations()" in helper
    and "flushRemoteApplyBatchBeforeYield()" in helper,
    "The synchronous helper must set/restore remote origin around the mutation closure and "
    "its deterministic save, including throwing/error exits.",
)

paths = {
    "fetched changes": function_body(REMOTE, "func handleFetchedRecordZoneChanges("),
    "conflict record": function_body(REMOTE, "func applyRemoteRecord("),
    "pending episodes": function_body(REMOTE, "func applyPendingEpisodeStates("),
    "pending subscriptions": function_body(REMOTE, "func applyPendingSubscriptions("),
    "subscription sort": function_body(REMOTE, "func applySubscriptionListSortIfNeeded("),
}
minimum_helper_calls = {
    "fetched changes": 2,
    "conflict record": 1,
    "pending episodes": 1,
    "pending subscriptions": 2,
    "subscription sort": 1,
}
for name, body in paths.items():
    require(
        body.count("performSynchronousRemoteApplyBatch {") >= minimum_helper_calls[name],
        f"{name} must apply every bounded remote mutation batch through the synchronous helper.",
    )
    require(
        "isApplyingRemoteChange = true" not in body
        and "isApplyingRemoteChange = false" not in body
        and "wasApplyingRemoteChange" not in body,
        f"{name} still owns the suppression flag across an async/reentrant function scope.",
    )

closures = trailing_closure_bodies(REMOTE, "performSynchronousRemoteApplyBatch")
require(len(closures) >= 7, "Every fetched/replay/list-sort mutation batch must use the helper.")
for closure in closures:
    require(
        "await" not in closure
        and "Task.yield" not in closure
        and "persistKnownRecordSystemFields" not in closure
        and "stagePending" not in closure
        and "localOutboxEntries" not in closure
        and "removePendingEpisodeStates" not in closure
        and "removePendingSubscriptionStates" not in closure,
        "System-field, staging, outbox, pending-removal, and yield awaits must stay outside "
        "the synchronous remote-mutation scope.",
    )

fetched = paths["fetched changes"]
require(
    fetched.find("removeKnownRecordSystemFields") < fetched.find("performSynchronousRemoteApplyBatch {")
    and fetched.find("persistKnownRecordSystemFields")
    < fetched.rfind("performSynchronousRemoteApplyBatch {")
    < fetched.find("removePendingEpisodeStates"),
    "Fetched system fields and pending rows must be staged/removed outside each synchronous "
    "Core Data mutation+flush scope.",
)

conflict = paths["conflict record"]
require(
    conflict.find("performSynchronousRemoteApplyBatch {")
    < conflict.find("removePendingEpisodeStates"),
    "Conflict repair must restore local-edit observation before awaiting pending-state removal.",
)

pending_episodes = paths["pending episodes"]
require(
    pending_episodes.find("performSynchronousRemoteApplyBatch {")
    < pending_episodes.find("removePendingEpisodeStates")
    < pending_episodes.find("await Task.yield()"),
    "Pending episode replay must release remote-origin suppression before removal I/O and yield.",
)

pending_subscriptions = paths["pending subscriptions"]
list_settings = pending_subscriptions.find("if let listSettingsSnapshot")
require(list_settings != -1, "Missing pending subscription-list settings replay.")
list_settings_scope = pending_subscriptions[list_settings:]
require(
    list_settings_scope.find("performSynchronousRemoteApplyBatch {")
    < list_settings_scope.find("await applySubscriptionListSortIfNeeded()")
    < list_settings_scope.find("removePendingSubscriptionStates"),
    "List settings must leave their synchronous suppression scope before chunked sort awaits "
    "and before pending-row removal.",
)

subscription_sort = paths["subscription sort"]
require(
    subscription_sort.find("performSynchronousRemoteApplyBatch {")
    < subscription_sort.find("await Task.yield()"),
    "Each manual-sort chunk must restore local-edit observation before yielding.",
)

require(
    "!isApplyingRemoteChange" in function_body(LOCAL, "func defaultsDidChange(")
    and "!isApplyingRemoteChange" in function_body(LOCAL, "func coreDataDidChange(")
    and "guard isStarted, !isApplyingRemoteChange" in function_body(LOCAL, "func journalLocalOutboxObjects("),
    "Remote-origin guards must remain in the local observers; the fix is to narrow the flag's "
    "lifetime, not to allow remote echoes into the outbox.",
)

flush = function_body(REMOTE, "func flushRemoteApplyBatchBeforeYield(")
failure = function_body(REMOTE, "func handleLocalPersistenceFailure(")
require(
    "saveReturningError()" in flush
    and "remoteAppliedObjectIDs.removeAll()" in flush
    and "remoteAppliedObjectIDs.removeAll()" in failure,
    "Successful flushes and save failures must retain their exact remote-object-ID cleanup.",
)


@dataclass
class ReentrantApplyModel:
    is_applying_remote: bool = False
    local_outbox: List[str] = field(default_factory=list)
    remote_flushes: int = 0

    def observe_edit(self, label: str) -> None:
        if not self.is_applying_remote:
            self.local_outbox.append(label)

    def synchronous_remote_batch(self, mutations: Callable[[], None]) -> None:
        previous = self.is_applying_remote
        self.is_applying_remote = True
        try:
            mutations()
            self.remote_flushes += 1
        finally:
            self.is_applying_remote = previous


# Old async-wide scope: a user edit during an await is silently discarded.
old = ReentrantApplyModel(is_applying_remote=True)
old.observe_edit("user-edit-during-await")
require(old.local_outbox == [], "The model must reproduce the old swallowed-edit failure.")

# New phase ordering: every suspension happens with the flag restored. Only the
# synchronous remote mutation notification is suppressed as an echo.
fixed = ReentrantApplyModel()
fixed.observe_edit("during-system-field-await")
fixed.synchronous_remote_batch(lambda: fixed.observe_edit("remote-echo"))
fixed.observe_edit("during-pending-removal-await")
fixed.observe_edit("during-yield")
require(
    fixed.local_outbox == [
        "during-system-field-await",
        "during-pending-removal-await",
        "during-yield",
    ]
    and fixed.remote_flushes == 1
    and not fixed.is_applying_remote,
    "Local edits in every reentrant phase must survive while the synchronous remote echo stays suppressed.",
)

print("iCloud remote-apply reentrancy regression checks passed")
