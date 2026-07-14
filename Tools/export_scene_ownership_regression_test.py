#!/usr/bin/env python3
"""Pins export progress/results to the UIWindowScene that started them."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "ImportExportSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


for global_name in (
    "gPendingFullExportURL", "gPendingFullExportError",
    "gPendingSubscriptionsExportURL", "gPendingSubscriptionsExportError",
    "gPendingBookmarksExportURL", "gPendingBookmarksExportError",
):
    require(global_name not in SOURCE,
            f"{global_name} lets one iPad scene consume another scene's export result.")

require("ICImportExportSceneState" in SOURCE
        and "objc_getAssociatedObject" in SOURCE
        and "UIWindowScene" in SOURCE,
        "Export lifecycle state must be retained by its UIWindowScene so controller replacement is safe without process globals.")
for field in (
    "fullExportInProgress", "subscriptionsExportInProgress", "bookmarksExportInProgress",
    "pendingFullExportURL", "pendingSubscriptionsExportURL", "pendingBookmarksExportURL",
):
    require(f"sceneExportState.{field}" in SOURCE,
            f"{field} must be read from the initiating scene's shared state.")


print("Export scene-ownership regression checks passed")
