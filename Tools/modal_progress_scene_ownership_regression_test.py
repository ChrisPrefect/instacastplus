#!/usr/bin/env python3
"""Pins legacy VDModalInfo progress overlays to the initiating scene window."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Classes" / "VDModalInfo.h").read_text()
MODAL = (ROOT / "Classes" / "VDModalInfo.m").read_text()
MAIN = (ROOT / "Classes" / "MainViewController_4.m").read_text()
SETTINGS = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("showInWindow:" in HEADER and "- (void) showInWindow:" in MODAL,
        "VDModalInfo needs an explicit scene-window presentation API.")
require("targetWindow.bounds" in MODAL and "[targetWindow addSubview:self]" in MODAL,
        "Overlay geometry and ownership must come from the explicitly selected window.")
require("showInWindow:self.view.window" in MAIN,
        "External XML analysis must appear in the main controller's own scene.")
require(SETTINGS.count("showInWindow:self.view.window") >= 3,
        "Backup analysis, OPML import, and reset progress must stay in the settings controller's scene.")
require("showInWindow:self.window" in SCENE and "showInWindow:self.window" in APP,
        "Scene/app delegate imports must pass their concrete window instead of resolving an arbitrary global key window.")


print("Modal progress scene-ownership regression checks passed")
