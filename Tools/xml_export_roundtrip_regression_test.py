#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FOUNDATION = (ROOT / "Classes" / "Utils" / "Foundation+Instacast.m").read_text()
EXPORTER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
PARSER = (ROOT / "Classes" / "InstacastBackupParser.m").read_text()
OPML = (ROOT / "Classes" / "OPML.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require('"&gt;", @">"' in FOUNDATION and '"&rt;", @">"' not in FOUNDATION,
        "The shared XML/HTML escaper must emit the standard greater-than entity.")
require("ICXML10SanitizedString" in FOUNDATION,
        "The shared escaper must remove characters forbidden by XML 1.0.")
require("stringByEncodingStandardHTMLEntities" in EXPORTER.split("- (NSString*) xmlEscape:", 1)[1].split("}", 1)[0],
        "Full backup escaping must reuse the sanitized shared XML escaping path.")
require("en_US_POSIX" in EXPORTER and "NSCalendarIdentifierGregorian" in EXPORTER,
        "Backup timestamps must not depend on the user's locale or calendar.")
require("en_US_POSIX" in PARSER and "NSCalendarIdentifierGregorian" in PARSER,
        "Backup timestamp parsing must mirror the locale-independent exporter.")
require("value != nil" in PARSER and "value.length > 0" not in PARSER.split("// <setting", 1)[1].split("// <episodeList", 1)[0],
        "Explicit empty string podcast settings must survive a backup roundtrip.")
require("en_US_POSIX" in OPML and "NSCalendarIdentifierGregorian" in OPML,
        "OPML dates must use a stable POSIX Gregorian formatter.")
require(EXPORTER.count("ICSafeExportFilenameComponent") >= 4,
        "Every exported filename must sanitize the device/localized filename component.")


print("XML export roundtrip regression checks passed")
