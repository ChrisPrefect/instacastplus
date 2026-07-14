#!/usr/bin/env python3
"""Pins registration, routing, validation, and visible errors for external XML backups."""

from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[1]
PLISTS = [
    ROOT / "Resources-iPhone" / "Instacast-Info.plist",
    ROOT / "Resources-iPad" / "Instacast HD-Info.plist",
]
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
MAIN_H = (ROOT / "Classes" / "MainViewController_4.h").read_text()
MAIN_M = (ROOT / "Classes" / "MainViewController_4.m").read_text()
PARSER = (ROOT / "Classes" / "InstacastBackupParser.m").read_text()
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(),
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

require("openBackupFileURL:" in MAIN_H and "openBackupFileURL:" in MAIN_M,
        "External backup reading and presentation need one shared scene-specific coordinator.")
require("startAccessingSecurityScopedResource" in PARSER and
        "stopAccessingSecurityScopedResource" in PARSER,
        "The shared bounded XML reader must balance optional security-scoped access.")
require("[ICXMLImportLimits readDataFromURL:url error:&readError]" in MAIN_M,
        "Backup file read failures and resource limits must use the shared visible-error path.")
require("isInstacastBackupData:" in MAIN_M and "parseData:" in MAIN_M,
        "An arbitrary XML document must be content-sniffed before parsing as a backup.")
backup_sniff = MAIN_M.find("isInstacastBackupData:data")
opml_route = MAIN_M.find("importOPMLData:data", backup_sniff)
require(backup_sniff >= 0 and opml_route > backup_sniff,
        "A .xml document whose content is OPML must route to the subscription importer instead of being rejected as a backup.")
require('rangeOfString:@"<opml" options:NSCaseInsensitiveSearch' in MAIN_M,
        "Non-backup XML must be positively identified as OPML before subscription import starts.")
require("InstacastBackupImportViewController" in MAIN_M and "pushViewController" in MAIN_M,
        "A valid external backup must open the preview in the current scene navigation stack.")

for source, delegate_name in ((SCENE, "scene"), (APP, "application")):
    require('compare:@"xml" options:NSCaseInsensitiveSearch' in source,
            f"The {delegate_name} URL router does not recognize .xml backup files.")
    require("[self.mainViewController openBackupFileURL:url]" in source,
            f"The {delegate_name} URL router does not delegate XML to the shared backup handler.")

require("connectionOptions.URLContexts" in SCENE and
        "openURLContexts:connectionOptions.URLContexts" in SCENE,
        "Cold-launch URL contexts must use the same XML route as warm launches.")

for localization in LOCALIZATIONS:
    for key in (
        "The backup file could not be read. Check that it is still available and try again.",
        "This XML file is not an InstacastPlus backup.",
        "The backup preview could not be opened.",
    ):
        require(f'"{key}" =' in localization, f"External backup error is not localized: {key}")

print("External XML backup import regression checks passed")
