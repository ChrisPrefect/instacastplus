#!/usr/bin/env python3
"""Pins database startup until iOS protected files are actually available."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = APP_DELEGATE.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = APP_DELEGATE.find("{", start)
    depth = 0
    for index in range(brace, len(APP_DELEGATE)):
        if APP_DELEGATE[index] == "{":
            depth += 1
        elif APP_DELEGATE[index] == "}":
            depth -= 1
            if depth == 0:
                return APP_DELEGATE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


launch = method_body("- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:")
begin = method_body("- (void)_beginDatabaseStartupWithLaunchOptions:")
protected_data = method_body("- (void)_protectedDataDidBecomeAvailable:")

require(
    "pendingDatabaseLaunchOptions" in launch
    and "application.protectedDataAvailable" in launch
    and "ICDatabaseStartupStatePreparing" in launch,
    "A locked cold launch must retain launch options and remain on the preparing UI.",
)
require(
    "UIApplicationProtectedDataDidBecomeAvailable" in launch
    and launch.find("UIApplicationProtectedDataDidBecomeAvailable") < launch.find("_beginDatabaseStartupWithLaunchOptions"),
    "The unlock observer must be installed before startup can inspect the database.",
)
require(
    "dataStoreNeedsMigration" not in launch
    and "prepareDataStoreMigrationWithCompletion" not in launch,
    "didFinishLaunching must never touch the protected database directly.",
)
require(
    "databaseStartupDidBegin" in begin
    and begin.find("databaseStartupDidBegin = YES") < begin.find("dataStoreNeedsMigration")
    and "dataStoreNeedsMigration" in begin
    and "prepareDataStoreMigrationWithCompletion" in begin,
    "The single startup authority must claim startup exactly once before database preflight.",
)
require(
    "_beginDatabaseStartupWithLaunchOptions" in protected_data
    and "pendingDatabaseLaunchOptions" in protected_data,
    "The protected-data notification must resume the retained cold launch.",
)

print("Protected-data database startup regression checks passed")
