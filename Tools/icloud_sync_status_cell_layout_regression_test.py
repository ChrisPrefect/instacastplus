#!/usr/bin/env python3
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SETTINGS = (ROOT / "Classes/ICiCloudSyncSettingsViewController.m").read_text()
DE_STRINGS = (ROOT / "Resources/de.lproj/Localizable.strings").read_text()
EN_STRINGS = (ROOT / "Resources/en.lproj/Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = SETTINGS.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = SETTINGS.find("{", start)
    require(brace != -1, f"Missing body: {signature}")

    depth = 0
    for index in range(brace, len(SETTINGS)):
        if SETTINGS[index] == "{":
            depth += 1
        elif SETTINGS[index] == "}":
            depth -= 1
            if depth == 0:
                return SETTINGS[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


def localized_value(strings: str, key: str) -> str:
    match = re.search(
        rf'^"{re.escape(key)}"\s*=\s*"([^"]*)";',
        strings,
        flags=re.MULTILINE,
    )
    require(match is not None, f"Missing localization: {key}")
    return match.group(1)


cell_for_row = method_body(
    "- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath"
)
status_branch = cell_for_row.split(
    "if (indexPath.section == ICiCloudSyncSettingsSectionStatus)", 1
)[1].split("if (indexPath.section == ICiCloudSyncSettingsSectionOptions)", 1)[0]
require(
    "NSString *statusText = [ICiCloudSyncManager sharedManager].statusText;" in status_branch
    and "[self statusCellWithStatusText:statusText]" in status_branch,
    "The status row must pass one immutable manager status into a dedicated self-sizing status cell.",
)

status_cell = method_body("- (UITableViewCell*)statusCellWithStatusText:")
require(
    "[UIListContentConfiguration subtitleCellConfiguration]" in status_cell
    and "cell.contentConfiguration = content" in status_cell,
    "The status row must use UIListContentConfiguration so UIKit can self-size multiline content reliably.",
)
require(
    "content.prefersSideBySideTextAndSecondaryText = NO" in status_cell
    and "content.secondaryText = statusText" in status_cell,
    "The activity/error must be one stacked status value, never combined with an unrelated counter column.",
)
require(
    "content.secondaryTextProperties.numberOfLines = 0" in status_cell
    and "content.secondaryTextProperties.lineBreakMode = NSLineBreakByWordWrapping" in status_cell
    and "NSLineBreakByTruncating" not in status_cell,
    "Long iCloud status and error guidance must wrap completely without a truncating ellipsis.",
)
require(
    "content.textProperties.adjustsFontForContentSizeCategory = YES" in status_cell
    and "content.secondaryTextProperties.adjustsFontForContentSizeCategory = YES" in status_cell,
    "The status row must continue to self-size when Dynamic Type changes.",
)
require(
    'cell.accessibilityLabel = @"Status".ls' in status_cell
    and "cell.accessibilityValue = statusText" in status_cell
    and "cell.isAccessibilityElement = YES" in status_cell,
    "VoiceOver must receive the same complete status that is visible on screen.",
)
for foreign_source in ["cloudInventory", "syncCounts", "episodeStates", "subscriptionsTotal"]:
    require(
        foreign_source not in status_cell,
        f"The status cell must not append a foreign counter source: {foreign_source}",
    )

row_height = method_body(
    "- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath"
)
require(
    "return UITableViewAutomaticDimension" in row_height,
    "The wrapped status content must be allowed to determine its row height.",
)

generic_error_key = "iCloud Sync konnte nicht abgeschlossen werden."
german_error = localized_value(DE_STRINGS, generic_error_key)
english_error = localized_value(EN_STRINGS, generic_error_key)
require(
    german_error != generic_error_key and "automatisch" in german_error.lower(),
    "The German generic failure must explain the automatic retry instead of ending without guidance.",
)
require(
    english_error != "iCloud Sync could not be completed."
    and "automatically" in english_error.lower(),
    "The English generic failure must explain the automatic retry instead of ending without guidance.",
)


print("iCloud status cell layout regression checks passed")
