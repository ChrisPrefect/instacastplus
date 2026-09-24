#!/usr/bin/env python3
"""Validate the persisted episode-list artwork setting in the selected model."""

from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
MODEL_DIR = ROOT / "Resources" / "Models" / "Model5.xcdatamodeld"
MODEL9 = MODEL_DIR / "Model9.xcdatamodel" / "contents"


def read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(MODEL9.exists(), "A shipped Model8 requires an additive Model9 for the durable list setting.")
current_version = plistlib.loads((MODEL_DIR / ".xccurrentversion").read_bytes())
require(
    current_version.get("_XCCurrentVersionName") == "Model9.xcdatamodel",
    "Model9 must be the selected Core Data model.",
)
project = read("Instacast.xcodeproj/project.pbxproj")
require(
    "Model9.xcdatamodel" in project
    and "/* Model9.xcdatamodel */" in project
    and "currentVersion" in project,
    "The Xcode model version group must include and select Model9.",
)

model_root = ET.parse(MODEL9).getroot()
episode_list_entity = next(
    entity for entity in model_root.findall("entity") if entity.get("name") == "EpisodeList"
)
artwork_attribute = next(
    (attribute for attribute in episode_list_entity.findall("attribute")
     if attribute.get("name") == "usePodcastArtwork"),
    None,
)
require(
    artwork_attribute is not None
    and artwork_attribute.get("attributeType") == "Boolean"
    and artwork_attribute.get("defaultValueString") == "NO",
    "EpisodeList.usePodcastArtwork must be an additive Boolean defaulting to the existing episode-artwork behavior.",
)

print("Episode-list artwork model metadata checks passed")
