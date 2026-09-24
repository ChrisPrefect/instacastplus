#!/usr/bin/env python3
from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


# The outbox must live in the same Core Data transaction as the user's edit. A separate
# plist would leave a kill window after unsubscribeFeed saved `subscribed = NO`, and that
# feed is physically removed before the sync manager starts on the next launch.
current_version = plistlib.loads((MODEL_DIR / ".xccurrentversion").read_bytes())
model_name = current_version.get("_XCCurrentVersionName")
require(model_name == "Model9.xcdatamodel", "The durable local outbox needs the current versioned Core Data model.")
model_path = MODEL_DIR / model_name / "contents"
require(model_path.exists(), "The current Core Data model version is missing.")
model = ET.parse(model_path).getroot()
old_model = ET.parse(MODEL_DIR / "Model.xcdatamodel" / "contents").getroot()


def entity_xml(entity: ET.Element, excluding_attributes=None) -> bytes:
    clone = ET.fromstring(ET.tostring(entity))
    for attribute in list(clone.findall("attribute")):
        if attribute.get("name") in (excluding_attributes or set()):
            clone.remove(attribute)
    clone.tail = None
    return ET.tostring(clone)


old_entities = {entity.get("name"): entity for entity in old_model.findall("entity")}
new_entities = {entity.get("name"): entity for entity in model.findall("entity")}
for entity_name, old_entity in old_entities.items():
    allowed_attributes = {
        "AppleWatchEpisodeState": {"watchLastEventRevision"},
        "EpisodeList": {"usePodcastArtwork"},
    }.get(entity_name, set())
    require(
        new_entities.get(entity_name) is not None
        and entity_xml(new_entities[entity_name], allowed_attributes) == entity_xml(old_entity),
        f"The current model must remain a lightweight additive migration; existing entity changed: {entity_name}",
    )
watch_revision_attributes = [
    attribute
    for attribute in new_entities["AppleWatchEpisodeState"].findall("attribute")
    if attribute.get("name") == "watchLastEventRevision"
]
require(
    len(watch_revision_attributes) == 1
    and watch_revision_attributes[0].get("attributeType") == "Integer 64"
    and watch_revision_attributes[0].get("optional") == "YES",
    "The Watch event revision must remain one optional additive attribute in the current model.",
)
project = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()
require(
    "Model9.xcdatamodel" in project
    and "currentVersion = F900B0A17E2D4B00A10B0001 /* Model9.xcdatamodel */;" in project,
    "The Xcode version group must compile Model9 as current; otherwise builds rewrite .xccurrentversion.",
)
outbox_entities = [entity for entity in model.findall("entity") if entity.get("name") == "ICCloudSyncOutboxEntry"]
require(len(outbox_entities) == 1, "The Core Data model must contain ICCloudSyncOutboxEntry.")
outbox_entity = outbox_entities[0]
require(outbox_entity.get("syncable") == "NO", "The local outbox itself must never be iCloud-synced by Core Data.")
attributes = {attribute.get("name"): attribute for attribute in outbox_entity.findall("attribute")}
for attribute in ["accountRecordName", "recordName", "category", "operation", "acknowledged",
                  "acknowledgedRevision", "acknowledgedOperation", "revision", "changedAt", "payloadData"]:
    require(attribute in attributes, f"Outbox attribute is missing: {attribute}")
require(
    any(
        {constraint.get("value") for constraint in unique.findall("constraint")}
        == {"accountRecordName", "recordName"}
        for constraints in outbox_entity.findall("uniquenessConstraints")
        for unique in constraints.findall("uniquenessConstraint")
    ),
    "Outbox entries must be unique per CloudKit account and record name.",
)

print("iCloud local outbox regression checks passed")
