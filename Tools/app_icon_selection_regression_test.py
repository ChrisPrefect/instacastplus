#!/usr/bin/env python3
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# Deliberate display order since 640a79bd: Core icon first, then Standard and the
# repository icons in curated (non-numeric) order.
EXPECTED_UI_ICONS = [
    "appiconCore",
    "appiconStandard",
    "appicon1",
    "appicon4",
    "appicon2",
    "appicon3",
    "appicon5",
    "appicon6",
    "appicon7",
    "appiconClassicAlt1",
    "appiconClassicAlt2",
    "appiconClassicAlt3",
]

EXPECTED_ICON_NAMES = [
    "InstacastPlus_Icon_Core",
    "",
    "AppIcon-1",
    "AppIcon-4",
    "AppIcon-2",
    "AppIcon-3",
    "AppIcon-5",
    "AppIcon-6",
    "AppIcon-7",
    "InstacastPlus_Icon_Classic_Alt1",
    "InstacastPlus_Icon_Classic_Alt2",
    "InstacastPlus_Icon_Classic_Alt3",
]

OLD_APP_ICON_NAMES = {"AppIcon", "AppIcon-1", "AppIcon-2", "AppIcon-3", "AppIcon-4", "AppIcon-5", "AppIcon-6", "AppIcon-7"}
DOWNLOAD_ICON_NAMES = {
    "InstacastPlus_Icon_Core",
    "InstacastPlus_Icon_Classic_Alt1",
    "InstacastPlus_Icon_Classic_Alt2",
    "InstacastPlus_Icon_Classic_Alt3",
}
INTERMEDIATE_ICON_NAMES = {"AppIcon-8", "AppIcon-9", "AppIcon-10", "AppIcon-11", "AppIcon-12", "AppIcon-13"}
INTERMEDIATE_PREVIEW_NAMES = {"appicon8", "appicon9", "appicon10", "appicon11", "appicon12", "appicon13"}


def objc_array(path: Path, name: str) -> list[str]:
    text = path.read_text()
    match = re.search(rf"{re.escape(name)}\s*=\s*@\[(.*?)\];", text, re.S)
    if not match:
        raise AssertionError(f"{path}: did not find {name} literal array")
    return re.findall(r'@"([^"]*)"', match.group(1))


def assert_controller(path: Path) -> None:
    preview_names = objc_array(path, "self->appIconsArray")
    icon_names = objc_array(path, "self->appIconNamesArray")
    assert preview_names == EXPECTED_UI_ICONS, f"{path}: unexpected preview icon list: {preview_names}"
    assert icon_names == EXPECTED_ICON_NAMES, f"{path}: unexpected app icon name list: {icon_names}"
    assert not (set(preview_names) & INTERMEDIATE_PREVIEW_NAMES), f"{path}: intermediate preview icons still selectable"
    assert not (set(icon_names) & INTERMEDIATE_ICON_NAMES), f"{path}: intermediate app icons still selectable"


def assert_project_settings() -> None:
    project = (ROOT / "Instacast.xcodeproj/project.pbxproj").read_text()
    app_icon_names = re.findall(r'ASSETCATALOG_COMPILER_APPICON_NAME = ([^;]+);', project)
    assert "InstacastPlus_Icon_Standard" in app_icon_names, "download Standard icon should remain the primary app icon"

    alternate_settings = re.findall(r'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "([^"]+)";', project)
    assert alternate_settings, "alternate app icon build setting missing"
    for setting in alternate_settings:
        names = set(setting.split())
        missing_old = OLD_APP_ICON_NAMES - names
        missing_download = DOWNLOAD_ICON_NAMES - names
        assert not missing_old, f"old app icons missing from build setting: {sorted(missing_old)}"
        assert not missing_download, f"download app icons missing from build setting: {sorted(missing_download)}"
        assert not (names & INTERMEDIATE_ICON_NAMES), f"intermediate app icons still in build setting: {sorted(names & INTERMEDIATE_ICON_NAMES)}"


def assert_intermediate_assets_removed() -> None:
    asset_root = ROOT / "Resources/Media.xcassets"
    for icon_name in INTERMEDIATE_ICON_NAMES:
        assert not (asset_root / f"{icon_name}.appiconset").exists(), f"{icon_name}.appiconset should be removed"
    for preview_name in INTERMEDIATE_PREVIEW_NAMES:
        assert not (asset_root / "AppIconsToShow" / f"{preview_name}.imageset").exists(), f"{preview_name}.imageset should be removed"


def main() -> None:
    assert_controller(ROOT / "Classes/AppearanceSettingsViewController.m")
    assert_project_settings()
    assert_intermediate_assets_removed()
    print("app icon selection regression checks passed")


if __name__ == "__main__":
    main()
