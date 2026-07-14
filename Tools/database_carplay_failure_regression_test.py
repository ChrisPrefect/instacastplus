#!/usr/bin/env python3
"""Pins a terminal CarPlay UI when database startup cannot complete."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace:index + 1]
    raise AssertionError(f"Unterminated method: {signature}")


require(
    "InstacastDatabaseStartupDidFailNotification" in APP
    and APP.count("postNotificationName:InstacastDatabaseStartupDidFailNotification") == 2,
    "Both migration-preparation and persistent-store failures must publish one terminal startup event.",
)

connect = method_body(SCENE, "- (void)carPlayDidConnectInterfaceController:")
failed_branch = connect.split(
    "if (appDelegate.databaseStartupState == ICDatabaseStartupStateFailed)", 1
)[1].split("if (appDelegate.databaseStartupState != ICDatabaseStartupStateReady)", 1)[0]
require(
    "carPlayDatabaseUnavailableTemplateForError" in failed_branch
    and "carPlaySetRootTemplate" in failed_branch
    and "return;" in failed_branch,
    "CarPlay connecting after a terminal database failure must immediately receive an explanatory root template.",
)
preparing_branch = connect.split(
    "if (appDelegate.databaseStartupState != ICDatabaseStartupStateReady)", 1
)[1].split("return;", 1)[0]
require(
    "InstacastMainViewControllerDidBecomeReadyNotification" in preparing_branch
    and "InstacastDatabaseStartupDidFailNotification" in preparing_branch,
    "CarPlay connecting during preparation must observe both possible terminal outcomes.",
)

failure = method_body(
    SCENE.split("@implementation InstacastSceneDelegate", 1)[1],
    "- (void)_databaseDidFailForCarPlay:",
)
require(
    "removeObserver" in failure
    and "carPlayDatabaseUnavailableTemplateForError" in failure
    and "carPlaySetRootTemplate" in failure,
    "The failure callback must stop waiting and install the terminal CarPlay template.",
)
disconnect = method_body(SCENE, "- (void)carPlayDidDisconnectInterfaceController:")
require(
    "InstacastDatabaseStartupDidFailNotification" in disconnect,
    "Disconnecting while startup is unresolved must remove the failure observer too.",
)


print("Database CarPlay failure regression checks passed")
