#!/usr/bin/env python3
"""Pins EpisodeList sync to the same Core Data commit as the edited list."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
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


require(
    'localOutboxSubscriptionListSettingsCategory = "subscriptionListSettings"' in MANAGER,
    "Episode-list state needs its own transactional outbox category.",
)

journal = method_body(LOCAL, "func journalLocalOutboxObjects")
require(
    "subscriptionListSettingsDirtyMarkerPayload" in journal
    and "localOutboxSubscriptionListSettingsCategory" in journal
    and "LocalOutboxMutation" in journal,
    "ObjectsDidChange must write only a lightweight dirty marker into the context-local outbox row.",
)
require(
    "persistPendingSingletonUploadIntent" not in journal
    and "addPendingSave(subscriptionListSettingsRecordID())" not in journal
    and "subscriptionListSettingsLocalModifiedDateKey" not in journal,
    "An uncommitted EpisodeList edit must not create external intent, clock, baseline, or CK pending state.",
)
require("subscriptionListSettingsPayload(in: context)" not in journal,
        "ObjectsDidChange must not fetch/prefetch/serialize the complete list/feed graph on the MainActor.")

did_save = method_body(LOCAL, "@objc nonisolated func coreDataDidSave")
require("scheduleLocalOutboxDrain" in did_save,
        "Only the post-commit notification may start EpisodeList outbox materialization.")

drain = method_body(LOCAL, "func drainLocalOutbox")
require(
    "localOutboxSubscriptionListSettingsCategory" in drain
    and "expandCommittedSubscriptionListSettingsOutboxEntry" in drain
    and "prepareCommittedSubscriptionListSettingsOutboxEntryForUpload" in drain,
    "The post-commit drain must expand, bind and queue EpisodeList singleton rows.",
)
expand = method_body(LOCAL, "func expandCommittedSubscriptionListSettingsOutboxEntry")
require("committedSubscriptionListSettingsPayload" in expand
        and "replaceSubscriptionListSettingsDirtyMarker" in expand
        and "entry.revision" in expand,
        "Background expansion must conditionally replace only the exact committed marker revision.")
prepare = method_body(
    LOCAL,
    "func prepareCommittedSubscriptionListSettingsOutboxEntryForUpload",
)
require(
    prepare.find("entry.revision") < prepare.find("persistPendingSingletonUploadIntent")
    < prepare.find("subscriptionListSettingsLocalModifiedDateKey")
    < prepare.find("addPendingSaves"),
    "Post-commit materialization must preserve the exact outbox revision/date before queueing CK.",
)

materialize = method_body(ENGINE, "nonisolated static func materializeRecordsForSyncEngineCallback")
require(
    "localOutboxSubscriptionListSettingsCategory" in materialize
    and "entry.payloadDictionary()" in materialize
    and "entry.revision" in materialize
    and "entry.changedAt" in materialize,
    "The CK record must be built from the committed outbox payload, never a newer/uncommitted live context.",
)
require("singletonIntent.revision == entry.revision" in materialize
        and "singletonIntent.modifiedAt == entry.changedAt" in materialize,
        "R2 outbox payload must never materialize while the callback snapshot still authorizes R1.")

require("causallyOrderedLocalOutboxDate" in LOCAL,
        "Per account+record outbox time must remain strictly monotone across equal/backward wall clocks.")

ack = method_body(
    REMOTE,
    "nonisolated static func acknowledgeLocalOutboxOperationsInBackground",
)
require(
    "currentRevision == sentAttempt.revision" in ack
    and "currentOperation == sentAttempt.operation" in ack
    and 'forKey: "acknowledgedRevision"' in ack
    and "context.delete(" not in ack,
    "Only the exact committed EpisodeList revision may receive a durable ACK receipt.",
)


class TransactionalOutboxModel:
    def __init__(self):
        self.store = {}
        self.transaction = None
        self.intent = None
        self.pending = False

    def objects_did_change(self, revision, changed_at, payload):
        self.transaction = (revision, changed_at, payload)

    def rollback(self):
        self.transaction = None

    def commit(self):
        revision, proposed_at, payload = self.transaction
        prior = self.store.get("settings_subscriptionList")
        prior_at = prior[1] if prior else None
        changed_at = proposed_at if prior_at is None or proposed_at > prior_at else prior_at + 1
        self.store["settings_subscriptionList"] = (revision, changed_at, payload)
        self.transaction = None

    def restart_and_drain(self):
        row = self.store.get("settings_subscriptionList")
        if row is None:
            return
        revision, changed_at, payload = row
        self.intent = (revision, changed_at, payload)
        self.pending = True


rolled_back = TransactionalOutboxModel()
rolled_back.objects_did_change("r1", 100, {"lists": ["old"]})
rolled_back.rollback()
rolled_back.restart_and_drain()
require(rolled_back.intent is None and not rolled_back.pending,
        "Rollback/save failure must leave no singleton intent or CK pending save.")

committed = TransactionalOutboxModel()
committed.objects_did_change("r2", 200, {"lists": ["new"]})
committed.commit()
# Simulate kill before the in-process didSave drain runs.
committed.restart_and_drain()
first_intent = committed.intent
committed.restart_and_drain()
require(
    first_intent == ("r2", 200, {"lists": ["new"]})
    and committed.intent == first_intent
    and committed.pending,
    "A committed row must survive kill-before-drain and resume the exact revision idempotently.",
)

clock_rollback = TransactionalOutboxModel()
clock_rollback.objects_did_change("r1", 500, {"lists": ["one"]})
clock_rollback.commit()
late_r1 = clock_rollback.store["settings_subscriptionList"]
clock_rollback.objects_did_change("r2", 400, {"lists": ["two"]})
clock_rollback.commit()
r2 = clock_rollback.store["settings_subscriptionList"]
require(r2[0] == "r2" and r2[1] > late_r1[1],
        "A causal R2 must sort after R1 even when wall clock moves backwards.")
cache = r2
if late_r1[1] > cache[1]:
    cache = late_r1
require(cache[0] == "r2", "A late R1 snapshot must not replace causally newer cached R2.")


def materialize(snapshot_intent, outbox_row):
    if snapshot_intent[:2] != outbox_row[:2]:
        return None
    return outbox_row


require(materialize(("r1", 100), ("r2", 101, {"lists": ["two"]})) is None,
        "R1 callback authority must wait instead of sending R2 and requeueing stale R1.")

print("iCloud EpisodeList transactional outbox regression checks passed")
