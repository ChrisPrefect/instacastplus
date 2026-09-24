#!/usr/bin/env python3
"""Checks the indexed iCloud metadata schema contract."""

from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL_PATH = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model6.xcdatamodel" / "contents"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


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

print("iCloud indexed-metadata Phase-1 regression checks passed")
