#!/usr/bin/env python3
from pathlib import Path
import json
import re
import struct


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "InstacastWatchWidgets" / "WatchComplicationWidget.swift"
ASSETS = ROOT / "InstacastWatchWidgets" / "Assets.xcassets"
PROJECT = ROOT / "Instacast.xcodeproj" / "project.pbxproj"
LOCALIZATIONS = {
    "de": ROOT / "InstacastWatchWidgets" / "de.lproj" / "Localizable.strings",
    "en": ROOT / "InstacastWatchWidgets" / "en.lproj" / "Localizable.strings",
}

VARIANTS = [
    ("standard", "ComplicationIcon", "WATCH_COMPLICATION_STANDARD_TITLE"),
    ("core", "ComplicationIconCore", "WATCH_COMPLICATION_CORE_TITLE"),
    ("icon1", "ComplicationIcon1", "WATCH_COMPLICATION_ICON_1_TITLE"),
    ("icon4", "ComplicationIcon4", "WATCH_COMPLICATION_ICON_4_TITLE"),
    ("icon2", "ComplicationIcon2", "WATCH_COMPLICATION_ICON_2_TITLE"),
    ("icon3", "ComplicationIcon3", "WATCH_COMPLICATION_ICON_3_TITLE"),
    ("icon5", "ComplicationIcon5", "WATCH_COMPLICATION_ICON_5_TITLE"),
    ("icon6", "ComplicationIcon6", "WATCH_COMPLICATION_ICON_6_TITLE"),
    ("icon7", "ComplicationIcon7", "WATCH_COMPLICATION_ICON_7_TITLE"),
    ("classicAlt1", "ComplicationIconClassicAlt1", "WATCH_COMPLICATION_CLASSIC_1_TITLE"),
    ("classicAlt2", "ComplicationIconClassicAlt2", "WATCH_COMPLICATION_CLASSIC_2_TITLE"),
    ("classicAlt3", "ComplicationIconClassicAlt3", "WATCH_COMPLICATION_CLASSIC_3_TITLE"),
    ("classicAlt4", "ComplicationIconClassicAlt4", "WATCH_COMPLICATION_CLASSIC_4_TITLE"),
]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def png_size(path):
    data = path.read_bytes()
    require(data[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {path}")
    return struct.unpack(">II", data[16:24])


def main():
    source = SOURCE.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")

    bundle_styles = re.findall(r"WatchComplicationWidget\(style: \.([A-Za-z0-9]+)\)", source)
    expected_styles = [style for style, _, _ in VARIANTS]
    require(bundle_styles == expected_styles, "The Watch widget bundle must expose every app icon in settings order.")
    require(
        'case .standard: "InstacastWatchComplication"' in source,
        "The Standard variant must preserve the existing widget kind so configured watch faces keep working.",
    )

    kinds = re.findall(r'case \.[A-Za-z0-9]+: "(InstacastWatchComplication[^\"]*)"', source)
    require(len(kinds) == len(VARIANTS), "Every complication variant needs a stable widget kind.")
    require(len(set(kinds)) == len(kinds), "Complication widget kinds must be unique.")

    for style, asset_name, title_key in VARIANTS:
        require(f'case .{style}: "{asset_name}"' in source, f"Missing asset mapping for {style}.")
        require(f'case .{style}: "{title_key}"' in source, f"Missing localized title mapping for {style}.")
        imageset = ASSETS / f"{asset_name}.imageset"
        contents_path = imageset / "Contents.json"
        require(contents_path.exists(), f"Missing asset catalog entry {asset_name}.")
        contents = json.loads(contents_path.read_text(encoding="utf-8"))
        images = {image.get("scale"): image.get("filename") for image in contents.get("images", [])}
        for scale, expected_size in (("2x", (88, 88)), ("3x", (87, 87))):
            filename = images.get(scale)
            require(filename, f"{asset_name} must provide a {scale} rendition.")
            image_path = imageset / filename
            require(image_path.exists(), f"Missing {scale} image for {asset_name}.")
            require(png_size(image_path) == expected_size, f"{asset_name} {scale} has the wrong dimensions.")

    localization_keys = [title_key for _, _, title_key in VARIANTS] + ["WATCH_COMPLICATION_DESCRIPTION"]
    for language, path in LOCALIZATIONS.items():
        require(path.exists(), f"Missing {language} Watch widget localization.")
        localization = path.read_text(encoding="utf-8")
        for key in localization_keys:
            require(re.search(rf'^"{re.escape(key)}"\s*=\s*".+";$', localization, re.MULTILINE), f"Missing {key} in {language}.")

    widget_resources = project.split("D222B9632F85B2B01C669878 /* Resources */ = {", 1)[1].split("};", 1)[0]
    require("Localizable.strings in Resources" in widget_resources, "Watch widget localizations must be part of the widget target.")


if __name__ == "__main__":
    main()
