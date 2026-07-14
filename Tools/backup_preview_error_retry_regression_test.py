#!/usr/bin/env python3
"""Pins actionable, retryable backup-preview analysis failures."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text()
ENGLISH = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
GERMAN = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace >= 0, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


guidance = (
    "The backup could not be analyzed. No data was changed. "
    "Check the available storage and try again."
)

analyze = body("- (void)analyzeBackup")
for token in (
    "self.analysisInProgress = YES",
    "self.analysisError = nil",
    "self.selectedCategories = [NSMutableSet set]",
    "++self.analysisGeneration",
    "[self.tableView reloadData]",
):
    require(token in analyze, f"Retry analysis must reset state before starting: {token}")

apply_result = body("- (void)applyAnalysisResult:")
require("generation != self.analysisGeneration" in apply_result,
        "An older analysis completion must not overwrite a newer retry.")
require("ErrLog" in apply_result and "self.analysisError = resolvedError" in apply_result,
        "Technical preview errors must remain logged while the UI shows localized guidance.")
require("self.analysisError = nil" in apply_result and "initializeSelectedCategories" in apply_result,
        "A successful retry must clear the failure and rebuild category selection.")

cell_builder = body("- (UITableViewCell *)tableView:")
error_branch = cell_builder.split("else if (self.analysisError)", 1)[1].split("} else {", 1)[0]
require('cell.textLabel.text = @"Try Again".ls' in error_branch
        and "cell.textLabel.textColor = ICTintColor" in error_branch
        and "UITableViewCellSelectionStyleDefault" in error_branch
        and f'@"{guidance}".ls' in error_branch,
        "The preview failure row must be an active retry control with one actionable explanation.")

category_cell = body("- (void)configureCategoryCell:")
category_error = category_cell.split("else if (self.analysisError)", 1)[1].split("}", 1)[0]
require("cell.detailTextLabel.text = nil" in category_error
        and '"Backup could not be analyzed"' not in category_error,
        "Disabled category rows must not repeat the same preview error eleven times.")

selection = body("- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:")
import_button = selection.split("indexPath.section == kImportButtonSection", 1)[1]
require("self.analysisError" in import_button
        and "[self analyzeBackup]" in import_button
        and "[self confirmImport]" in import_button,
        "Tapping the import-row error must retry analysis; a healthy row must still confirm import.")

require(f'"{guidance}" = "{guidance}";' in ENGLISH,
        "English preview retry guidance is missing.")
require(
    f'"{guidance}" = "Das Backup konnte nicht analysiert werden. Es wurden keine Daten geändert. '
    'Prüfe den freien Speicherplatz und versuche es erneut.";' in GERMAN,
    "German preview retry guidance is missing.",
)

print("Backup preview error/retry regression checks passed")
