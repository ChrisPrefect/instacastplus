#!/usr/bin/env python3
from pathlib import Path
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld" / "Model6.xcdatamodel" / "contents"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


model = ET.parse(MODEL).getroot()
entity = model.find("./entity[@name='ICCloudPendingEpisodeState']")
require(entity is not None,
        "Model6 must store pending remote episode states as indexed Core Data rows.")
attributes = {attribute.attrib["name"]: attribute.attrib for attribute in entity.findall("attribute")}
require(attributes.get("accountRecordName", {}).get("indexed") == "YES",
        "Pending states must be isolated and indexed by iCloud account.")
require(attributes.get("recordName", {}).get("indexed") == "YES",
        "Pending states need an indexed CloudKit record identity.")
require(attributes.get("payloadData", {}).get("attributeType") == "Binary",
        "Each pending state must persist its payload independently.")
constraints = [[constraint.attrib.get("value") for constraint in group.findall("constraint")]
               for group in entity.findall("./uniquenessConstraints/uniquenessConstraint")]
require(["accountRecordName", "recordName"] in constraints,
        "One account/record pair must own exactly one latest pending payload.")

print("iCloud pending episode-state store regression checks passed")
