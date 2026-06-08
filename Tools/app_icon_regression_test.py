#!/usr/bin/env python3
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]

APPEARANCE = ROOT / "Classes" / "AppearanceSettingsViewController.m"
GENERAL = ROOT / "Classes" / "GeneralSettingsViewController.m"
PROJECT = ROOT / "Instacast.xcodeproj" / "project.pbxproj"
MEDIA = ROOT / "Resources" / "Media.xcassets"


def read(path):
    return path.read_text(encoding="utf-8")


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def extract_array(source, name):
    match = re.search(rf"self->{name}\s*=\s*@\[\s*(.*?)\s*\];", source)
    assert_true(match is not None, f"Missing {name} assignment.")
    return re.findall(r'@"([^"]*)"', match.group(1))


def app_icon_content(name):
    path = ROOT / "Resources" / "AppIcons" / f"{name}.icon" / "icon.json"
    assert_true(path.exists(), f"Missing Icon Composer document {name}.")
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    appearance_source = read(APPEARANCE)
    general_source = read(GENERAL)
    project_source = read(PROJECT)

    appearance_previews = extract_array(appearance_source, "appIconsArray")
    appearance_names = extract_array(appearance_source, "appIconNamesArray")
    general_previews = extract_array(general_source, "appIconsArray")
    general_names = extract_array(general_source, "appIconNamesArray")

    assert_true(
        appearance_previews == general_previews and appearance_names == general_names,
        "General and Appearance settings must show the same app icons in the same order.",
    )
    assert_true(
        len(appearance_previews) == len(appearance_names),
        "Preview asset list and alternate icon name list must stay aligned.",
    )
    expected_previews = [
        "appiconStandard",
        "appiconCore",
        "appiconClassicAlt1",
        "appiconClassicAlt2",
        "appiconClassicAlt3",
    ]
    expected_icon_names = [
        "",
        "InstacastPlus_Icon_Core",
        "InstacastPlus_Icon_Classic_Alt1",
        "InstacastPlus_Icon_Classic_Alt2",
        "InstacastPlus_Icon_Classic_Alt3",
    ]
    assert_true(appearance_previews == expected_previews, "Settings must show only the new consistent Icon Composer previews.")
    assert_true(appearance_names == expected_icon_names, "Settings icon names must map to the new Icon Composer app icons.")
    assert_true(
        "ASSETCATALOG_COMPILER_APPICON_NAME = InstacastPlus_Icon_Standard;" in project_source
        and 'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "InstacastPlus_Icon_Core InstacastPlus_Icon_Classic_Alt1 InstacastPlus_Icon_Classic_Alt2 InstacastPlus_Icon_Classic_Alt3";' in project_source,
        "The app target must use the new Icon Composer document as primary icon and the remaining supplied documents as alternates.",
    )

    for icon_name in expected_icon_names[1:]:
        assert_true(f"{icon_name}.icon in Resources" in project_source, f"{icon_name}.icon must be compiled by the asset catalog compiler.")
    assert_true("InstacastPlus_Icon_Standard.icon in Resources" in project_source, "The primary Icon Composer document must be compiled by the asset catalog compiler.")
    for icon_name in ["InstacastPlus_Icon_Standard", *expected_icon_names[1:]]:
        contents = app_icon_content(icon_name)
        assert_true(contents.get("supported-platforms", {}).get("squares") == "shared", f"{icon_name} must support shared square iOS icon renditions.")
    assert_true(
        "cell.chapterImageView.layer.cornerRadius = 16;" in appearance_source
        and "cell.chapterImageView.layer.cornerRadius = 16;" in general_source,
        "App icon previews must use the same rounded shape in General and Appearance settings.",
    )

    for preview_name, alternate_name in zip(appearance_previews, appearance_names):
        preview = MEDIA / "AppIconsToShow" / f"{preview_name}.imageset" / f"{preview_name}.png"
        assert_true(preview.exists(), f"Missing preview image for {preview_name}.")
    assert_true("setAlternateIconName:appIconName" in appearance_source and "? selectedIconName : nil" in appearance_source, "Selecting the Standard preview must reset to the primary app icon.")


if __name__ == "__main__":
    main()
