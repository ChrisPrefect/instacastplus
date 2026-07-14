#!/usr/bin/env python3
"""Pins backup exclusion to the episode directory instead of every cached file."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DATABASE = (ROOT / "Classes" / "Model" / "DatabaseManager.m").read_text()
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
IOS_OPERATION = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()
MAC_OPERATION = (ROOT / "Classes" / "CacheOperation.m").read_text()


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
require("AddSkipBackupAttributeToFile(fileCachePath)" in database_init,
        "The persistent Episodes directory must be excluded from backup once at creation.")

index = body(MANAGER, "- (void)_buildCacheIndexInBackground")
require("AddSkipBackupAttributeToFile(filePath)" not in index,
        "Startup must not issue one backup-xattr write per downloaded episode.")

import_file = body(MANAGER, "- (void)_importFileAtURL:")
require("AddSkipBackupAttributeToFile(cachedURL.path)" not in import_file,
        "Imported children inherit the directory exclusion and need no extra metadata write.")

finalize_ios = body(IOS_OPERATION, "- (NSError*)_moveValidatedStagedDownloadToFinalURL")
require("AddSkipBackupAttributeToFile(self.localURL.path)" not in finalize_ios,
        "Each iOS download must not repeat the directory's backup metadata write.")

finish_mac = body(MAC_OPERATION, "- (void) main")
require("AddSkipBackupAttributeToFile([self.localURL path])" not in finish_mac,
        "Each macOS download must not repeat the directory's backup metadata write.")

print("Download backup-exclusion scaling regression checks passed")
