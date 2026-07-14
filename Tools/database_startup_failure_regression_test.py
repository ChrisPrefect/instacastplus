#!/usr/bin/env python3
"""Pins a non-destructive, user-visible startup state when Core Data cannot open."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DB_H = (ROOT / "Classes" / "Model" / "DatabaseManager.h").read_text()
DB_M = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
APP_H = (ROOT / "Classes" / "InstacastAppDelegate.h").read_text()
APP_M = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(),
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require("initializationError" in DB_H and "initializationError" in DB_M,
        "DatabaseManager must retain the real store-open failure for startup UI and diagnostics.")

init_start = DB_M.find("- (id) init")
init_end = DB_M.find("- (void) _createDatabase", init_start)
require(init_start != -1 and init_end != -1, "DatabaseManager init boundary is missing.")
initializer = DB_M[init_start:init_end]
context_check = initializer.find("NSManagedObjectContext* startupContext = self.objectContext;")
create = initializer.find("[self _createDatabase]")
fetch_controller = initializer.find("_feedsController =")
require(-1 < context_check < create < fetch_controller,
        "The store must be opened and checked before default inserts or fetched-results controllers are created.")
require("if (!startupContext)" in initializer[context_check:create] and "return self;" in initializer[context_check:create],
        "A failed store open must stop DatabaseManager initialization instead of continuing with a nil context.")
prepare_start = DB_M.find("+ (BOOL)_prepareDataStoreMigrationWithError:", DB_M.find("@implementation DatabaseManager"))
prepare_end = DB_M.find("+ (void) prepareDataStoreMigrationWithCompletion:", prepare_start)
preparation = DB_M[prepare_start:prepare_end]
require("ICDataStoreMigrationPhaseBuilding" in preparation and
        preparation.find("_removePreparedDataStoreAtURL") < preparation.find("migratePersistentStore"),
        "An interrupted supported migration must remain building and discard only its non-authoritative target before retrying.")
require("removeItemAtURL:sourceURL" not in preparation and "removeItemAtPath:sourceURL.path" not in preparation,
        "Preparation failure must never delete the authoritative legacy source store.")

container_start = DB_M.find("- (NSPersistentContainer *)persistentContainer")
container_end = DB_M.find("- (void)refreshAllObjects", container_start)
container = DB_M[container_start:container_end]
require("storeLoadError" in container and "self.initializationError" in container,
        "The persistent-container failure must be retained, not only logged.")
require("removeItemAtURL:storeURL" not in container and "removeItemAtPath:storeURL.path" not in container,
        "A failed open must never delete the user's database as recovery behavior.")

require("databaseUnavailableViewControllerForError:" in APP_H and
        "databaseUnavailableViewControllerForError:" in APP_M,
        "Startup needs one shared, user-visible database failure screen.")

startup_start = APP_M.find("- (void) _startUpApplicationWithLaunchOptions:")
startup_end = APP_M.find("#pragma mark -", startup_start + 1)
startup = APP_M[startup_start:startup_end]
require(startup.find("initializationError") < startup.find("[MainViewController_4 mainViewController]"),
        "Legacy startup must stop before constructing database-backed UI after a store failure.")

scene_start = SCENE.find("- (void)scene:(UIScene *)scene willConnectToSession:")
scene_end = SCENE.find("- (void)scene:(UIScene *)scene openURLContexts:", scene_start)
scene_connect = SCENE[scene_start:scene_end]
require(scene_connect.find("initializationError") < scene_connect.find("[MainViewController_4 mainViewController]"),
        "Scene startup must install the error screen before constructing database-backed UI.")

for localization in LOCALIZATIONS:
    for key in (
        "Local Data Unavailable",
        "InstacastPlus could not open the local podcast database. Your data was left unchanged. Check the available storage, restart the device, and open InstacastPlus again.",
    ):
        require(f'"{key}" =' in localization, f"Database startup failure text is not localized: {key}")

print("Database startup failure regression checks passed")
