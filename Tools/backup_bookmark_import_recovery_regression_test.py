#!/usr/bin/env python3
"""Pins crash-safe, idempotent recovery for batched bookmark backup imports."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text(encoding="utf-8")
HEADER = (ROOT / "Classes" / "InstacastBackupImporter.h").read_text(encoding="utf-8")
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text(encoding="utf-8")
SCENE_DELEGATE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text(encoding="utf-8")
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(encoding="utf-8"),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(encoding="utf-8"),
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
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


def ordered(source: str, *tokens: str) -> bool:
    position = -1
    for token in tokens:
        position = source.find(token, position + 1)
        if position < 0:
            return False
    return True


require("resumePendingBookmarkImportIfNeeded" in HEADER,
        "The importer needs a public app-start recovery hook.")
require("ICBackupBookmarkStageURL" in IMPORTER and "NSApplicationSupportDirectory" in IMPORTER,
        "Pending bookmark imports must be staged persistently in Application Support.")
require("ICBackupPresentBookmarkRecoveryError" in IMPORTER
        and "UIApplicationStateActive" in IMPORTER
        and "showBackgroundErrorWithTitle" in IMPORTER,
        "An active app must show one non-modal background error when automatic recovery fails.")
require("ICBackupBeginBookmarkRecovery" in IMPORTER,
        "Concurrent startup/foreground hooks must coalesce into one visible recovery attempt.")
require("NSPropertyListBinaryFormat_v1_0" in IMPORTER and "NSDataWritingAtomic" in IMPORTER,
        "The recovery payload must be a compact atomically replaced property list.")
require('@"state"' in IMPORTER and '@"cancelled"' in IMPORTER,
        "The durable stage must distinguish interrupted work from an explicit cancellation.")
require("ICBackupQuarantineBookmarkStage" in IMPORTER and "bookmarks.invalid.plist" in IMPORTER,
        "A corrupt/unsupported stage needs one bounded quarantine path instead of blocking every future import.")
require("NSFileProtectionCompleteUntilFirstUserAuthentication" in IMPORTER
        and "NSURLIsExcludedFromBackupKey" in IMPORTER,
        "The transient recovery payload needs appropriate protection and must not enter backups.")
for field in ('@"feedURL"', '@"episodeGuid"', '@"position"', '@"title"'):
    require(field in IMPORTER, f"Bookmark staging is missing {field}.")

prepare = body(IMPORTER, "static BOOL ICBackupPrepareBookmarkStage")
require("ICBackupReadBookmarkStage" in prepare and "isEqualToArray" in prepare,
        "Retry must reuse the exact pending stage instead of overwriting recovery state.")
require("ICBackupBookmarkPendingConflictError" in prepare,
        "A different backup must not replace an unfinished bookmark import.")
require(ordered(prepare, "if (stageExists)", "isEqualToArray", "ICBackupWriteBookmarkStage"),
        "A new stage may only be written after pending-state comparison.")
require(ordered(prepare, "stageInvalid", "ICBackupQuarantineBookmarkStage", "*error = readError", "return NO"),
        "A syntactically invalid old stage must be quarantined and request the original backup once.")

read_stage = body(IMPORTER, "static NSArray<NSDictionary *> *ICBackupReadBookmarkStage")
require(ordered(read_stage, "if (!data)", "ICBackupBookmarkRecoveryStateError", "propertyListWithData"),
        "A transient/protected-data read failure must retain the active stage for a later retry.")
require("stageInvalid" in read_stage and "ICBackupBookmarkInvalidStageError" in read_stage,
        "Parsed corrupt/unsupported stages must be distinguishable from retryable read failures.")

wrapper = body(IMPORTER, "+ (NSInteger)importBookmarksFromBackup:")
core = body(IMPORTER[IMPORTER.find("+ (NSInteger)importBookmarksFromBackup:"):],
            "+ (NSInteger)_importBookmarks:")
require(ordered(wrapper, "ICBackupPrepareBookmarkStage", "[self _importBookmarks:"),
        "The recovery stage must be durable before the first bookmark batch can save.")
require("operation:(NSOperation *)operation" in IMPORTER and "operation.isCancelled" in core,
        "Cancellation must belong to the concrete import operation, not mutable global state.")
require("_currentOperation.isCancelled" not in core,
        "Startup recovery must not inherit cancellation from another import.")
require(ordered(core, "performBlockAndWait", "if (operation.isCancelled)",
                "ICBackupMarkBookmarkStageCancelled", "return savedBookmarkCount"),
        "Once the worker observes cancellation, its durable cancelled state must precede return.")
require("bookmarkSaveBatchSize" in core and "[context save:&saveError]" in core,
        "Recovery must retain small private-context transactions rather than one large main-context save.")
require("ICBackupBookmarkExistsInIndex" in core,
        "Replayed batches must remain idempotent by checking durable bookmark identities.")
require(ordered(wrapper, "[self _importBookmarks:", "if (bookmarkImportError)", "ICBackupRemoveBookmarkStage"),
        "Save failure must return with the stage intact; cleanup belongs only after a successful replay.")
require("if (operation.isCancelled)" in wrapper and "ICBackupRemoveBookmarkStage" in wrapper,
        "Explicit cancellation must discard its recovery stage instead of silently resuming at launch.")
require(ordered(wrapper, "[self _importBookmarks:", "if (operation.isCancelled)",
                "ICBackupMarkBookmarkStageCancelled", "if (bookmarkImportError)"),
        "Observed cancellation must win over a simultaneous batch failure so launch cannot resume it.")
cancel_branch = wrapper[wrapper.find("if (operation.isCancelled)"):]
require(ordered(cancel_branch, "ICBackupMarkBookmarkStageCancelled", "ICBackupRemoveBookmarkStage"),
        "Cancellation intent must be durable before best-effort stage deletion.")
require("cleanupError" in cancel_branch and "ErrLog" in cancel_branch,
        "A cancelled stage that cannot be deleted must remain ignored and retry cleanup later.")
require("cleanupError" in wrapper and "*error = cleanupError" in wrapper,
        "A failed success-path cleanup must be reported and retained for idempotent launch recovery.")

resume = body(IMPORTER, "+ (void)resumePendingBookmarkImportIfNeeded")
require("ICBackupImportQueue" in resume and "NSQualityOfServiceUtility" in resume,
        "Launch recovery must be serialized with imports and run off the main thread at utility priority.")
require("NSInteger count = [self _importBookmarks:" not in resume,
        "Release builds must not retain a result used only by the compiled-out DebugLog macro.")
require(ordered(resume, "ICBackupReadBookmarkStage", "[self _importBookmarks:", "ICBackupRemoveBookmarkStage"),
        "Launch recovery must replay the staged source before deleting it.")
require("if (importError)" in resume and "return;" in resume,
        "Launch recovery must retain the stage after a failed batch for the next retry.")
require("protectedDataAvailable" in resume,
        "A stage protected before first unlock must remain pending instead of becoming a read failure.")
require("if (visibleError) ICBackupPresentBookmarkRecoveryError(visibleError)" in resume,
        "Every failed automatic attempt needs one coalesced visible background error.")
for failure in ("readError", "decodeError", "importError", "cleanupError"):
    require(any("finishAttempt(" in line and failure in line for line in resume.splitlines()),
            f"Automatic recovery does not visibly finish its {failure} path.")
require(ordered(resume, "stageInvalid", "ICBackupQuarantineBookmarkStage", "finishAttempt"),
        "Automatic recovery must quarantine invalid data and tell the user to re-import the original backup.")
require(ordered(resume, "stageInvalid", "App.applicationState != UIApplicationStateActive",
                "finishAttempt(nil)", "ICBackupQuarantineBookmarkStage"),
        "An invalid stage found before activation must remain pending until its warning can be shown.")
cancelled_resume = resume[resume.find("stageCancelled"):resume.find("[self _importBookmarks:")]
require("ICBackupRemoveBookmarkStage" in cancelled_resume and "return;" in cancelled_resume,
        "Launch recovery must only clean a cancelled stage, never replay it.")

startup = body(APP_DELEGATE, "- (void) _startUpApplicationWithLaunchOptions:")
require('#import "InstacastBackupImporter.h"' in APP_DELEGATE,
        "The app delegate must import the bookmark recovery owner.")
require(ordered(startup, "databaseManager.initializationError", "resumePendingBookmarkImportIfNeeded"),
        "Bookmark recovery may start only after the persistent store opened successfully.")
require("name:UIApplicationProtectedDataDidBecomeAvailable" in APP_DELEGATE
        and "UIApplicationProtectedDataDidBecomeAvailableNotification" not in APP_DELEGATE,
        "First-unlock must trigger another store-ready recovery attempt.")
foreground = body(SCENE_DELEGATE, "- (void)sceneDidBecomeActive:")
require('#import "InstacastBackupImporter.h"' in SCENE_DELEGATE
        and "resumePendingBookmarkImportIfNeeded" in foreground,
        "Active foreground entry must retry a protected stage and make any recovery error visible.")

for localization in LOCALIZATIONS:
    for key in (
        '"Bookmark Import Could Not Continue" =',
        '"The bookmark import was interrupted. Saved progress will continue automatically',
        '"The bookmark import recovery state could not be read or updated.',
        '"The saved bookmark recovery data is damaged or from an unsupported version.',
    ):
        require(key in localization, "Bookmark recovery guidance must be localized in German and English.")

print("Backup bookmark import recovery regression checks passed")
