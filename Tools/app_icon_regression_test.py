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


def project_alternate_icon_lists(project_source):
    values = re.findall(r'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "([^"]*)";', project_source)
    assert_true(values, "The app target must declare alternate app icon names.")
    return [value.split() for value in values]


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
    old_previews = [
        "appicon13",
        "appicon8",
        "appicon9",
        "appicon10",
        "appicon11",
        "appicon1",
        "appicon2",
        "appicon3",
        "appicon4",
        "appicon5",
        "appicon6",
        "appicon7",
    ]
    old_icon_names = [
        "AppIcon-13",
        "AppIcon-8",
        "AppIcon-9",
        "AppIcon-10",
        "AppIcon-11",
        "AppIcon-1",
        "AppIcon-2",
        "AppIcon-3",
        "AppIcon-4",
        "AppIcon-5",
        "AppIcon-6",
        "AppIcon-7",
    ]
    icon_composer_previews = [
        "appiconStandard",
        "appiconCore",
        "appiconClassicAlt1",
        "appiconClassicAlt2",
        "appiconClassicAlt3",
    ]
    icon_composer_names = [
        "",
        "InstacastPlus_Icon_Core",
        "InstacastPlus_Icon_Classic_Alt1",
        "InstacastPlus_Icon_Classic_Alt2",
        "InstacastPlus_Icon_Classic_Alt3",
    ]
    expected_previews = [
        icon_composer_previews[0],
        *old_previews,
        *icon_composer_previews[1:],
    ]
    expected_icon_names = [
        icon_composer_names[0],
        *old_icon_names,
        *icon_composer_names[1:],
    ]
    assert_true(appearance_previews == expected_previews, "Settings must keep the original repository app icon previews and the new Icon Composer previews.")
    assert_true(appearance_names == expected_icon_names, "Settings icon names must keep the original repository app icons and the new Icon Composer app icons.")
    assert_true(
        "ASSETCATALOG_COMPILER_APPICON_NAME = InstacastPlus_Icon_Standard;" in project_source,
        "The app target must use the new Icon Composer Standard document as the primary icon.",
    )

    expected_project_alternates = [*old_icon_names, "AppIcon", *icon_composer_names[1:]]
    for alternate_names in project_alternate_icon_lists(project_source):
        missing_names = sorted(set(expected_project_alternates) - set(alternate_names))
        assert_true(not missing_names, f"The app target is missing alternate app icons: {', '.join(missing_names)}.")

    for icon_name in icon_composer_names[1:]:
        assert_true(f"{icon_name}.icon in Resources" in project_source, f"{icon_name}.icon must be compiled by the asset catalog compiler.")
    assert_true("InstacastPlus_Icon_Standard.icon in Resources" in project_source, "The primary Icon Composer document must be compiled by the asset catalog compiler.")
    for icon_name in ["InstacastPlus_Icon_Standard", *icon_composer_names[1:]]:
        contents = app_icon_content(icon_name)
        assert_true(contents.get("supported-platforms", {}).get("squares") == "shared", f"{icon_name} must support shared square iOS icon renditions.")
    for icon_name in old_icon_names:
        assert_true((MEDIA / f"{icon_name}.appiconset").exists(), f"Missing original repository app icon asset {icon_name}.")
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
