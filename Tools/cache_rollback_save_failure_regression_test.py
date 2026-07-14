#!/usr/bin/env python3
"""Pins terminal error semantics when cache-file deletion and rollback save both fail."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(),
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    search_start = 0
    while True:
        start = SOURCE.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = SOURCE.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = SOURCE.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


finish = method_body("- (void)_finishCancelledDownloadRemovalForIdentifier:")
failure = finish.split("} else {", 1)[1]
require("rollbackSaveError" in failure and "saveReturningError" in failure,
        "A failed physical deletion must observe whether restoring the Core Data state commits.")
require("[DMANAGER save];" not in failure,
        "Rollback persistence errors must never be discarded.")

save = failure.find("rollbackSaveError")
save_failure = failure.find("if (rollbackSaveError)", save)
restore_event = failure.find("CacheManagerDidRestoreCacheNotification", save_failure)
restore_success_guard = failure.find("else", save_failure)
completion = failure.find("_completeCacheDeletionForIdentifier")
require(-1 < save < save_failure < restore_success_guard < restore_event < completion,
        "The restore event must be emitted only on the successful-save branch before completion.")
require("NSUnderlyingErrorKey: rollbackSaveError" in failure and "code:42" in failure,
        "Completion must propagate a concrete terminal rollback-persistence error.")

message = "The downloaded file is still present, but its local download state could not be restored. Restart InstacastPlus and try again."
require(f'@"{message}".ls' in failure,
        "The rollback-save failure needs actionable user guidance.")
for localization in LOCALIZATIONS:
    require(f'"{message}" =' in localization,
            "Rollback-save guidance must be localized in English and German.")

print("Cache rollback save-failure regression checks passed")
