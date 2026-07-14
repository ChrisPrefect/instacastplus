#!/usr/bin/env python3
"""Pins truthful backup-import counts and UI for deferred episode downloads."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text(encoding="utf-8")
IMPORTER_HEADER = (ROOT / "Classes" / "InstacastBackupImporter.h").read_text(encoding="utf-8")
PROGRESS = (ROOT / "Classes" / "ICBackupImportProgressView.m").read_text(encoding="utf-8")
PROGRESS_HEADER = (ROOT / "Classes" / "ICBackupImportProgressView.h").read_text(encoding="utf-8")
CONTROLLER = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text(encoding="utf-8")
ENGLISH = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(encoding="utf-8")
GERMAN = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start >= 0, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace >= 0, f"Missing method body: {signature}")
        if source.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("setMetadataQueued" in IMPORTER_HEADER,
        "Deferred downloads need a progress callback distinct from completed/imported metadata.")
require("queuedDownloadCount" in IMPORTER_HEADER.split("completion:", 1)[1],
        "Import completion must report queued downloads separately from imported items.")

download_import = method_body(IMPORTER, "+ (NSInteger)importDownloadsFromBackup:")
require("queuedCount:" in IMPORTER[IMPORTER.find("+ (NSInteger)importDownloadsFromBackup:"):
                                    IMPORTER.find("+ (NSInteger)importDownloadsFromBackup:") + 240],
        "Download staging must return its durable queued count through a separate out parameter.")
require("*queuedCount = count" in download_import and "return count;" not in download_import,
        "Persisted download GUIDs must not be returned as actually imported items.")
require("ICBackupCanonicalPendingDownloads" in download_import
        and "ICBackupMergePendingDownloads" in download_import
        and download_import.find("ICBackupMergePendingDownloads") < download_import.find("ICBackupAppendPendingDownloads")
        and "count++" not in download_import,
        "Queued-download counts must come from the same canonical feed/GUID set written to the durable stage.")

import_flow = method_body(IMPORTER, "+ (void)importBackup:")
require("__block NSInteger queuedDownloadCount = 0" in import_flow,
        "The import operation must carry a separate queued-download count through finalization.")
require("setMetadataQueued" in import_flow and "ICBackupImportDownloads" in import_flow,
        "A successfully persisted download stage must use the queued row state.")
require("completion(totalImported, queuedDownloadCount" in IMPORTER,
        "Completion must not fold queued downloads back into totalImported.")

queued_row = method_body(PROGRESS, "- (void)setQueuedWithDetail:")
require("systemOrangeColor" in queued_row and "systemGreenColor" not in queued_row
        and "checkmark.circle" not in queued_row,
        "Queued downloads must use a pending/orange status, never the green completed checkmark.")
require("setMetadataCategoryQueued:" in PROGRESS_HEADER
        and "setMetadataCategoryQueued:" in PROGRESS,
        "The existing metadata row must expose the queued state to the import controller.")

perform_import = method_body(CONTROLLER, "- (void)performImport")
require("queuedDownloadCount" in perform_import
        and "setMetadataCategoryQueued:" in perform_import,
        "The controller must display the separate queued count instead of a completed download row.")
require("downloadsQueued:" in perform_import,
        "The completion title must distinguish imports whose downloads continue afterward.")
require("queuedDownloadCount > 0" in perform_import and "queuedDownloadsSummary" in perform_import,
        "Imports without queued downloads must keep their existing completion message unchanged.")

analysis = method_body(CONTROLLER, "+ (ICBackupAnalysisResult *)analysisResultForBackup:")
require("podcast.feedURL && backupEpisode.downloaded && backupEpisode.guid.length > 0" in analysis,
        "Preview and queued completion counts must use the same stageable downloaded-episode contract.")
require("downloadEpisodeKeys" in analysis
        and "ICBackupEpisodeLookupKey" in analysis
        and "addObject:downloadKey" in analysis,
        "Preview must count each canonical feed/GUID download identity only once.")


def unique_download_count(rows):
    return len({(feed_url, guid) for feed_url, guid in rows if feed_url and guid})


require(unique_download_count([("feed", "episode"), ("feed", "episode")]) == 1,
        "Duplicate downloaded XML episode rows must preview and queue as one durable request.")

plural_key = "%ld downloads queued for re-download. Track progress in Downloads."
singular_key = "1 download queued for re-download. Track progress in Downloads."
for localization, language in ((ENGLISH, "English"), (GERMAN, "German")):
    require(f'"{plural_key}" = ' in localization and f'"{singular_key}" = ' in localization,
            f"{language} must fully localize singular and plural deferred-download guidance.")
require(f'"{singular_key}" = "{singular_key}";' in ENGLISH
        and f'"{plural_key}" = "{plural_key}";' in ENGLISH,
        "English guidance must explicitly describe re-download rather than an ambiguous transfer.")
require(
    f'"{singular_key}" = "1 Download zum erneuten Herunterladen vorgemerkt. Den Fortschritt siehst du unter „Downloads“.";' in GERMAN
    and f'"{plural_key}" = "%ld Downloads zum erneuten Herunterladen vorgemerkt. Den Fortschritt siehst du unter „Downloads“.";' in GERMAN,
    "German guidance must explicitly describe re-downloading and where its progress remains visible.",
)
require('"%ld queued" = "%ld vorgemerkt";' in GERMAN
        and '"%ld queued" = "%ld queued";' in ENGLISH,
        "The queued row detail must be localized in German and English.")
require('"Downloads queued" = "Downloads vorgemerkt";' in GERMAN
        and '"Downloads queued" = "Downloads queued";' in ENGLISH,
        "The conditional completion title must not claim that deferred downloads are complete.")

print("Backup deferred-download UI/count regression checks passed")
