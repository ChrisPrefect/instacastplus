#!/usr/bin/env python3
"""Pins every launch/lifecycle entry point behind verified database readiness."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP_HEADER = (ROOT / "Classes" / "InstacastAppDelegate.h").read_text()
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
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


for state in ("Preparing", "Ready", "Failed"):
    require(f"ICDatabaseStartupState{state}" in APP_HEADER,
            f"Missing explicit {state.lower()} database startup state.")

did_finish = method_body(
    APP,
    "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions",
)
begin_startup = method_body(APP, "- (void)_beginDatabaseStartupWithLaunchOptions:")
preparing = begin_startup.find("ICDatabaseStartupStatePreparing")
prepare = begin_startup.find("prepareDataStoreMigrationWithCompletion", preparing)
failed = begin_startup.find("ICDatabaseStartupStateFailed", prepare)
startup = begin_startup.find("_startUpApplicationWithLaunchOptions", prepare)
require(-1 < preparing < prepare < failed < startup,
        "AppDelegate must own asynchronous preparing/failed/ready startup instead of exposing the target early.")
require("_beginDatabaseStartupWithLaunchOptions" in did_finish
        and "prepareDataStoreMigrationWithCompletion" not in did_finish,
        "didFinishLaunching must enter the single protected-data-aware startup authority.")
require("performSelector:@selector(_startUpApplicationWithLaunchOptions:)" not in did_finish,
        "A delay still runs migration on the main thread and is not a readiness boundary.")

connect = method_body(
    SCENE,
    "- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions",
)
require("dataStoreNeedsMigration" not in connect,
        "SceneDelegate must consume AppDelegate's authoritative state, not race its own filesystem preflight.")
require("databaseStartupState" in connect and "ICDatabaseStartupStateFailed" in connect,
        "Scene connection must render preparing, ready, and failed states without missing a fast completion.")

for source, signature, forbidden in (
    (SCENE, "- (void)sceneWillEnterForeground:(UIScene *)scene", "DMANAGER"),
    (SCENE, "- (void)sceneDidEnterBackground:(UIScene *)scene", "DMANAGER"),
    (SCENE, "- (void)carPlayDidConnectInterfaceController:(CPInterfaceController*)interfaceController", "PlaybackManager"),
    (APP, "- (void)applicationDidEnterBackground:(UIApplication *)application", "DMANAGER"),
    (APP, "- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))handler", "ICiCloudSyncManager"),
    (APP, "- (void)application:(UIApplication *)application performFetchWithCompletionHandler:(void (^)(UIBackgroundFetchResult result))completionHandler", "DMANAGER"),
):
    body = method_body(source, signature)
    gate = body.find("databaseStartupState != ICDatabaseStartupStateReady")
    access = body.find(forbidden)
    require(-1 < gate < access,
            f"{signature} can still initialize database-dependent services while migration is preparing.")

startup_body = method_body(APP, "- (void) _startUpApplicationWithLaunchOptions:(NSDictionary *)launchOptions")
watch_start = startup_body.find("[[AppleWatchSyncManager sharedManager] start]")
ready_state = startup_body.find("ICDatabaseStartupStateReady", watch_start)
ready_notification = startup_body.find("InstacastMainViewControllerDidBecomeReadyNotification", ready_state)
require(-1 < watch_start < ready_state < ready_notification,
        "Ready must be published only after dependent services start, then replay deferred Scene work exactly once.")

print("Database migration lifecycle-gate regression checks passed")
