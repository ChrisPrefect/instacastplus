#!/usr/bin/env python3
"""Checks versioned CKRecord system-field schema compatibility."""

from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"
MODEL7_PATH = MODEL_DIR / "Model7.xcdatamodel" / "contents"
MODEL8_PATH = MODEL_DIR / "Model8.xcdatamodel" / "contents"
MODEL9_PATH = MODEL_DIR / "Model9.xcdatamodel" / "contents"
PROJECT = (ROOT / "Instacast.xcodeproj" / "project.pbxproj").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


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

print("iCloud indexed system-field store regression checks passed")
