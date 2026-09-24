#!/usr/bin/env python3
"""Checks the document registration contract for external XML backups."""

from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]
PLISTS = [
    ROOT / "Resources-iPhone" / "Instacast-Info.plist",
    ROOT / "Resources-iPad" / "Instacast HD-Info.plist",
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


for plist_path in PLISTS:
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    backup_types = [
        item
        for item in plist.get("CFBundleDocumentTypes", [])
        if "public.xml" in item.get("LSItemContentTypes", [])
    ]
    require(len(backup_types) == 1, f"{plist_path.name} must register external XML backups exactly once.")
    backup_type = backup_types[0]
    require(backup_type.get("CFBundleTypeRole") == "Viewer",
            f"{plist_path.name} must open backup XML as a viewer.")
    require(backup_type.get("LSHandlerRank") == "Alternate",
            f"{plist_path.name} must not claim ownership of every XML document.")

print("External XML backup import regression checks passed")
