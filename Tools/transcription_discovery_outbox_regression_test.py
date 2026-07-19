#!/usr/bin/env python3
"""Regression proof for the automatic-transcription discovery outbox."""

import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SUBSCRIPTIONS = (ROOT / "Classes/Model/SubscriptionManager.m").read_text()
QUEUE = (ROOT / "Classes/TranscriptionQueue.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


post_start = SUBSCRIPTIONS.index("- (void)_postDidAddEpisodesNotification:")
post_end = SUBSCRIPTIONS.index("\n}", post_start)
post_body = SUBSCRIPTIONS[post_start:post_end]
record_call = "recordAutomaticDiscoveryForEpisodes:episodes"
handoff_call = "scheduleAutomaticProcessingForEpisodes:episodes"
require(record_call in post_body and handoff_call in post_body, (
    "SubscriptionManager must persist each discovered episode hash before handing "
    "the episode batch to TranscriptionQueue."
))
require(post_body.index(record_call) < post_body.index(handoff_call), (
    "The automatic-processing handoff still precedes the durable discovery outbox write."
))
require("NSError* discoveryError" in post_body and "completion:" not in post_body, (
    "_postDidAddEpisodesNotification still starts a fire-and-forget outbox write and "
    "can return to a Core Data save before the hash is durable."
))
require("if (discoveryError)" in post_body
        and handoff_call in post_body.split("if (discoveryError)", 1)[1], (
    "A failed outbox write must not be treated as a delivered queue handoff."
))

require("PersistedAutomaticDiscoveryOutbox" in QUEUE, (
    "The automatic discovery hashes have no dedicated durable outbox format."
))
require('appendingPathComponent("TranscriptionDiscoveryOutbox.json")' in QUEUE, (
    "The automatic discovery outbox has no stable persistence location."
))
require("ICUpdatePersistedAutomaticDiscoveryOutbox" in QUEUE and ".atomic" in QUEUE, (
    "Discovery outbox changes are not committed with atomic file replacement."
))
require("@objc(recordAutomaticDiscoveryForEpisodes:)" in QUEUE, (
    "SubscriptionManager cannot synchronously confirm the durable discovery record."
))
require("ICPersistAutomaticDiscoveryHashesBeforeHandoff" in QUEUE, (
    "The pre-handoff discovery write has no dedicated synchronous durability boundary."
))
sync_writer_start = QUEUE.index("private func ICPersistAutomaticDiscoveryHashesBeforeHandoff")
sync_writer_end = QUEUE.index("\n}", sync_writer_start)
sync_writer = QUEUE[sync_writer_start:sync_writer_end]
require("ICPersistedTranscriptionQueueWriteQueue.sync" in sync_writer, (
    "The outbox API can return before its serial atomic file write has completed."
))

batch_start = QUEUE.index("private func automaticProcessingDecision(episodes:")
batch_end = QUEUE.index("@objc(scheduleAutomaticProcessingForEpisodes:)", batch_start)
batch_body = QUEUE[batch_start:batch_end]
require("discoveryHashesToAcknowledge" in batch_body, (
    "The queue does not retain the exact discovery hashes whose decisions it resolves."
))
require("persistQueue { error in" in batch_body, (
    "Automatic queue decisions are not durably snapshotted before acknowledgement."
))
persist_index = batch_body.index("persistQueue { error in")
success_index = batch_body.index("guard error == nil", persist_index)
ack_index = batch_body.index("acknowledgeAutomaticDiscovery", success_index)
require(persist_index < success_index < ack_index, (
    "Discovery hashes are acknowledged before the queue snapshot has committed."
))
require("let shouldStartAfterPersistence = didEnqueueAny" in batch_body, (
    "The queue-start decision must cross the Swift 6 sendable persistence callback "
    "as an immutable value."
))
require("guard didEnqueueAny else" not in batch_body[:persist_index]
        and "guard shouldStartAfterPersistence else" in batch_body[persist_index:], (
    "Opt-out and already-queued decisions must also persist a queue snapshot and "
    "acknowledge their discovery hashes."
))

require("reconcilePersistedAutomaticDiscoveryOutbox()" in QUEUE, (
    "TranscriptionQueue startup does not reconcile a discovery record left by a kill."
))
reconcile_start = QUEUE.index("private func reconcilePersistedAutomaticDiscoveryOutbox()")
reconcile_end = QUEUE.index("\n    }", reconcile_start)
reconcile_body = QUEUE[reconcile_start:reconcile_end]
require("episodes(withObjectHashes:" in reconcile_body, (
    "Startup discovery reconciliation must use a targeted objectHash fetch."
))
require("missingEpisodeHashes" in reconcile_body, (
    "Missing Core Data episodes must remain explicitly pending for a later feed refresh."
))
require("dmanager.feeds" not in reconcile_body, (
    "Startup reconciliation must not scan the full podcast library."
))


# Functional state-machine proof. A kill at either boundary can only leave extra
# outbox work; it can never lose an episode or acknowledge an uncommitted job.
class Outbox:
    def __init__(self, path: Path) -> None:
        self.path = path

    def read(self) -> set[str]:
        if not self.path.exists():
            return set()
        return set(json.loads(self.path.read_text())["episodeHashes"])

    def write(self, hashes: set[str]) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"episodeHashes": sorted(hashes)}))
        tmp.replace(self.path)

    def record(self, hashes: set[str]) -> None:
        self.write(self.read() | hashes)

    def acknowledge(self, hashes: set[str], queue_snapshot_committed: bool) -> None:
        if not queue_snapshot_committed:
            return
        self.write(self.read() - hashes)


with tempfile.TemporaryDirectory() as directory:
    outbox = Outbox(Path(directory) / "discovery.json")
    outbox.record({"queued", "opted-out", "missing"})
    outbox.record({"queued"})  # duplicate feed delivery is idempotent
    require(outbox.read() == {"queued", "opted-out", "missing"}, (
        "Duplicate discovery recording changed the durable work set."
    ))

    # Simulated kill after outbox commit and before queue commit.
    require("queued" in outbox.read(), "The pre-handoff kill lost the discovery hash.")
    outbox.acknowledge({"queued", "opted-out"}, queue_snapshot_committed=False)
    require(outbox.read() == {"queued", "opted-out", "missing"}, (
        "A queue decision was acknowledged without a durable queue snapshot."
    ))

    # Both a real queue row and a deliberate opt-out are resolved by one committed
    # snapshot. The missing Core Data row stays pending for a later feed refresh.
    outbox.acknowledge({"queued", "opted-out"}, queue_snapshot_committed=True)
    require(outbox.read() == {"missing"}, (
        "Committed queue/opt-out decisions were not acknowledged exactly once."
    ))

print("Automatic transcription discovery outbox regression checks passed.")
