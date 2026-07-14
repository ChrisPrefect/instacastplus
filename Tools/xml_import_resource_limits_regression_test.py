#!/usr/bin/env python3
"""Pins bounded XML reads and parser budgets for backup and OPML imports."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LIMITS_H = (ROOT / "Classes" / "InstacastBackupParser.h").read_text()
LIMITS_M = (ROOT / "Classes" / "InstacastBackupParser.m").read_text()
OPML = (ROOT / "Classes" / "OPML.m").read_text()
MAIN = (ROOT / "Classes" / "MainViewController_4.m").read_text()
SETTINGS = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
APP = (ROOT / "Classes" / "InstacastAppDelegate.m").read_text()
SCENE = (ROOT / "Classes" / "InstacastSceneDelegate.m").read_text()
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(),
]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("ICXMLImportLimits" in LIMITS_H and "readDataFromURL:" in LIMITS_H
        and "validateData:" in LIMITS_H,
        "Backup and OPML callers need one shared bounded XML data API.")
require("16 * 1024 * 1024" in LIMITS_M,
        "XML imports need a documented 16 MiB ceiling that comfortably exceeds real backups.")
require("4500" in LIMITS_M and "1.1" in LIMITS_M,
        "The import ceiling rationale must remain tied to the measured large-library backup.")

bounded_read = body(LIMITS_M, "+ (NSData *)readDataFromURL:")
require("NSURLFileSizeKey" in bounded_read,
        "External XML size must be checked before allocating its payload when metadata is available.")
require("NSFileHandle" in bounded_read and "readDataUpToLength" in bounded_read,
        "The authoritative read must itself stop at the limit instead of loading an arbitrary file first.")
require("startAccessingSecurityScopedResource" in bounded_read
        and "stopAccessingSecurityScopedResource" in bounded_read,
        "The shared bounded reader must balance security-scoped file access on every exit.")
require("ICXMLImportMaximumDataLength + 1" in bounded_read,
        "The reader must distinguish an exactly-at-limit file from an oversized one without reading it all.")

for source, signature in (
    (MAIN, "- (void)openBackupFileURL:"),
    (SETTINGS, "- (void)importFileFromURL:"),
):
    import_body = body(source, signature)
    require("[ICXMLImportLimits readDataFromURL:url error:&readError]" in import_body,
            f"{signature} must use the shared bounded reader.")
    require("dataWithContentsOfURL" not in import_body,
            f"{signature} must not allocate an unbounded external XML file.")

for source, signature in (
    (APP, "- (BOOL)application:(UIApplication *)app openURL:"),
    (SCENE, "- (void)scene:(UIScene *)scene openURLContexts:"),
):
    route_body = body(source, signature)
    require("[ICXMLImportLimits readDataFromURL:url error:&readError]" in route_body,
            f"{signature} must apply the same bound to external OPML files.")

backup_parse = body(LIMITS_M, "+ (void)parseData:")
opml_parse = body(OPML, "- (void) parseWithCompletionHandler:")
require("validateData:data error:&validationError" in backup_parse,
        "Backup parsing must revalidate in-memory data so callers cannot bypass the file reader.")
require("validateData:data error:&validationError" in opml_parse,
        "OPML parsing must revalidate in-memory data so callers cannot bypass the file reader.")

for source, parser_name in ((LIMITS_M, "backup"), (OPML, "OPML")):
    require("ICXMLImportParserBudget" in source,
            f"The {parser_name} parser must use the shared element/object/depth/text budget.")
    require("consumeElement" in source and "consumeCharacters" in source and "consumeObject" in source,
            f"The {parser_name} parser does not enforce every parser resource dimension.")
    require("shouldResolveExternalEntities = NO" in source,
            f"The {parser_name} parser must never resolve external XML entities.")
    require("resolveExternalEntityName" in source and "return nil" in source,
            f"The {parser_name} parser delegate must explicitly refuse external entity data.")

for token in ("64", "16 * 1024 * 1024"):
    require(token in LIMITS_M, f"Missing shared XML parser limit: {token}")
require("ICXMLImportMaximumDataLength / ICXMLImportMinimumSerializedBytesPerElement" in LIMITS_M,
        "The element budget must scale from the bounded serialized input instead of an arbitrary count.")
require("ICXMLImportMaximumDataLength / ICXMLImportMinimumSerializedBytesPerSemanticObject" in LIMITS_M,
        "The semantic-object budget must scale from the bounded serialized input instead of an arbitrary count.")
require("abortParsing" in LIMITS_M,
        "Crossing a parser budget must abort before any partial result can be imported.")

for localization in LOCALIZATIONS:
    require('"The selected XML file is too large to import. InstacastPlus supports files up to 16 MB." =' in localization,
            "The oversized-file error must be localized in German and English.")
    require('"The selected XML file is too complex to import safely." =' in localization,
            "The parser-budget error must be localized in German and English.")

print("XML import resource-limit regression checks passed")
