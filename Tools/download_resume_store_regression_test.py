#!/usr/bin/env python3
"""Pins race-free, per-download resume-data persistence."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OPERATION = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()
HEADER = (ROOT / "Classes" / "CacheOperation_iOS7.h").read_text()
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = source.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("ICDownloadResumeStoreQueue" in OPERATION and "DISPATCH_QUEUE_SERIAL" in OPERATION,
        "Resume save/read/delete operations need one serial ordering domain.")
require("DownloadResumeData" in OPERATION and "NSApplicationSupportDirectory" in OPERATION,
        "Large opaque resume blobs belong in a dedicated non-preferences directory.")
require("NSDataWritingAtomic" in OPERATION and "AddSkipBackupAttributeToFile" in OPERATION,
        "Each per-download resume blob must be replaced atomically and excluded from backups.")
require("ICResumeDataPathForIdentifier" in OPERATION,
        "Resume state must be independently addressable by download identifier.")
require("MD5Hash" in OPERATION and "identifier" in OPERATION,
        "Resume filenames must hash identifiers instead of accepting path components from external data.")

save = method_body(OPERATION, "- (void) _saveResumeData:")
read = method_body(OPERATION, "- (NSData*) _resumeData")
require("ICDownloadResumeStoreSync" in save and "ICWriteResumeData" in save,
        "Save must serialize one identifier's atomic file write.")
require("ICDownloadResumeStoreSync" in read and "ICReadAndDeleteResumeData" in read,
        "Resume data is a one-use token and must be atomically taken from the ordered store.")

for body, operation_name in ((save, "save"), (read, "read")):
    require("mutableCopy" not in body and "kUserDefaultsResumeInfoKey" not in body,
            f"Resume {operation_name} must not read-modify-write the shared legacy defaults dictionary.")

require("ICMigrateLegacyResumeDataIfNeeded" in OPERATION and
        "kUserDefaultsResumeInfoKey" in OPERATION and
        "removeObjectForKey:kUserDefaultsResumeInfoKey" in OPERATION,
        "The old unbound shared dictionary needs one ordered retirement before the URL-bound store is used.")
require("NSURLSessionResumeInfoLocalPath" not in OPERATION,
        "Opaque Apple resume data must not be interpreted through undocumented private plist keys.")
require("remoteURL" in save and "self.remoteURL" in read,
        "A resume token must be bound to the media URL that produced it so feed URL changes cannot fetch old audio.")
require("prepareResumeInfoStore" in HEADER and "deleteAllResumeInfo" in HEADER,
        "CacheManager needs explicit startup migration and clear-all APIs.")
require("[CACHE_OPERATION_CLASS prepareResumeInfoStore]" in MANAGER,
        "Legacy migration must begin off-main during CacheManager startup, before downloads need it.")

public_delete = method_body(OPERATION, "+ (void) deleteResumeInfoForIdentifier:")
require("ICDownloadResumeStoreAsync" in public_delete,
        "A UI-triggered cache deletion must enqueue its tiny resume-file deletion without blocking main.")
clear_all = method_body(OPERATION, "+ (void) deleteAllResumeInfo")
require("ICDownloadResumeStoreAsync" in clear_all and "ICDeleteAllResumeData" in clear_all,
        "Clear-all must remove the resume directory on the serial I/O queue.")
require("[CACHE_OPERATION_CLASS deleteAllResumeInfo]" in MANAGER and
        "removeObjectForKey:kUserDefaultsResumeInfoKey" not in MANAGER,
        "CacheManager must clear both migrated and legacy resume state through the ordered store.")

main = method_body(OPERATION, "- (void) main")
cancel_call = main.find("cancelByProducingResumeData")
cancel_wait = main.find("dispatch_semaphore_wait(cancellationSemaphore")
terminal_callback = main.find("[self _notifyDidEndOnMainThread]")
require(cancel_call != -1 and cancel_wait > cancel_call and terminal_callback > cancel_wait,
        "Cancel must wait for resume persistence before reporting the operation terminal.")
cancel_block = main[cancel_call:cancel_wait]
require("_saveResumeData:resumeData" in cancel_block and
        cancel_block.find("_saveResumeData:resumeData") < cancel_block.find("dispatch_semaphore_signal(cancellationSemaphore)"),
        "The cancel callback must finish the ordered store write before releasing main.")
setup_callback = main.split("getTasksWithCompletionHandler:", 1)[1].split("while (!setupFinished", 1)[0]
require("[self isCancelled]" in setup_callback and
        setup_callback.find("[self isCancelled]") < setup_callback.find("for (NSURLSessionDownloadTask* candidate in downloadTasks)"),
        "A delayed URLSession setup callback must not create or resume work after cancel.")
require("_taskBelongsToOperation:candidate session:activeSession" in setup_callback and
        "candidate.taskIdentifier > matchingTask.taskIdentifier" in setup_callback,
        "Background reattachment must select the newest active task for the exact current media URL.")
require(main.count("sessionWithConfiguration:config") == 1,
        "An invalid resume token must fall back to a fresh task on the existing session, not create a competing session with the same identifier.")

background = method_body(MANAGER, "- (void) handleEventsForBackgroundURLSession:")
require("if (!savedInfo)" in background and "_cancelOrphanedBackgroundSession" in background,
        "A background wake without a persisted user job must cancel the orphan session, never restart the download.")

print("Download resume-store regression checks passed")
