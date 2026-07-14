from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
HEADER = (ROOT / "Classes" / "Model" / "DatabaseManager.h").read_text()
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise SystemExit(f"Unterminated method: {signature}")


require(
    "#define MODEL_VERSION 5" in DATABASE
    and "#define DATA_STORE_GENERATION 6" in DATABASE,
    "The current Model5 bundle and the clean DataStore6 generation must be versioned independently.",
)
require(
    "prepareDataStoreMigrationWithCompletion" in HEADER,
    "Launch needs an asynchronous preparation API before DatabaseManager opens the target store.",
)

prepare = method_body(DATABASE, "+ (void) prepareDataStoreMigrationWithCompletion:")
implementation = DATABASE[DATABASE.find("@implementation DatabaseManager"):]
migration = method_body(implementation, "+ (BOOL)_prepareDataStoreMigrationWithError:")
require(
    "QOS_CLASS_UTILITY" in prepare and "dispatch_async" in prepare,
    "The multi-second clean-store rewrite must run on a utility queue while the migration spinner stays responsive.",
)
require(
    'ICDataStoreMigrationPhaseBuilding' in DATABASE
    and 'ICDataStoreMigrationPhaseReady' in DATABASE
    and 'sourcePath' in migration
    and 'targetPath' in migration
    and 'entityCounts' in migration
    and "NSDataWritingAtomic" in DATABASE,
    "A durable plist marker must preserve exact source/target paths, phase, and verified counts across process kills.",
)
require(
    "migratePersistentStore" in migration
    and "compatibleSourceModel" in migration
    and "NSPersistentHistoryTrackingKey: @YES" in migration
    and "NSPersistentHistoryTrackingKey: @NO" in migration,
    "Use supported Core Data migration: open the legacy source with its compatible model/history and write a history-free modeled target.",
)
require(
    "quick_check" in DATABASE
    and "entityCounts" in migration
    and "isEqualToDictionary" in migration,
    "A target is ready only after SQLite integrity and exact modeled-entity counts match; model compatibility alone accepts a killed empty store.",
)
require(
    "copyItemAtURL:urlOfLastDataStoreFile" not in DATABASE,
    "The old raw SQLite/WAL/SHM copy path must be removed; it preserves obsolete ANSCK/history tables and created the kill race.",
)

initializer = method_body(DATABASE, "- (id) init")
ready_check = initializer.find("ICDataStoreMigrationPhaseReady")
store_open = initializer.find("self.objectContext")
save = initializer.find("saveReturningError", store_open)
marker_remove = initializer.find("removeItemAtURL:migrationMarkerURL", save)
source_cleanup = initializer.find("_deleteObsoleteDataStores", marker_remove)
require(
    -1 < ready_check < store_open < save < marker_remove < source_cleanup,
    "Only a ready target may open; retain source and marker until the target opens and the app's own migrations save successfully.",
)

persistent_container = method_body(DATABASE, "- (NSPersistentContainer *)persistentContainer")
export_context = method_body(DATABASE, "- (NSManagedObjectContext*)newExportBackgroundContext")
require(
    "NSPersistentHistoryTrackingKey" not in persistent_container
    and "NSPersistentHistoryTrackingKey" not in export_context,
    "The clean live store and read-only export coordinator must not restart unused persistent-history growth.",
)

launch = method_body(
    APP_DELEGATE,
    "- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions",
)
begin_startup = method_body(
    APP_DELEGATE,
    "- (void)_beginDatabaseStartupWithLaunchOptions:",
)
require(
    "_beginDatabaseStartupWithLaunchOptions" in launch
    and "prepareDataStoreMigrationWithCompletion" not in launch
    and "prepareDataStoreMigrationWithCompletion" in begin_startup
    and "_startUpApplicationWithLaunchOptions" in begin_startup
    and "performSelector:@selector(_startUpApplicationWithLaunchOptions:)" not in begin_startup,
    "App launch must await asynchronous verified preparation instead of delaying 0.1 seconds and then blocking the main thread.",
)
