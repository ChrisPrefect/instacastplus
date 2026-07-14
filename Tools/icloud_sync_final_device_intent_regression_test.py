#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


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


require('finalDeviceRecordUpdatePendingKey = "ICiCloudSyncFinalDeviceRecordUpdatePending"' in MANAGER,
        "Turning the last switch off needs a durable final-device intent key.")
file_keys = method_body(MANAGER, "nonisolated static var fileBackedSyncMetadataKeys")
require("finalDeviceRecordUpdatePendingKey" in file_keys,
        "The final-device intent must use the atomic file-backed metadata store.")

options = method_body(MANAGER, "@objc func syncOptionsChanged")
persist = options.find("persistFinalDeviceRecordUpdateIntent()")
signed_out = options.find("isICloudAccountSignedOut")
require(-1 not in (persist, signed_out) and persist < signed_out,
        "The last toggle must persist its final-device intent even when the phone is already offline/signed out.")

start = method_body(MANAGER, "@objc func start")
require("anySyncEnabled || hasPendingFinalDeviceRecordUpdate" in start
        and "initializeSyncEngineIfNeeded()" in start
        and "refreshAccountStatus()" in start,
        "Cold start with all categories off must still verify the account and resume the durable device update.")

reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require(reconcile.find("setICloudAccountIdentityVerified(true)")
        < reconcile.find("resumePendingFinalDeviceRecordUpdateIfNeeded()"),
        "A pending final device record must resume only after the real iCloud account is verified.")

final_send = method_body(MANAGER, "func sendFinalDeviceRecordUpdate")
require("setError(error)" in final_send
        and 'scheduleSyncRetryAfterFailure(error: error, reason: "finalDeviceRecord")' in final_send,
        "Final all-off device sends must never swallow their CloudKit error.")
require("clearPendingFinalDeviceRecordUpdateIntent()" not in final_send,
        "The durable intent may clear only from the exact CloudKit save acknowledgement, not sendChanges returning.")

sent = method_body(REMOTE, "func handleSentRecordZoneChanges")
match_ack = method_body(REMOTE, "func deviceRecordAcknowledgementMatchesCurrentSyncOptions")
for option in ["episodesEnabled", "subscriptionsEnabled", "settingsEnabled"]:
    require(option in match_ack,
            f"A device acknowledgement must compare the current {option} value before clearing the intent.")
require("clearPendingFinalDeviceRecordUpdateIntent()" in sent
        and "deviceRecordID(for: deviceID)" in sent
        and "deviceRecordAcknowledgementMatchesCurrentSyncOptions(payload)" in sent,
        "Only an acknowledgement of this installation's currently desired ICDevice payload may clear the final intent.")
require("queueDeviceRecord(scheduleSync: false)" in sent
        and "requiresImmediateFinalDeviceRecordResend" in sent,
        "A stale in-flight device acknowledgement must retain the intent and queue the current payload without starting a nested send from the callback.")

send_wrapper = method_body(MANAGER, "func sendChangesAndApplyCallbackOutcomes")
require("requiresImmediateFinalDeviceRecordResend" in send_wrapper
        and "continue" in send_wrapper,
        "The outer send loop must immediately send the current device payload after the stale acknowledgement callback returns.")


def acknowledgement_transition(desired: dict[str, bool], acknowledged: dict[str, object]) -> tuple[bool, bool]:
    """Returns (clear durable intent, queue current payload)."""
    keys = ("episodesEnabled", "subscriptionsEnabled", "settingsEnabled")
    matches = all(type(acknowledged.get(key)) is bool
                  and acknowledged[key] == desired[key]
                  for key in keys)
    return matches, not matches


# Sequence proof for the real race:
# 1. An ON payload is already in flight.
# 2. The user turns the last category off; the durable all-off intent is set, but the
#    duplicate pending key cannot replace the in-flight save yet.
# 3. The old ON acknowledgement arrives. It must not clear the all-off intent; after
#    that callback returns, the now-unblocked device key must be queued and sent again.
all_off = {"episodesEnabled": False, "subscriptionsEnabled": False, "settingsEnabled": False}
old_on_ack = {"episodesEnabled": True, "subscriptionsEnabled": False, "settingsEnabled": False}
require(acknowledgement_transition(all_off, old_on_ack) == (False, True),
        "An old ON acknowledgement must retain and immediately requeue the durable all-off intent.")
require(acknowledgement_transition(all_off, all_off) == (True, False),
        "Only the exact false/false/false acknowledgement may complete the all-off intent.")
require(acknowledgement_transition(all_off, {}) == (False, True),
        "A malformed/legacy device acknowledgement must not be mistaken for an exact all-off payload.")

retry = method_body(MANAGER, "func scheduleSyncRetryAfterFailure(code:")
require("anySyncEnabled || hasPendingFinalDeviceRecordUpdate" in retry
        and "resumePendingFinalDeviceRecordUpdateIfNeeded()" in retry,
        "Automatic retry must remain alive when every user-data category is off.")

status = method_body(MANAGER, "@objc var statusText")
require(status.find("hasPendingFinalDeviceRecordUpdate") < status.find('NSLocalizedString("Aus"'),
        "A pending/failed final device update must be visible instead of always being masked by 'Off'.")

print("iCloud final device-intent regression checks passed")
