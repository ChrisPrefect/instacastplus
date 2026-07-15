#!/usr/bin/env python3
"""Pins singleton payload intents across unknown/same/switched iCloud accounts."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
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


intent_struct = MANAGER[MANAGER.find("struct PendingSingletonUploadIntent"):]
intent_struct = intent_struct[:intent_struct.find("\n    }")]
require("payloadData" in intent_struct and "payloadDictionary" in MANAGER,
        "A singleton intent must retain the exact settings/list/scroll payload across kill/account transitions.")
require("sequence" in intent_struct,
        "Singleton intent ordering must use a durable causal sequence, not wall-clock Date.")

persist = method_body(MANAGER, "func persistPendingSingletonUploadIntent")
require(
    "localOutboxCaptureAccountRecordName" in persist
    and "verifiedAccountRecordNameForLocalCapture" in persist
    and "accountUserRecordNameKey" not in persist,
    "Singleton capture must use verified-or-pending scope, never the stale persisted account ID.",
)
require("payloadData" in persist and "PropertyListSerialization.data" in persist,
        "The payload must be durable before clocks/baselines or CK pending state advance.")
require("nextPendingSingletonSequence" in persist,
        "Every new singleton mutation needs a strictly monotone cross-scope sequence.")

bind = method_body(MANAGER, "func bindPendingSingletonUploadIntents")
require("sourceAccountRecordName" in bind and "accountRecordName" in bind
        and "writePendingSingletonUploadIntents" in bind
        and ".sequence" in bind,
        "Pending/unbound singleton intents must bind atomically after CloudKit verifies the account.")
require("modifiedAt >" not in bind,
        "Clock rollback must not make an older destination intent beat a later pending-scope edit.")
reconcile = method_body(REMOTE, "func reconcileAvailableICloudAccount")
require(
    "bindPendingSingletonUploadIntents" in reconcile
    and "localOutboxUnboundAccountRecordName" in reconcile,
    "Account reconciliation must bind both transition scope and first-install unbound singleton intents.",
)

transition_reset = method_body(REMOTE, "func resetForICloudAccountTransition")
require("preservePendingSingletonIntents: true" in transition_reset,
        "A→B reset must preserve account-scoped and pending singleton payloads until binding.")
transfer = method_body(REMOTE, "func transferablePendingUserChanges")
require("episodesSyncEnabled" not in transfer
        and "subscriptionsSyncEnabled" not in transfer
        and "settingsSyncEnabled" not in transfer,
        "Same-account engine rebuilding must retain paused singleton pending changes too.")

for signature in [
    "nonisolated static func appSettingsRecordForSyncEngineCallback",
    "nonisolated static func listScrollPositionsRecordForSyncEngineCallback",
    "nonisolated static func subscriptionListSettingsRecordForSyncEngineCallback",
]:
    builder = method_body(ENGINE, signature)
    require("payloadDictionary" in builder,
            f"{signature} must upload the captured payload instead of mutable live defaults.")

ack = method_body(REMOTE, "func acknowledgePendingSingletonUpload")
require("accountRecordName" in ack and "intent.revision" in ack,
        "ACK must match the current verified account and exact singleton revision.")

resume = method_body(MANAGER, "func resumePendingSingletonUploadsForVerifiedAccount")
require("refreshPendingSingletonIntentForCurrentLocalState" in resume,
        "A→B→A must compare each old account payload with current live Settings/Scroll before queueing.")
refresh = method_body(MANAGER, "func refreshPendingSingletonIntentForCurrentLocalState")
require("singletonIntentPayloadMatchesCurrentState" in refresh
        and "persistPendingSingletonUploadIntent" in refresh,
        "A mismatched old account payload must become a new causal revision of the current local state.")
restore = method_body(MANAGER, "func restorePendingSingletonUploadMetadata")
require("syncedSettingsHash(payload:" in restore,
        "Settings baseline must describe the stored/sent payload, never unrelated live defaults.")


class ScopedIntentStore:
    def __init__(self):
        self.rows = []

    def capture(self, scope, record, revision, sequence, changed_at, payload):
        self.rows = [r for r in self.rows if not (r["scope"] == scope and r["record"] == record)]
        self.rows.append({"scope": scope, "record": record, "revision": revision,
                          "sequence": sequence, "changed_at": changed_at, "payload": payload})

    def bind(self, source, account):
        sources = [r for r in self.rows if r["scope"] == source]
        self.rows = [r for r in self.rows if r["scope"] != source]
        for source_row in sources:
            candidates = [r for r in self.rows
                          if r["scope"] == account and r["record"] == source_row["record"]]
            winner = max(candidates + [source_row], key=lambda r: r["sequence"])
            self.rows = [r for r in self.rows
                         if not (r["scope"] == account and r["record"] == source_row["record"])]
            winner = dict(winner)
            winner["scope"] = account
            self.rows.append(winner)

    def acknowledge(self, current_account, record, revision):
        before = len(self.rows)
        self.rows = [r for r in self.rows if not (
            r["scope"] == current_account and r["record"] == record and r["revision"] == revision
        )]
        return len(self.rows) != before


# A signed out -> edit in pending scope -> B verified: B gets the exact edit; old A stays isolated.
switched = ScopedIntentStore()
switched.capture("A", "settings_app", "a1", 1, 10, {"theme": "old-A"})
# The causal edit is newer although the wall clock moved backwards.
switched.capture("pending-1", "settings_app", "p1", 2, 5, {"theme": "offline-edit"})
switched.bind("pending-1", "B")
require(any(r["scope"] == "B" and r["payload"]["theme"] == "offline-edit" for r in switched.rows),
        "An offline edit must bind to newly verified B, not stale A.")
require(any(r["scope"] == "A" and r["revision"] == "a1" for r in switched.rows),
        "Foreign A intent must remain isolated across A→B.")
require(not switched.acknowledge("B", "settings_app", "a1")
        and any(r["scope"] == "B" and r["revision"] == "p1" for r in switched.rows),
        "A stale A ACK must never clear B's pending revision.")

# Same-A relogin binds the pending edit back to A and the newer edit wins.
same = ScopedIntentStore()
same.capture("A", "settings_app", "a1", 4, 100, {"theme": "old"})
same.capture("pending-2", "settings_app", "p2", 5, 50, {"theme": "new"})
same.bind("pending-2", "A")
require(len(same.rows) == 1 and same.rows[0]["scope"] == "A"
        and same.rows[0]["revision"] == "p2" and same.rows[0]["payload"]["theme"] == "new",
        "Same-account relogin must preserve the newer offline payload exactly once.")


def refresh_for_current_local_state(row, current_payload, next_revision, next_sequence):
    if row["payload"] == current_payload:
        return row
    refreshed = dict(row)
    refreshed.update(revision=next_revision, sequence=next_sequence, payload=current_payload)
    return refreshed


old_a_settings = {"scope": "A", "record": "settings_app", "revision": "a-old",
                  "sequence": 7, "changed_at": 100, "payload": {"theme": "A"}}
current_b_settings = {"theme": "B-new"}
refreshed_settings = refresh_for_current_local_state(
    old_a_settings, current_b_settings, "a-current", 9
)
require(refreshed_settings["payload"] == current_b_settings
        and refreshed_settings["revision"] == "a-current",
        "Returning to A must not upload/mark an old A settings payload while B-new is visible locally.")

old_a_scroll = {"scope": "A", "record": "settings_listScrollPositions", "revision": "s-old",
                "sequence": 8, "changed_at": 100, "payload": {"positions": {"list": 10}}}
current_b_scroll = {"positions": {"list": 90}}
refreshed_scroll = refresh_for_current_local_state(old_a_scroll, current_b_scroll, "s-current", 10)
require(refreshed_scroll["payload"] == current_b_scroll
        and refreshed_scroll["revision"] == "s-current",
        "Returning to A must create a current scroll revision even though scroll has no hash notification.")

print("iCloud singleton account-scope regression checks passed")
