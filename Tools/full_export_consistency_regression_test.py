#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


export = body("- (void)_beginFullExportAfterBusyState")
selection = body("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")

require("saveReturningError" in export and "finishFullExportWithURL:nil error:" in export,
        "Full export must stop and report a failed pre-export save instead of exporting stale state.")
require("setQueryGenerationFromToken" in export and "currentQueryGenerationToken" in export,
        "All full-backup fetches must be pinned to one Core Data query generation.")
require("anyExportInProgress" in selection and "importInProgress" in selection,
        "Import/reset actions must not mutate the database while any export snapshot is running.")
for method in ["exportEverything", "exportSubscriptions", "exportBookmarks"]:
    method_body = body(f"- (void) {method}")
    require("importInProgress" in method_body,
            f"{method} must not start while an import is changing the database.")


print("Full-export consistency regression checks passed")
