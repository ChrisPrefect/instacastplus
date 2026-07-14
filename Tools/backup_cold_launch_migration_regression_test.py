#!/usr/bin/env python3
"""Pins cold-launch file URLs across asynchronous database migration/startup."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("pendingOpenURLContexts" in SCENE,
        "The scene must retain launch URL contexts while database migration owns the root controller.")
migration = SCENE.split("if ([DatabaseManager dataStoreNeedsMigration])", 1)[1].split("else", 1)[0]
require("connectionOptions.URLContexts" in migration and "pendingOpenURLContexts" in migration,
        "Cold-launch URL contexts must be captured in the migration branch, not only after normal startup.")
require("InstacastMainViewControllerDidBecomeReadyNotification" in SCENE
        and "InstacastMainViewControllerDidBecomeReadyNotification" in APP,
        "Scene and app startup need one explicit readiness handoff after migration.")
require("_mainViewControllerDidBecomeReady:" in SCENE,
        "The scene must consume retained URL contexts when its real main controller is ready.")
ready = SCENE.split("- (void)_mainViewControllerDidBecomeReady:", 1)[1]
require("self.mainViewController" in ready
        and "openURLContexts:self.pendingOpenURLContexts" in ready
        and "self.pendingOpenURLContexts = nil" in ready,
        "Readiness must bind the scene controller, route every retained URL, then clear ownership.")
startup = APP.split("- (void) _startUpApplicationWithLaunchOptions:", 1)[1]
require(startup.find("self.window.rootViewController = self.mainViewController")
        < startup.find("InstacastMainViewControllerDidBecomeReadyNotification"),
        "Startup may announce readiness only after the real main controller owns the window.")
require("pendingBackupFileURL" in APP,
        "Legacy application URL delivery must also retain a backup URL received before migration finishes.")
legacy_xml_route = APP.split('compare:@"xml" options:NSCaseInsensitiveSearch', 1)[1].split("else if", 1)[0]
require("self.mainViewController" in legacy_xml_route and "pendingBackupFileURL" in legacy_xml_route,
        "The application URL route must defer XML when no main controller exists yet.")
require("openBackupFileURL:self.pendingBackupFileURL" in startup,
        "App startup must consume a deferred legacy backup URL after installing the main controller.")


print("Backup cold-launch migration regression checks passed")
