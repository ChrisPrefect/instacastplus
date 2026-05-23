#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INTENT = (ROOT / "InstacastWidgets" / "Intents" / "SmartListConfigIntent.swift").read_text()
PROVIDER = (ROOT / "InstacastWidgets" / "Providers" / "SmartListProvider.swift").read_text()
WIDGET = (ROOT / "InstacastWidgets" / "Widgets" / "SmartListWidget.swift").read_text()
EN_STRINGS = (ROOT / "InstacastWidgets" / "Resources" / "en.lproj" / "Localizable.strings").read_text()
DE_STRINGS = (ROOT / "InstacastWidgets" / "Resources" / "de.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def require_string(strings: str, key: str, value: str, language: str) -> None:
    require(f'"{key}" = "{value}";' in strings, f"{language} widget strings must localize {key} as {value}.")


require("enum SmartListOrder: String, AppEnum" in INTENT, "Smart List widget must define an AppEnum for episode order.")
require("case columns" in INTENT and "case rows" in INTENT, "Smart List order must offer Columns and Rows.")
require('@Parameter(title: "Order", default: .columns)' in INTENT, "Order must be the third widget option and default to Columns.")
require("var order: SmartListOrder" in INTENT, "Smart List configuration must store the selected order.")

compact_index = WIDGET[WIDGET.find("compactGridIndex"):]
require("switch entry.order" in compact_index, "Compact grid indexing must respect the selected order.")
require("column * rowCount + row" in compact_index, "Column order must fill the first column before the second.")
require("row * 2 + column" in compact_index, "Row order must preserve left-to-right row filling.")
require("compactGridIndex(row: row, column: 0" in WIDGET, "Compact grid left cell must use the shared indexer.")
require("compactGridIndex(row: row, column: 1" in WIDGET, "Compact grid right cell must use the shared indexer.")

require("let order: SmartListOrder" in PROVIDER, "Smart List timeline entries must carry the selected order.")
require("order: configuration.order" in PROVIDER, "Provider must pass the configured order into entries.")
require("order: order" in PROVIDER, "Provider helper must preserve order when building entries.")

require(".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)" in WIDGET, "Non-compact list content must be vertically centered while staying leading-aligned.")

for key in ["List", "Compact", "Order", "Columns", "Rows", "Choose which list to display."]:
    require_string(EN_STRINGS, key, key, "English")

for key, value in [
    ("List", "Liste"),
    ("Compact", "Kompakt"),
    ("Order", "Reihenfolge"),
    ("Columns", "Spalten"),
    ("Rows", "Zeilen"),
    ("Choose which list to display.", "Wähle die anzuzeigende Liste."),
]:
    require_string(DE_STRINGS, key, value, "German")
