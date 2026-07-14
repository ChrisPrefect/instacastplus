#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "Model" / "SubscriptionManager.m").read_text()
HEADER = (ROOT / "Classes" / "Model" / "SubscriptionManager.h").read_text()
CONTROLLER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()


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


import_opml = body(MANAGER, "- (void)importOPMLData:(NSData *)data completion:(void (^)(NSError* error))")
import_urls = body(MANAGER, "- (void)importURLs:(NSArray<NSURL *> *)urls completion:(void (^)(NSError* error))")
finalize = body(MANAGER, "- (void)finalizeImportWithCompletion:(void (^)(NSError* error))")
read_file = body(CONTROLLER, "- (void)importFileFromURL:")
controller_opml = body(CONTROLLER, "- (void)importOPMLFromData:")

require("completion:(void (^)(NSError* error))completion" in HEADER,
        "OPML import callers need the parse/network/save error in their completion contract.")
require("self.importing = YES" in import_opml and "retainNetworkActivity" in import_opml,
        "Import lifecycle ownership must start before parsing so every exit balances it exactly once.")
require("errorHandler" in import_opml and "savingWasInterrupted:NO" in import_opml,
        "Parser and empty-import exits must finalize without decrementing a save interrupt they never began.")
require("beginInterruptSaving" in import_urls and "savingWasInterrupted:YES" in import_urls,
        "Only the URL subscription phase may own and end the DatabaseManager save interruption.")
require("if (savingWasInterrupted)" in finalize and "endInterruptSaving" in finalize,
        "Finalization must conditionally balance the save interruption.")
require("saveReturningError" in finalize and "completion(finalError)" in finalize,
        "Finalization must report persistence errors instead of always announcing success.")
require("[ICXMLImportLimits readDataFromURL:url error:&readError]" in read_file and "_finishImportWithError" in read_file,
        "The settings importer must report unreadable/empty files.")
require("selectedImportRow" in read_file and "isInstacastBackupData" in read_file,
        "The chosen import type must reject the other XML format instead of silently switching workflows.")
require("_finishImportWithError" in controller_opml,
        "OPML parser/subscription failures must close progress UI and remain visible to the user.")
require("completion:^(NSError* error)" in APP and "completion:^(NSError* error)" in SCENE,
        "External OPML imports must consume and display the new error contract.")
require("[ICXMLImportLimits readDataFromURL:url error:&readError]" in APP and "showBackgroundErrorWithTitle" in APP
        and "[ICXMLImportLimits readDataFromURL:url error:&readError]" in SCENE and "showBackgroundErrorWithTitle" in SCENE,
        "External OPML file access/read failures must be visible instead of only logged.")


print("OPML import error-lifecycle regression checks passed")
