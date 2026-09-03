#!/usr/bin/env python3
import ast
import json
import plistlib
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
    for language, table in (("English", en_strings), ("German", de_strings)):
        empty = sorted(key for key, value in table.items() if not value.strip())
        require(not empty, f"{name} {language} localization has empty values: {empty}")


def lookup_key(literal: str) -> str:
    """Mirrors -[NSBundle preflightTokenOfLocalizationKey:], used by `.ls`.

    `.ls` removes a trailing "…" or ":" before looking the key up and appends it
    again afterwards. An entry stored *with* that character is therefore never
    found, and the untranslated source literal leaks into the UI.
    """
    for token in ("…", ":"):
        if literal.endswith(token):
            return literal[:-len(token)]
    return literal


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
    ("property_title", re.compile(r'@Property\s*\(\s*title:\s*"((?:[^"\\]|\\.)*)"')),
    ("summary", re.compile(r'\bSummary\s*\(\s*"((?:[^"\\]|\\.)*)"')),
    ("shortcut_title", re.compile(r'shortTitle:\s*"((?:[^"\\]|\\.)*)"')),
    ("display_representation", re.compile(r'DisplayRepresentation\s*\(\s*title:\s*"((?:[^"\\]|\\.)*)"')),
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
    # A literal that is nothing but a Swift interpolation carries a runtime value,
    # not a translatable text (e.g. DisplayRepresentation(title: "\(name)")).
    if not re.sub(r"\\\([^)]*\)", "", literal).strip():
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
        if {"AppIntents", "Intents"} & set(path.parts) or path.name == "ICAppShortcuts.swift":
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
                key = lookup_key(literal) if pattern_name == "objc_ls" else literal
                if key not in localized_keys:
                    line = source.count("\n", 0, match.start()) + 1
                    missing.append(f"{path.relative_to(ROOT)}:{line}: {key}")

    require(not missing, "Missing localization keys:\n" + "\n".join(missing[:80]))


# A .strings table resolves duplicate keys by keeping the LAST occurrence (verified
# against Foundation, not just plutil). Earlier lines are silently dead and hid
# diverging translations, e.g. German "Off" existed as both "Deaktivieren" and "Aus".
STRINGS_FILES = [
    "Resources/en.lproj/Localizable.strings",
    "Resources/de.lproj/Localizable.strings",
    "Resources/en.lproj/AppShortcuts.strings",
    "Resources/de.lproj/AppShortcuts.strings",
    "Resources/en.lproj/InfoPlist.strings",
    "Resources/de.lproj/InfoPlist.strings",
    "Resources-iPhone/en.lproj/MediaSuggestions.strings",
    "Resources-iPhone/de.lproj/MediaSuggestions.strings",
    "InstacastWatch/en.lproj/Localizable.strings",
    "InstacastWatch/de.lproj/Localizable.strings",
    "InstacastWidgets/Resources/en.lproj/Localizable.strings",
    "InstacastWidgets/Resources/de.lproj/Localizable.strings",
    "InstacastWatchWidgets/en.lproj/Localizable.strings",
    "InstacastWatchWidgets/de.lproj/Localizable.strings",
]

KEY_LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=')
for relative in STRINGS_FILES:
    seen: dict[str, int] = {}
    duplicates = []
    for number, line in enumerate(read(relative).splitlines(), 1):
        match = KEY_LINE.match(line)
        if not match:
            continue
        key = match.group(1)
        if key in seen:
            duplicates.append(f"{key!r} (lines {seen[key]} and {number})")
        seen[key] = number
    require(not duplicates, f"{relative} defines the same key twice: {duplicates}")


# Keys ending in "…" or ":" are only reachable through an exact NSLocalizedString
# lookup — `.ls` strips the token first. Anything else is a dead entry whose source
# literal leaks into the UI untranslated.
EXACT_LOOKUP = re.compile(r'NSLocalizedString\s*\(\s*@?"((?:[^"\\]|\\.)*)"')
SWIFT_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
exact_keys = set()
for directory in ("Classes", "VemedioKit", "VemedioDatabase", "InstacastWatch", "InstacastWidgets"):
    base = ROOT / directory
    if not base.exists():
        continue
    for path in base.rglob("*"):
        if path.suffix not in {".m", ".mm", ".h", ".swift"} or "build" in path.parts:
            continue
        source = path.read_text(errors="ignore")
        for match in EXACT_LOOKUP.finditer(source):
            exact_keys.add(unescape_literal(match.group(1)))
        if path.suffix == ".swift":
            # SwiftUI (Text, Label, ProgressView, …) localizes a literal with the
            # literal itself as the key — no token stripping, unlike ObjC `.ls`.
            for match in SWIFT_LITERAL.finditer(source):
                exact_keys.add(unescape_literal(match.group(1)))

for name, table in [("app", APP_EN), ("watch", WATCH_EN), ("widgets", WIDGET_EN)]:
    unreachable = sorted(
        key for key in table
        if (key.endswith("…") or key.endswith(":")) and key not in exact_keys
    )
    require(
        not unreachable,
        f"{name}: keys ending in an ellipsis/colon are never found by `.ls` — "
        f"store them without that character: {unreachable}",
    )


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


# App Shortcut phrases are localized through AppShortcuts.strings with ${token}
# placeholders — Localizable.strings entries carrying the Swift interpolation
# ("\(.applicationName)") never match, which left the German Siri phrases English
# (proven via Metadata.appintents/root.ssu.yaml, which listed the English
# utterances under "locale: de").
APP_SHORTCUTS_EN = strings_dict("Resources/en.lproj/AppShortcuts.strings")
APP_SHORTCUTS_DE = strings_dict("Resources/de.lproj/AppShortcuts.strings")

shortcuts_source = read("Classes/AppIntents/ICAppShortcuts.swift")
expected_phrases = set()
for block in re.finditer(r"phrases:\s*\[(.*?)\]", shortcuts_source, re.S):
    for literal in re.finditer(r'"((?:[^"\\]|\\.)*)"', block.group(1)):
        phrase = re.sub(r"\\\(\\\.\$(\w+)\)", r"${\1}", literal.group(1))
        phrase = re.sub(r"\\\(\.(\w+)\)", r"${\1}", phrase)
        expected_phrases.add(phrase)

require(expected_phrases, "No App Shortcut phrases found in ICAppShortcuts.swift.")
for phrase in sorted(expected_phrases):
    require("${applicationName}" in phrase, f"App Shortcut phrase without app name: {phrase}")

for language, table in [("English", APP_SHORTCUTS_EN), ("German", APP_SHORTCUTS_DE)]:
    missing_phrases = sorted(expected_phrases - set(table))
    require(not missing_phrases, f"{language} AppShortcuts.strings misses phrases: {missing_phrases}")
    for key, value in table.items():
        require("${applicationName}" in value,
                f"{language} Siri phrase without app name: {key} -> {value}")

untranslated_phrases = sorted(
    phrase for phrase in expected_phrases if APP_SHORTCUTS_DE[phrase] == APP_SHORTCUTS_EN[phrase]
)
require(not untranslated_phrases, f"German Siri phrases are still English: {untranslated_phrases}")

for language, table in [("English", APP_EN), ("German", APP_DE)]:
    dead_phrase_keys = sorted(key for key in table if ".applicationName" in key)
    require(not dead_phrase_keys,
            f"{language} Localizable.strings still carries dead Siri phrase keys: {dead_phrase_keys}")


# Permission prompts come from Info.plist and need InfoPlist.strings per language.
INFO_PLIST = plistlib.loads((ROOT / "Resources-iPhone" / "Instacast-Info.plist").read_bytes())
INFO_EN = strings_dict("Resources/en.lproj/InfoPlist.strings")
INFO_DE = strings_dict("Resources/de.lproj/InfoPlist.strings")

usage_keys = sorted(key for key in INFO_PLIST if key.endswith("UsageDescription"))
require(usage_keys, "Info.plist has no usage descriptions to check.")
for language, table in [("English", INFO_EN), ("German", INFO_DE)]:
    missing_usage = sorted(key for key in usage_keys if key not in table)
    require(not missing_usage, f"{language} InfoPlist.strings misses: {missing_usage}")
for key in usage_keys:
    require(INFO_DE[key] != INFO_EN[key],
            f"German InfoPlist text for {key} is identical to the English one.")


print("Localization coverage regression checks passed.")
