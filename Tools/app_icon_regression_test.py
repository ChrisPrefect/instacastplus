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
    return re.findall(r'@"([^"]+)"', match.group(1))


def app_icon_content(name):
    path = MEDIA / f"{name}.appiconset" / "Contents.json"
    assert_true(path.exists(), f"Missing app icon asset catalog {name}.")
    return json.loads(path.read_text(encoding="utf-8"))


def appearance_values(contents):
    values = []
    for image in contents["images"]:
        for appearance in image.get("appearances", []):
            if appearance.get("appearance") == "luminosity":
                values.append(appearance.get("value"))
    return values


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
    assert_true(
        "appicon12" not in appearance_previews and "AppIcon-12" not in appearance_names,
        "Retro/Vintage AppIcon-12 must not remain selectable.",
    )
    assert_true(
        "AppIcon-12" not in project_source,
        "Retro/Vintage AppIcon-12 must not be listed as an alternate app icon.",
    )
    assert_true(
        not (MEDIA / "AppIcon-12.appiconset").exists()
        and not (MEDIA / "AppIconsToShow" / "appicon12.imageset").exists(),
        "Retro/Vintage AppIcon-12 assets must be removed.",
    )
    assert_true(
        "appicon13" in appearance_previews and "AppIcon-13" in appearance_names,
        "Core AppIcon-13 must remain selectable.",
    )
    assert_true(
        "AppIcon-13" in project_source,
        "Core AppIcon-13 must be listed as an alternate app icon.",
    )

    core_contents = app_icon_content("AppIcon-13")
    values = appearance_values(core_contents)
    assert_true("dark" in values, "Core AppIcon-13 must include a dark appearance rendition.")
    assert_true("tinted" in values, "Core AppIcon-13 must include a tinted appearance rendition.")
    assert_true(
        "cell.chapterImageView.layer.cornerRadius = 16;" in appearance_source
        and "cell.chapterImageView.layer.cornerRadius = 16;" in general_source,
        "App icon previews must use the same rounded shape in General and Appearance settings.",
    )

    for preview_name, alternate_name in zip(appearance_previews, appearance_names):
        preview = MEDIA / "AppIconsToShow" / f"{preview_name}.imageset" / f"{preview_name}.png"
        icon = MEDIA / f"{alternate_name}.appiconset" / f"{alternate_name}.png"
        assert_true(preview.exists(), f"Missing preview image for {preview_name}.")
        assert_true(icon.exists(), f"Missing app icon image for {alternate_name}.")


if __name__ == "__main__":
    main()
