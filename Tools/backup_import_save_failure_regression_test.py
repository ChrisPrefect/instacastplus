#!/usr/bin/env python3
"""Pins terminal Core Data save-error handling throughout backup import."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text(encoding="utf-8")
EPISODE_LOADING_MANAGER = (
    ROOT / "Classes" / "Model" / "EpisodeLoadingManager.m"
).read_text(encoding="utf-8")
LOCALIZATIONS = [
    (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text(encoding="utf-8"),
    (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text(encoding="utf-8"),
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


def ordered(source: str, *tokens: str) -> bool:
    position = -1
    for token in tokens:
        position = source.find(token, position + 1)
        if position < 0:
            return False
    return True


main_import = body(IMPORTER, "+ (void)importBackup:")
finalize = body(IMPORTER, "+ (void)_finalize:")
feed_settings = body(IMPORTER, "+ (NSInteger)importFeedSettingsFromBackup:")
watch = body(IMPORTER, "+ (NSInteger)importAppleWatchEpisodesFromBackup:")
playlists = body(IMPORTER, "+ (NSInteger)importPlaylistsFromBackup:")
episode_lists = body(IMPORTER, "+ (NSInteger)importEpisodeListsFromBackup:")
cancel_feed_loading = body(EPISODE_LOADING_MANAGER, "- (void)cancelLoadingForFeed:")

require("ICBackupImportPersistenceError" in IMPORTER,
        "Core Data save failures need one user-facing terminal backup-import error.")
require("ICBackupSaveMainContext" in IMPORTER and "[DMANAGER saveReturningError]" in IMPORTER,
        "All main-context backup phases need one error-returning save path.")

feed_metadata_start = main_import.find("// Apply backup metadata on main thread")
feed_metadata_end = main_import.find("[subscribedFeeds addObject:subscribedFeed]", feed_metadata_start)
require(feed_metadata_start >= 0 and feed_metadata_end >= 0, "Missing subscribed-feed metadata phase.")
feed_metadata = main_import[feed_metadata_start:feed_metadata_end]
require("ICBackupSaveMainContext" in feed_metadata and "terminalError" in feed_metadata,
        "Subscribed-feed metadata must turn its save failure into the terminal import error.")
require("if (terminalError)" in feed_metadata and "break;" in feed_metadata,
        "A feed metadata save failure must stop before the feed is counted or hydrated.")
require("cancelLoadingForFeed:subscribedFeed" in feed_metadata,
        "A feed metadata save failure must stop the feed hydration queued before the failed metadata save.")
cancel_save_failure = cancel_feed_loading[
    cancel_feed_loading.find("if (saveError)"):
    cancel_feed_loading.find("return;", cancel_feed_loading.find("if (saveError)"))
]
require("[self _cancelLoadingForFeedURL:feedURL]" not in cancel_save_failure,
        "A failed cancellation save must retain the only durable hydration job for explicit retry.")
require("previousLoadedCount" in cancel_save_failure and
        "previousTotalExpectedEpisodes" in cancel_save_failure and
        "previousLoadingComplete" in cancel_save_failure,
        "A failed cancellation save must restore the feed's prior in-memory loading state.")
require("if (!terminalError" in feed_metadata and "loadImageForURL" in feed_metadata,
        "Feed artwork preloading must not run after the metadata save failed.")

require("^NSInteger(NSError **error)" in main_import and "NSError *phaseError" in main_import,
        "Metadata phases need a uniform error-returning block contract for failure injection.")
require("terminalError = phaseError" in main_import,
        "The first failing metadata phase must become the terminal import error.")
metadata_loop = main_import[main_import.find("NSError *phaseError"):]
require(ordered(metadata_loop, "if (phaseError)", "terminalError = phaseError", "break;", "setMetadataCompleted"),
        "A failed phase must stop before positive completion/count UI is emitted.")
require("if (error && *error) return" in main_import,
        "Episode-list import must not run after playlist persistence failed.")

feed_settings_signature = "+ (NSInteger)importFeedSettingsFromBackup:(InstacastBackupData *)backup error:(NSError **)error"
require(feed_settings_signature in IMPORTER,
        "The feed settings phase must expose its background transaction failure.")
require("[context save:&saveError]" in feed_settings and
        "batchError = ICBackupImportPersistenceError(saveError)" in feed_settings,
        "The feed settings background transaction must preserve its exact save failure.")
require(ordered(feed_settings, "if (batchError)", "*error = batchError", "return 0;"),
        "Feed settings must stop and report a failed background batch before returning success.")

for name, signature, method in (
    ("Apple Watch", "+ (NSInteger)importAppleWatchEpisodesFromBackup:(InstacastBackupData *)backup error:(NSError **)error", watch),
    ("playlists", "+ (NSInteger)importPlaylistsFromBackup:(InstacastBackupData *)backup error:(NSError **)error", playlists),
    ("episode lists", "+ (NSInteger)importEpisodeListsFromBackup:(InstacastBackupData *)backup error:(NSError **)error", episode_lists),
):
    require(signature in IMPORTER,
            f"The {name} phase must expose its save failure to the phase runner.")
    require("ICBackupSaveMainContext" in method,
            f"The {name} phase still uses a save path that cannot report failure.")
    require("if (saveError)" in method and "*error = saveError" in method,
            f"The {name} phase must return its save error instead of a positive success count.")

require(ordered(watch, "ICBackupSaveMainContext", "if (saveError)", "syncCurrentSelectionsNow"),
        "Watch selection sync must only start after its Core Data state is durable.")
require("[DMANAGER addList:" not in playlists and "[DMANAGER addList:" not in episode_lists,
        "List phases must not call addList:, whose internal void save can hide an injected failure.")
require("[CDList updateRanksOfLists:DMANAGER.lists]" in playlists
        and "[CDList updateRanksOfLists:DMANAGER.lists]" in episode_lists,
        "List phases must retain addList:'s rank update before their single error-returning phase save.")

require("NSError *finalError = terminalError" in finalize,
        "Finalization must preserve the first terminal error.")
require(ordered(finalize, "NSError *finalError = terminalError", "if (!finalError)", "ICBackupSaveMainContext"),
        "Finalization must only perform its final save when no earlier phase already failed.")
require("BOOL completedSuccessfully = !wasCancelled && !finalError" in finalize,
        "Successful side effects must require a confirmed final save.")
require("processPendingNowPlaying" not in main_import and "processPendingDownloads" not in main_import,
        "Pending playback/download side effects must not run before the final save result is known.")
require(ordered(finalize, "if (completedSuccessfully)", "processPendingNowPlaying", "processPendingDownloads"),
        "Pending playback/download work must be gated by successful final persistence.")
require("completion(totalImported, queuedDownloadCount, finalError)" in finalize,
        "The public completion must receive final-save failures.")

save_error_key = (
    '"The imported data could not be saved. The import was stopped and may have been applied only partially. '
    'Check the available storage and try again." ='
)
for localization in LOCALIZATIONS:
    require(save_error_key in localization,
            "The terminal backup save error must be localized in German and English.")

print("Backup import save-failure regression checks passed")
