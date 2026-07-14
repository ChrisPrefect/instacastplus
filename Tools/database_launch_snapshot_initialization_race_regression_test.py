#!/usr/bin/env python3
"""Pins database-touching launch diagnostics behind successful store initialization."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


snapshot_wrapper = method_body(MANAGER, "@objc nonisolated static func logSyncMetadataStorageSnapshot")
snapshot_reader = method_body(METADATA, "nonisolated static func syncMetadataStorageSnapshot")
require("Task.detached" in snapshot_wrapper,
        "The launch diagnostic is no longer detached; update this concurrency proof.")
require("DatabaseManager.shared()?.newBackgroundContext()" in snapshot_reader,
        "The launch diagnostic no longer opens Core Data; update this concurrency proof.")

did_finish = method_body(
    APP,
    "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions",
)
startup = method_body(APP, "- (void) _startUpApplicationWithLaunchOptions:(NSDictionary *)launchOptions")
snapshot_call = '[ICiCloudSyncManager logSyncMetadataStorageSnapshot:@"launch"]'

# Starting this detached database read from didFinishLaunching races the main startup call to
# DatabaseManager.sharedDatabaseManager. The singleton intentionally exposes its allocated object
# during recursive init, so another thread can observe a half-built persistent container.
require(snapshot_call not in did_finish,
        "A detached launch diagnostic opens Core Data before migration/startup owns the store.")

snapshot_index = startup.find(snapshot_call)
error_guard = startup.find("if (databaseManager.initializationError)")
normal_ui = startup.find("MainViewController_4* mainViewController", error_guard)
widget_start = startup.find("[[WidgetDataExporter sharedExporter] startObserving]", normal_ui)
require(-1 < error_guard < normal_ui < snapshot_index < widget_start,
        "The launch metadata snapshot must start only after DatabaseManager initialized successfully and before dependent services start.")

shared_manager = method_body(DATABASE, "+ (DatabaseManager*) sharedDatabaseManager")
lock = shared_manager.find("@synchronized (self)")
publish = shared_manager.find("gSharedDatabaseManager = [self alloc]", lock)
initialize = shared_manager.find("gSharedDatabaseManager = [gSharedDatabaseManager init]", publish)
require(-1 < lock < publish < initialize,
        "DatabaseManager must serialize first initialization while retaining same-thread recursive access to the pre-published object.")

print("Database launch snapshot initialization-race regression checks passed")
