#!/usr/bin/env python3
"""Pins the Phase-1 indexed iCloud metadata store and kill-safe migration."""

from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
TYPES = (ROOT / "Classes" / "ICiCloudSyncTypes.swift").read_text()
MODEL_PATH = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model6.xcdatamodel" / "contents"
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


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


model = ET.parse(MODEL_PATH).getroot()
entity = model.find("./entity[@name='ICCloudSyncItemMetadata']")
require(entity is not None,
        "Growing episode/subscription clocks and fingerprints need indexed Core Data rows.")
attributes = {attribute.attrib["name"]: attribute.attrib for attribute in entity.findall("attribute")}
for name in ["accountRecordName", "category", "recordName", "itemIdentifier"]:
    require(attributes.get(name, {}).get("attributeType") == "String",
            f"Indexed sync metadata needs the required string attribute {name}.")
for name in ["accountRecordName", "category", "recordName", "itemIdentifier"]:
    require(attributes[name].get("indexed") == "YES",
            f"Sync metadata lookup field {name} must be indexed.")
require(attributes.get("localModifiedAt", {}).get("attributeType") == "Date"
        and attributes["localModifiedAt"].get("optional") == "YES",
        "The local logical clock must remain optional during migration.")
require(attributes.get("localState", {}).get("attributeType") == "Boolean"
        and attributes["localState"].get("optional") == "YES"
        and attributes["localState"].get("usesScalarValueType") == "NO",
        "Unknown subscription state must remain distinct from false.")
require(attributes.get("payloadHash", {}).get("attributeType") == "String"
        and attributes["payloadHash"].get("optional") == "YES",
        "Subscription payload fingerprints must be optional for episode rows.")
constraints = [[constraint.attrib.get("value") for constraint in group.findall("constraint")]
               for group in entity.findall("./uniquenessConstraints/uniquenessConstraint")]
require(["accountRecordName", "recordName"] in constraints,
        "One account/CloudKit-record pair must own exactly one metadata row.")

require("struct ICCloudSyncItemMetadataWrite: Sendable" in TYPES
        and "struct ICCloudSyncItemMetadataSnapshot: Sendable" in TYPES,
        "Core Data queues must exchange immutable Sendable metadata values.")

require('@"ICCloudSyncItemMetadata"' in DATABASE.split("resetAllUserDataWithCompletion", 1)[1],
        "A full app reset must delete the indexed iCloud metadata rows too.")

for signature in [
    "nonisolated static func upsertSyncItemMetadata(\n        accountRecordName",
    "nonisolated static func syncItemMetadataByRecordName",
    "nonisolated static func deleteSyncItemMetadata",
    "nonisolated static func bindSyncItemMetadata",
]:
    helper = body(METADATA, signature)
    expected_context = "newICloudSyncBackgroundContext()"
    require(expected_context in helper and "context.perform" in helper,
            f"{signature} must keep Core Data I/O off the main actor.")
    require("remoteApplyBatchSize" in helper,
            f"{signature} must bound work to the established <=100-row batch size.")

upsert = body(METADATA, "nonisolated static func upsertSyncItemMetadata(\n        accountRecordName")
require("recordName IN %@" in upsert and "context.save()" in upsert and "context.reset()" in upsert,
        "Metadata upserts must use one indexed fetch and durable save per bounded chunk.")
require("if write.localState == false" not in upsert,
        "Idempotent legacy replays may fill nil fields only; a stale state=false source must not erase newer metadata after a partial migration.")
for field in ["localModifiedAt", "localState", "payloadHash"]:
    require(f'entry.value(forKey: "{field}") == nil' in upsert,
            f"Crash-retry migration may only fill a missing {field} on an existing row.")
require('entry.setValue(nil, forKey: "payloadHash")' not in upsert,
        "A stale state=false legacy source must never erase a newer indexed payload hash.")

lookup = body(METADATA, "nonisolated static func syncItemMetadataByRecordName")
require("recordName IN %@" in lookup and "ICCloudSyncItemMetadataSnapshot" in lookup,
        "Callback consumers need bounded immutable lookups by CloudKit record name.")

delete = body(METADATA, "nonisolated static func deleteSyncItemMetadata")
require("fetchLimit = remoteApplyBatchSize" in delete and "context.delete" in delete
        and "context.save()" in delete,
        "Reset/account cleanup must delete indexed rows in bounded durable chunks.")

bind = body(METADATA, "nonisolated static func bindSyncItemMetadata")
require("localModifiedAt" in bind and "context.save()" in bind,
        "Account binding must resolve duplicate identities by their logical clock.")

migrate = body(METADATA, "func migrateLegacySyncItemMetadataIfNeeded")
save = migrate.find("upsertSyncItemMetadata")
remove = migrate.find("removeLegacySyncItemMetadataSources", save)
require(-1 < save < remove,
        "Legacy plist migration must commit indexed rows before deleting its crash-retry source files.")
legacy_reader = body(METADATA, "nonisolated static func legacySyncItemMetadataWrites")
for legacy_key in [
    "episodeLocalModifiedDatesKey",
    "subscriptionRecordURLsKey",
    "subscriptionLocalModifiedDatesKey",
    "subscriptionLocalStatesKey",
    "subscriptionPayloadHashesKey",
]:
    require(legacy_key in legacy_reader,
            f"The migration reader must retain the legacy source {legacy_key} explicitly.")
require("cloudAccountGeneration" in migrate and "accountUserRecordNameKey" in migrate,
        "Migration must revalidate account identity before deleting retry sources.")
require("UserDefaults.standard.object(forKey: key)" in legacy_reader,
        "App-Store upgrades must migrate the older UserDefaults-backed dictionaries too.")
remove_sources = body(METADATA, "nonisolated static func removeLegacySyncItemMetadataSources")
require("Task.detached(priority: .utility)" in remove_sources
        and "FileManager.default.removeItem" in remove_sources,
        "Migration source removal must be throwing and off-main, not the legacy best-effort delete helper.")

print("iCloud indexed-metadata Phase-1 regression checks passed")
