#!/usr/bin/env python3
import ast
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def read(path: str) -> str:
    return (ROOT / path).read_text()


def strings_dict(path: str) -> dict[str, str]:
    data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(ROOT / path)])
    return json.loads(data)


APP_EN = strings_dict("Resources/en.lproj/Localizable.strings")
APP_DE = strings_dict("Resources/de.lproj/Localizable.strings")
WATCH_EN = strings_dict("InstacastWatch/en.lproj/Localizable.strings")
WATCH_DE = strings_dict("InstacastWatch/de.lproj/Localizable.strings")
WIDGET_EN = strings_dict("InstacastWidgets/Resources/en.lproj/Localizable.strings")
WIDGET_DE = strings_dict("InstacastWidgets/Resources/de.lproj/Localizable.strings")


for name, en_strings, de_strings in [
    ("app", APP_EN, APP_DE),
    ("watch", WATCH_EN, WATCH_DE),
    ("widgets", WIDGET_EN, WIDGET_DE),
]:
    require(set(en_strings) == set(de_strings), f"{name} localization keys differ between English and German.")


def strip_comments(source: str) -> str:
    result = []
    index = 0
    in_string = False
    string_quote = ""
    escaped = False
    while index < len(source):
        char = source[index]
        if in_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == string_quote:
                in_string = False
            index += 1
            continue

        if char in {'"', "'"}:
            in_string = True
            string_quote = char
            result.append(char)
            index += 1
            continue

        if char == "/" and index + 1 < len(source) and source[index + 1] == "/":
            while index < len(source) and source[index] != "\n":
                index += 1
            result.append("\n")
            continue

        if char == "/" and index + 1 < len(source) and source[index + 1] == "*":
            index += 2
            while index + 1 < len(source) and not (source[index] == "*" and source[index + 1] == "/"):
                result.append("\n" if source[index] == "\n" else " ")
                index += 1
            index += 2
            continue

        result.append(char)
        index += 1

    return "".join(result)


def unescape_literal(content: str) -> str:
    try:
        return ast.literal_eval(f'"{content}"')
    except Exception:
        return content


COMMON_PATTERNS = [
    ("objc_ls", re.compile(r'@"((?:[^"\\]|\\.)*)"\s*\.ls')),
    ("objc_nslocalized", re.compile(r'NSLocalizedString\s*\(\s*@"((?:[^"\\]|\\.)*)"')),
    ("swift_nslocalized", re.compile(r'NSLocalizedString\s*\(\s*"((?:[^"\\]|\\.)*)"')),
]

APP_INTENT_PATTERNS = [
    ("localized_resource", re.compile(r'LocalizedStringResource\s*=\s*"((?:[^"\\]|\\.)*)"')),
    ("intent_description", re.compile(r'IntentDescription\s*\(\s*"((?:[^"\\]|\\.)*)"')),
    ("parameter_title", re.compile(r'@Parameter\s*\(\s*title:\s*"((?:[^"\\]|\\.)*)"')),
    ("summary", re.compile(r'\bSummary\s*\(\s*"((?:[^"\\]|\\.)*)"')),
    ("shortcut_title", re.compile(r'shortTitle:\s*"((?:[^"\\]|\\.)*)"')),
    ("shortcut_phrase", re.compile(r'"((?:[^"\\]|\\.)*\\\(\.(?:applicationName|\$[A-Za-z_][A-Za-z0-9_]*)\)(?:[^"\\]|\\.)*)"')),
]

WATCH_SWIFTUI_PATTERNS = [
    ("swiftui_static", re.compile(r'\b(?:Text|Label|Button|UnavailableWatchView\(title:)\s*\(\s*"((?:[^"\\]|\\.)*)"')),
]


def source_files(root: str) -> list[Path]:
    return sorted(
        path for path in (ROOT / root).rglob("*")
        if path.suffix in {".m", ".mm", ".h", ".swift"}
    )


def literal_is_localizable(literal: str, pattern_name: str, path: Path) -> bool:
    if literal in {"", "InstacastPlus"}:
        return False
    if path.name == "WidgetSampleData.swift":
        return False
    if pattern_name == "swiftui_static" and r"\(" in literal:
        return False
    if re.fullmatch(r"[%@0-9xX .:/_\-+−]+", literal):
        return False
    return True


def require_source_strings_localized(root: str, localized_keys: set[str], extra_patterns: list[tuple[str, re.Pattern]]) -> None:
    missing = []
    for path in source_files(root):
        source = path.read_text(errors="ignore")
        stripped = strip_comments(source)
        patterns = list(COMMON_PATTERNS)
        if "AppIntents" in path.parts or path.name == "ICAppShortcuts.swift":
            patterns += APP_INTENT_PATTERNS
        if root == "InstacastWatch":
            patterns += WATCH_SWIFTUI_PATTERNS
        patterns += extra_patterns

        for pattern_name, pattern in patterns:
            if pattern_name.startswith("shortcut_") and path.name != "ICAppShortcuts.swift":
                continue
            for match in pattern.finditer(stripped):
                literal = unescape_literal(match.group(1))
                if not literal_is_localizable(literal, pattern_name, path):
                    continue
                if literal not in localized_keys:
                    line = source.count("\n", 0, match.start()) + 1
                    missing.append(f"{path.relative_to(ROOT)}:{line}: {literal}")

    require(not missing, "Missing localization keys:\n" + "\n".join(missing[:80]))


require_source_strings_localized("Classes", set(APP_EN), [])
require_source_strings_localized("InstacastWatch", set(WATCH_EN), [])
require_source_strings_localized("InstacastWidgets", set(WIDGET_EN), [])


playback_intents = read("Classes/AppIntents/ICPlaybackIntents.swift")
content_intents = read("Classes/AppIntents/ICContentIntents.swift")
app_delegate = read("Classes/InstacastAppDelegate.m")
scene_delegate = read("Classes/InstacastSceneDelegate.m")
view_functions_h = read("Classes/ViewFunctions.h")
view_functions_m = read("Classes/ViewFunctions.m")

for token in [
    "ICLocalizedIntentDialog(\"Playback speed set to %@×\"",
    "ICLocalizedIntentDialog(\"Sleep timer set for %d minutes.\"",
    "ICLocalizedIntentDialog(\"Marked “%@” as played.\"",
    "ICLocalizedIntentDialog(\"Nothing is playing.\")",
    "ICLocalizedIntentDialog(\"Added to favorites.\")",
    "ICLocalizedIntentDialog(\"Removed from favorites.\")",
]:
    require(token in playback_intents, f"Playback intent dialog is not explicitly localized: {token}")

for token in [
    "ICLocalizedIntentDialog(\"Playing “%@”.\"",
    "ICLocalizedIntentDialog(\"No playable episode found.\")",
    "ICLocalizedIntentDialog(\"Episode not found.\")",
]:
    require(token in content_intents, f"Content intent dialog is not explicitly localized: {token}")

require("void ICLocalizeViewText(UIView* view);" in view_functions_h, "View localization helper is missing from ViewFunctions.h.")
require("void ICLocalizeViewText(UIView* view)" in view_functions_m, "View localization helper is missing from ViewFunctions.m.")
require("ICLocalizeViewText(migrationViewController.view);" in app_delegate, "AppDelegate must localize the migration XIB after loading it.")
require("ICLocalizeViewText(migrationViewController.view);" in scene_delegate, "SceneDelegate must localize the migration XIB after loading it.")

print("Localization coverage regression checks passed.")
