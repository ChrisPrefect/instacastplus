#!/usr/bin/env python3
"""Validate release scheme configurations and opt-in transcription defaults."""

from pathlib import Path
import plistlib
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


scheme = ET.parse(ROOT / "Instacast.xcodeproj/xcshareddata/xcschemes/Instacast.xcscheme").getroot()

launch_action = scheme.find("LaunchAction")
archive_action = scheme.find("ArchiveAction")
require(
    launch_action is not None
    and launch_action.get("buildConfiguration") == "Debug",
    "The shared Xcode Run action must use Debug so device development builds expose transcription.",
)
require(
    archive_action is not None
    and archive_action.get("buildConfiguration") == "Release",
    "The shared Xcode Archive action must remain Release so App Store builds hide transcription by default.",
)

for relative in ("Resources/Defaults.plist", "Resources-iPad/Defaults.plist"):
    with (ROOT / relative).open("rb") as handle:
        defaults = plistlib.load(handle)
    require(defaults.get("LocalTranscriptionEnabled") is False,
            f"{relative} must default local AI transcription to off.")
    require(defaults.get("ServerTranscriptionEnabled") is False,
            f"{relative} must default server AI transcription to off.")
    require(defaults.get("TranscriptionAutoDefault") is False,
            f"{relative} must explicitly default automatic transcription to off.")
    require(defaults.get("ChapterAutoDefault") is False,
            f"{relative} must explicitly default automatic chapter generation to off.")

print("AI transcription release configuration checks passed.")
