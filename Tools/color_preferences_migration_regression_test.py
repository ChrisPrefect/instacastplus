#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "VemedioKit" / "UIColor+VMFoundation.h").read_text()
IMPLEMENTATION = (ROOT / "VemedioKit" / "UIColor+VMFoundation.m").read_text()


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


for selector in [
    "ic_colorFromDefaults:",
    "ic_colorHexFromDefaults:",
    "ic_setColor:",
]:
    require(selector in HEADER, f"The canonical color preference API is missing {selector}.")

reader = method_body(IMPLEMENTATION, "+ (UIColor*)ic_colorFromDefaults:")
require("unarchivedObjectOfClass:[UIColor class]" in reader,
        "Legacy UIColor archives must be decoded in exactly one central boundary.")
require("@try" in reader and "@catch" in reader,
        "Malformed legacy archives can raise Objective-C exceptions and must be contained.")
# ICTintColor resolves through this reader from cell layout. A NSUserDefaults write per
# read cost ~123 µs instead of ~0.2 µs and ran on every layout pass during swipes.
require("setObject:" not in reader and "removeObjectForKey:" not in reader,
        "The color read path must not write to NSUserDefaults — it runs from cell layout.")

require("ic_normalizeStoredColorInDefaults:" in HEADER,
        "The one-shot color migration must be part of the public API.")
migration = method_body(IMPLEMENTATION, "+ (void)ic_normalizeStoredColorInDefaults:")
require("removeObjectForKey:legacyArchiveKey" in migration,
        "A legacy archive must be removed after successful or failed migration.")
require("setObject:" in migration and "forKey:hexKey" in migration,
        "A valid legacy archive must be converted to the canonical hex preference.")

startup = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
require(startup.count("ic_normalizeStoredColorInDefaults:") >= 3,
        "Every stored color must be migrated at startup, otherwise the pure reader never canonicalises.")

setter = method_body(IMPLEMENTATION, "+ (void)ic_setColor:")
require("forKey:hexKey" in setter and "removeObjectForKey:legacyArchiveKey" in setter,
        "New color selections must store only canonical hex and remove the obsolete archive.")
require("NSKeyedArchiver" not in setter,
        "New color selections must not recreate the crash-prone UIKit archive.")

consumers = [
    "Classes/PlayerController.m",
    "Classes/ICAppearanceManager.m",
    "Classes/AppearanceSettingsViewController.m",
    "Classes/ImportExportSettingsViewController.m",
    "Classes/WidgetDataExporter.m",
    "Classes/InstacastBackupImporter.m",
]
for path in consumers:
    source = (ROOT / path).read_text()
    require("NSKeyedUnarchiver" not in source,
            f"{path} still decodes color archives outside the guarded migration boundary.")
    require("NSKeyedArchiver" not in source,
            f"{path} still writes the obsolete color archive instead of canonical hex.")

for path in consumers[:-1]:
    source = (ROOT / path).read_text()
    require("ic_colorFromDefaults:" in source or "ic_colorHexFromDefaults:" in source or "ic_setColor:" in source,
            f"{path} must use the canonical color preference API.")

print("Color preference migration regression checks passed")
