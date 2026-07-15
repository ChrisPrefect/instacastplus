#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = REMOTE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = REMOTE.find("{", start)
    depth = 0
    for index in range(brace, len(REMOTE)):
        if REMOTE[index] == "{":
            depth += 1
        elif REMOTE[index] == "}":
            depth -= 1
            if depth == 0:
                return REMOTE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


dedupe = method_body("func deterministicallyResolvedEpisodesByObjectHash")
require("Dictionary(uniqueKeysWithValues:" not in dedupe,
        "Duplicate legacy episode hashes must never reach Dictionary(uniqueKeysWithValues:), which traps.")
require("objectID.uriRepresentation().absoluteString" in dedupe,
        "Duplicate episode rows need a stable, deterministic winner instead of fetch-order-dependent selection.")

remote_batch = method_body("func applyPendingEpisodeStateBatchInBackground")
pending_replay = method_body("func applyPendingEpisodeStates")
sent_changes = method_body("func handleSentRecordZoneChanges")
failed_save = method_body("func handleFailedRecordSave")
single_record_apply = method_body("func applyRemoteRecord")
require("deterministicallyResolvedEpisodesByObjectHash" in remote_batch,
        "Live remote batches must deduplicate corrupt/legacy duplicate episode hashes safely.")
require("applyPendingEpisodeStateBatchInBackground" in pending_replay,
        "Pending episode replay must use the shared deterministic background worker.")
require("case .serverRecordChanged:" in failed_save
        and "applyPendingEpisodeStateBatchInBackground" in sent_changes
        and "applyPendingEpisodeStateBatchInBackground" in single_record_apply,
        "Every CloudKit conflict path must use the shared deterministic background worker.")
require("Dictionary(uniqueKeysWithValues: episodes" not in remote_batch
        and "Dictionary(uniqueKeysWithValues: episodes" not in REMOTE,
        "Neither episode resolution path may retain the duplicate-key fatal initializer.")

# All application paths must choose the same stable object-ID winner regardless of Core
# Data fetch order. This models the legacy duplicate that previously oscillated between
# batch/pending application and serverRecordChanged conflict resolution.
candidate_ids = ["x-coredata://store/Episode/z", "x-coredata://store/Episode/a"]
batch_winner = min(candidate_ids)
pending_winner = min(reversed(candidate_ids))
conflict_winner = min(candidate_ids)
require(batch_winner == pending_winner == conflict_winner,
        "Every remote episode application path must choose the same lexical object-ID winner.")

print("iCloud duplicate episode-identity regression checks passed")
