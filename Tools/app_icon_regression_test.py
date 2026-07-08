#!/usr/bin/env python3
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[1]

APPEARANCE = ROOT / "Classes" / "AppearanceSettingsViewController.m"
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
    project_source = read(PROJECT)

    appearance_previews = extract_array(appearance_source, "appIconsArray")
    appearance_names = extract_array(appearance_source, "appIconNamesArray")
    assert_true(
        len(appearance_previews) == len(appearance_names),
        "Preview asset list and alternate icon name list must stay aligned.",
    )
# The intermediate icons 8-13 were removed for good in 9f92ffe1; the display order
    # (Core first, curated repository icon order) is deliberate since 640a79bd.
    old_previews = [
        "appicon1",
        "appicon4",
        "appicon2",
        "appicon3",
        "appicon5",
        "appicon6",
        "appicon7",
    ]
    old_icon_names = [
        "AppIcon-1",
        "AppIcon-4",
        "AppIcon-2",
        "AppIcon-3",
        "AppIcon-5",
        "AppIcon-6",
        "AppIcon-7",
    ]
    icon_composer_previews = [
        "appiconCore",
        "appiconStandard",
        "appiconClassicAlt1",
        "appiconClassicAlt2",
        "appiconClassicAlt3",
    ]
    icon_composer_names = [
        "InstacastPlus_Icon_Core",
        "",
        "InstacastPlus_Icon_Classic_Alt1",
        "InstacastPlus_Icon_Classic_Alt2",
        "InstacastPlus_Icon_Classic_Alt3",
    ]
    expected_previews = [
        *icon_composer_previews[:2],
        *old_previews,
        *icon_composer_previews[2:],
    ]
    expected_icon_names = [
        *icon_composer_names[:2],
        *old_icon_names,
        *icon_composer_names[2:],
    ]
    assert_true(appearance_previews == expected_previews, "Settings must keep the original repository app icon previews and the new Icon Composer previews.")
    assert_true(appearance_names == expected_icon_names, "Settings icon names must keep the original repository app icons and the new Icon Composer app icons.")
    assert_true(
        "ASSETCATALOG_COMPILER_APPICON_NAME = InstacastPlus_Icon_Standard;" in project_source,
        "The app target must use the new Icon Composer Standard document as the primary icon.",
    )

    alternate_composer_names = [name for name in icon_composer_names if name]
    expected_project_alternates = [*old_icon_names, "AppIcon", *alternate_composer_names]
    for alternate_names in project_alternate_icon_lists(project_source):
        missing_names = sorted(set(expected_project_alternates) - set(alternate_names))
        assert_true(not missing_names, f"The app target is missing alternate app icons: {', '.join(missing_names)}.")

    for icon_name in alternate_composer_names:
        assert_true(f"{icon_name}.icon in Resources" in project_source, f"{icon_name}.icon must be compiled by the asset catalog compiler.")
    assert_true("InstacastPlus_Icon_Standard.icon in Resources" in project_source, "The primary Icon Composer document must be compiled by the asset catalog compiler.")
    for icon_name in ["InstacastPlus_Icon_Standard", *alternate_composer_names]:
        contents = app_icon_content(icon_name)
        assert_true(contents.get("supported-platforms", {}).get("squares") == "shared", f"{icon_name} must support shared square iOS icon renditions.")
    # AppIcon-2…7 were converted to Icon Composer documents in 8e771195 ("neue icons");
    # AppIcon-1 is still a classic appiconset. Accept either representation.
    for icon_name in old_icon_names:
        as_appiconset = (MEDIA / f"{icon_name}.appiconset").exists()
        as_icon_document = (ROOT / "Resources" / "AppIcons" / f"{icon_name}.icon" / "icon.json").exists()
        assert_true(as_appiconset or as_icon_document, f"Missing original repository app icon asset {icon_name}.")
        if as_icon_document:
            assert_true(f"{icon_name}.icon in Resources" in project_source, f"{icon_name}.icon must be compiled by the asset catalog compiler.")
    assert_true(
        "cell.chapterImageView.layer.cornerRadius = 16;" in appearance_source,
        "App icon previews must use the rounded shape in Appearance settings.",
    )

    for preview_name, alternate_name in zip(appearance_previews, appearance_names):
        preview = MEDIA / "AppIconsToShow" / f"{preview_name}.imageset" / f"{preview_name}.png"
        assert_true(preview.exists(), f"Missing preview image for {preview_name}.")
    assert_true("setAlternateIconName:appIconName" in appearance_source and "? selectedIconName : nil" in appearance_source, "Selecting the Standard preview must reset to the primary app icon.")


if __name__ == "__main__":
    main()
