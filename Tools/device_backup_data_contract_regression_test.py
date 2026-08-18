#!/usr/bin/env python3
"""Pins durable InstacastPlus data to device-backup locations."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
APP_DELEGATE = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing function/method: {signature}")
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
    raise AssertionError(f"Unterminated function/method: {signature}")


database_init = body(DATABASE, "- (id) init")
require(
    'pathToSubfolder:@"Data" parent:[DatabaseManager pathToDocuments]' in database_init
    and "_databaseURL = [NSURL fileURLWithPath:[dataPath stringByAppendingPathComponent:_DataStoreFile()]]" in database_init,
    "Subscriptions, episode state, and lists must remain in the backed-up Documents database.",
)
require(
    "AddSkipBackupAttributeToFile(dataPath)" not in database_init
    and "AddSkipBackupAttributeToFile(_databaseURL.path)" not in database_init,
    "The durable podcast database must not be excluded from device backups.",
)
require(
    'pathToSubfolder:@"Episodes" parent:[DatabaseManager pathToDocuments]' in database_init
    and "AddSkipBackupAttributeToFile(fileCachePath)" in database_init,
    "Redownloadable episode media must remain explicitly excluded from device backups.",
)

initialize = body(APP_DELEGATE, "+ (void) initialize")
require(
    "registerDefaults:defaults" in initialize
    and "removePersistentDomainForName" not in initialize
    and "setPersistentDomain" not in initialize,
    "Startup must register fallback settings without replacing restored NSUserDefaults.",
)

print("Device-backup durable-data contract regression checks passed")
