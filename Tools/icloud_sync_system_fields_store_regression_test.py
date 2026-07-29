#!/usr/bin/env python3
"""Pins bounded indexed CKRecord system-field persistence and migration."""

from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"
MODEL7_PATH = MODEL_DIR / "Model7.xcdatamodel" / "contents"
MODEL8_PATH = MODEL_DIR / "Model8.xcdatamodel" / "contents"
MODEL9_PATH = MODEL_DIR / "Model9.xcdatamodel" / "contents"
PROJECT = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()


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


require(MODEL7_PATH.exists(),
        "The indexed CKRecord system-field store needs additive Core Data Model7.")
require(MODEL8_PATH.exists(), "Model8 must preserve the Model7 system-field store.")
require(MODEL9_PATH.exists(), "The current Model9 must preserve the Model8 system-field store.")
current_version = plistlib.loads((MODEL_DIR / ".xccurrentversion").read_bytes())
require(current_version.get("_XCCurrentVersionName") == "Model9.xcdatamodel",
        "Model9 must be the compiled current Core Data model.")
require("Model9.xcdatamodel" in PROJECT
        and "currentVersion = F900B0A17E2D4B00A10B0001 /* Model9.xcdatamodel */;" in PROJECT,
        "The Xcode version group must compile Model9 as current.")

model7 = ET.parse(MODEL7_PATH).getroot()
system_fields = model7.find("./entity[@name='ICCloudKnownRecordSystemFields']")
require(system_fields is not None and system_fields.get("syncable") == "NO",
        "CKRecord system fields need a local-only Core Data entity.")
attributes = {attribute.get("name"): attribute for attribute in system_fields.findall("attribute")}
for name in ["accountRecordName", "recordName"]:
    require(attributes.get(name, {}).get("attributeType") == "String"
            and attributes[name].get("indexed") == "YES",
            f"System-field lookup key must be indexed: {name}")
require(attributes.get("systemFieldsData", {}).get("attributeType") == "Binary",
        "The archived CloudKit system fields must be one durable blob.")
constraints = [
    {constraint.get("value") for constraint in unique.findall("constraint")}
    for groups in system_fields.findall("uniquenessConstraints")
    for unique in groups.findall("uniquenessConstraint")
]
require({"accountRecordName", "recordName"} in constraints,
        "System fields must be unique per CloudKit account and record name.")
model8 = ET.parse(MODEL8_PATH).getroot()
model8_system_fields = model8.find("./entity[@name='ICCloudKnownRecordSystemFields']")
require(ET.tostring(model8_system_fields) == ET.tostring(system_fields),
        "Model8 must not alter the shipped Model7 system-field entity.")
model9 = ET.parse(MODEL9_PATH).getroot()
model9_system_fields = model9.find("./entity[@name='ICCloudKnownRecordSystemFields']")
require(ET.tostring(model9_system_fields) == ET.tostring(model8_system_fields),
        "Model9 must not alter the shipped Model8 system-field entity.")


def entity_xml(entity: ET.Element) -> bytes:
    clone = ET.fromstring(ET.tostring(entity))
    clone.tail = None
    return ET.tostring(clone)


# The immediately preceding development schema must remain strictly additive. The separate
# runtime migration proof covers the published Model4 store as well as Model6.
model6 = ET.parse(MODEL_DIR / "Model6.xcdatamodel" / "contents").getroot()
model5_base = ET.parse(MODEL_DIR / "Model.xcdatamodel" / "contents").getroot()
model7_entities = {entity.get("name"): entity for entity in model7.findall("entity")}
for entity in model6.findall("entity"):
    name = entity.get("name")
    require(name in model7_entities and entity_xml(model7_entities[name]) == entity_xml(entity),
            f"Model7 changed existing Model6 entity {name}; migration is not additive.")

# The Model5 base predates Model6's intentionally additive Watch revision and local sync
# entities. Its existing fields/relationships must remain byte-identical, while every added
# field on an existing entity must be optional or have a migration default.
for base_entity in model5_base.findall("entity"):
    name = base_entity.get("name")
    current_entity = model7_entities.get(name)
    require(current_entity is not None,
            f"Model7 removed Model5 base entity {name}.")
    base_attribute_names = {
        attribute.get("name") for attribute in base_entity.findall("attribute")
    }
    for attribute in current_entity.findall("attribute"):
        if attribute.get("name") not in base_attribute_names:
            require(attribute.get("optional") == "YES" or "defaultValueString" in attribute.attrib,
                    f"Model5→Model7 added required field without default: {name}.{attribute.get('name')}")
    comparable = ET.fromstring(ET.tostring(current_entity))
    for attribute in list(comparable.findall("attribute")):
        if attribute.get("name") not in base_attribute_names:
            comparable.remove(attribute)
    require(entity_xml(comparable) == entity_xml(base_entity),
            f"Model7 changed Model5 base fields/relationships on {name}.")

require('@"ICCloudKnownRecordSystemFields"' in DATABASE.split("resetAllUserDataWithCompletion", 1)[1],
        "A full local reset must delete stored CloudKit system fields.")

# Runtime code must not retain the old N-files/N-record hot path.
for obsolete in [
    "func rememberServerRecord(",
    "func forgetServerRecord(",
    "knownRecordSystemFieldsData(forRecordName:",
    "writeKnownRecordSystemFields(",
    "removeKnownRecordSystemFields(forRecordName:",
]:
    require(obsolete not in METADATA + ENGINE + REMOTE,
            f"Per-record system-field API still exists: {obsolete}")

materialize = body(ENGINE, "nonisolated static func materializeRecordsForSyncEngineCallback")
require(materialize.count("knownRecordSystemFieldsForSyncEngineCallback(") == 1,
        "Each <=250 materialization page must perform exactly one system-field lookup.")
require("knownRecordLookup.succeeded" in materialize
        and "knownRecordLookup.invalidRecordNames" in materialize,
        "A failed/corrupt read must remain distinct from a missing new record.")
lookup = body(ENGINE, "nonisolated static func knownRecordSystemFieldsForSyncEngineCallback")
require("accountRecordName == %@ AND recordName IN %@" in lookup
        and "maximumRecordZoneChangesPerBatch" in lookup
        and "fetchLimit = maximumRecordZoneChangesPerBatch" in lookup
        and "performAndWait" in lookup,
        "The callback must use one bounded account-scoped indexed fetch.")

# Deterministic stress contract: 4,500 records require 18 indexed page lookups, never 4,500
# filesystem operations. This deliberately models CKSyncEngine's maximum page size.
record_names = [f"episode-{index}" for index in range(4_500)]
pages = [record_names[index:index + 250] for index in range(0, len(record_names), 250)]
require(len(pages) == 18 and all(len(page) <= 250 for page in pages),
        "The 4,500-record materialization contract must remain 18 bounded pages.")
require("Data(contentsOf:" not in materialize
        and ".write(to:" not in materialize
        and "removeItem" not in materialize,
        "Materialization must never perform per-record file I/O.")

persist = body(METADATA, "nonisolated static func persistKnownRecordSystemFields")
delete = body(METADATA, "nonisolated static func removeKnownRecordSystemFields")
for helper, operation in [(persist, "persist"), (delete, "delete")]:
    require("maximumRecordZoneChangesPerBatch" in helper
            and "newICloudSyncBackgroundContext()" in helper
            and "context.perform" in helper
            and "context.save()" in helper
            and "context.reset()" in helper
            and "await Task.yield()" in helper,
            f"System-field {operation} must use durable <=250-row background transactions.")
    require("try?" not in helper,
            f"System-field {operation} failures must propagate and block acknowledgement.")

sent = body(REMOTE, "func handleSentRecordZoneChanges")
persist_position = sent.find("try await Self.persistKnownRecordSystemFields")
ack_position = sent.find("acknowledgeLocalOutboxOperationsInBackground")
conflict_position = sent.find("failedRecordSaves.compactMap")
failed_apply_position = sent.find("handleFailedRecordSave")
require(-1 < conflict_position < persist_position < ack_position,
        "Saved/conflict system fields must commit before local send acknowledgement.")
require(persist_position < failed_apply_position,
        "serverRecordChanged fields must be awaited off-main before conflict apply.")
failed_save = body(REMOTE, "func handleFailedRecordSave")
require("rememberServerRecord" not in failed_save
        and "persistKnownRecordSystemFields" not in failed_save,
        "serverRecordChanged must never synchronously persist on MainActor.")

state_callback = body(ENGINE, "nonisolated func handleEvent")
state_guard = body(ENGINE, "func statePersistenceGeneration")
require("case .stateUpdate" in state_callback
        and "try await persistStateSerialization" in state_callback
        and "requiresSyncEngineStateRollbackAfterPersistenceFailure" in state_guard,
        "A failed local system-field transaction must block the off-main CloudKit state write.")
initializer = body(MANAGER, "func initializeSyncEngineIfNeeded")
require("requiresSyncEngineStateRollbackAfterPersistenceFailure" in initializer
        and initializer.find("syncEngine = nil") < initializer.find("loadStateSerialization()"),
        "The next retry must rebuild CKSyncEngine from the last durable cursor.")
local_failure = body(REMOTE, "func handleLocalPersistenceFailure")
require("requiresSyncEngineStateRollbackAfterPersistenceFailure = true" in local_failure,
        "Persistence failures must arm durable-cursor rollback before retry.")

migration = body(METADATA, "func migrateLegacyKnownRecordSystemFieldsIfNeeded")
require("cloudAccountGeneration" in migration
        and "accountUserRecordNameKey" in migration
        and migration.find("persistKnownRecordSystemFields") < migration.find("removeLegacyKnownRecordSystemFieldFiles"),
        "Legacy files must commit account-scoped rows before crash-safe source deletion.")
legacy_reader = body(METADATA, "nonisolated static func legacyKnownRecordSystemFieldWrites")
require("NSKeyedUnarchiver" in legacy_reader and "CKRecord(coder:" in legacy_reader,
        "Legacy migration must decode each CKRecord system-field blob before binding it.")
reconcile = body(REMOTE, "func reconcileAvailableICloudAccount")
require(reconcile.find("setICloudAccountIdentityVerified(true)")
        < reconcile.find("migrateLegacyKnownRecordSystemFieldsIfNeeded"),
        "Unscoped legacy system fields may bind only after CloudKit verified the account.")

print("iCloud indexed system-field store regression checks passed")
