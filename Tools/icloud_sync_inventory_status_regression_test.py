#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
SETTINGS = (ROOT / "Classes" / "ICiCloudSyncSettingsViewController.m").read_text()
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(),
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


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
    raise AssertionError(f"Unterminated method: {signature}")


inventory_refresh = method_body(MANAGER, "func refreshCloudInventory(reason:")
require(
    "cloudInventoryRefreshInProgress" in MANAGER
    and "cloudInventoryRefreshErrorText" in MANAGER,
    "The settings UI needs explicit inventory loading and error state, not only cached counts.",
)
require(
    "cloudInventoryRefreshErrorText = nil" in inventory_refresh
    and 'NSLocalizedString("iCloud data counts could not be updated."' in inventory_refresh
    and "postStateChanged()" in inventory_refresh,
    "Inventory refresh must publish loading, success, and failure state changes.",
)

header = method_body(SETTINGS, "- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:")
footer = method_body(SETTINGS, "- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:")
inventory_footer = method_body(SETTINGS, "- (NSString*)cloudInventoryFooterText")
require(
    '@"iCloud Data".ls' in header and '@"On iCloud".ls' not in header,
    "A cached inventory must be labelled as data, not presented as an unqualified live 'On iCloud' value.",
)
require(
    "cloudInventoryFooterText" in footer
    and "cloudInventoryRefreshInProgress" in inventory_footer
    and "cloudInventoryRefreshErrorText" in inventory_footer
    and "inventory.fetchDate" in inventory_footer,
    "The inventory footer must distinguish updating, stale/error, and last-checked states.",
)

for localization in LOCALIZATIONS:
    for key in (
        "iCloud Data",
        "Updating iCloud data…",
        "iCloud data counts could not be updated.",
        "Last checked %@.",
        "iCloud data has not been checked yet.",
    ):
        require(f'"{key}" =' in localization, f"Missing inventory status localization: {key}")


print("iCloud inventory status regression checks passed")
