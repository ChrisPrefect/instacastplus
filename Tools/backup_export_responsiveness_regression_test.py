#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXPORTER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()
EN_STRINGS = (ROOT / "Resources" / "en.lproj" / "Localizable.strings").read_text()
DE_STRINGS = (ROOT / "Resources" / "de.lproj" / "Localizable.strings").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(signature: str) -> str:
    start = EXPORTER.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = EXPORTER.find("{", start)
    require(brace != -1, f"Missing method body: {signature}")
    depth = 0
    for index in range(brace, len(EXPORTER)):
        if EXPORTER[index] == "{":
            depth += 1
        elif EXPORTER[index] == "}":
            depth -= 1
            if depth == 0:
                return EXPORTER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require(
    "fullExportInProgress" in EXPORTER,
    "Full backup export needs persistent busy state to prevent duplicate starts and survive row reloads.",
)

cell_builder = method_body("- (UITableViewCell *)tableView:")
require(
    "fullExportInProgress" in cell_builder
    and "UIActivityIndicatorView" in cell_builder
    and '"Backup wird exportiert…".ls' in cell_builder,
    "The full-export row must visibly show an animated, localized busy state.",
)

orchestrator = method_body("- (void)_beginFullExportAfterBusyState")
require(
    "QOS_CLASS_USER_INITIATED" in orchestrator
    and "dispatch_get_global_queue" in orchestrator
    and "newExportBackgroundContext" in orchestrator,
    "Full backup work must leave the main queue and use the dedicated read-only export coordinator.",
)
require(
    "performBlock:" in orchestrator
    and "dispatch_get_main_queue" in orchestrator,
    "Core Data export work must run on its context queue and return to main only for UI completion.",
)
require(
    "cachedEpisodeHashesAtStoragePath:" in orchestrator
    and "fileCacheURL.path" in orchestrator,
    "Export must verify downloaded episodes against the real storage directory, even before CacheManager finishes indexing.",
)
database_error_key = (
    "The backup could not be exported because the local podcast database could not be opened. "
    "Check the available storage, restart InstacastPlus, and try again."
)
require(f'@"{database_error_key}".ls' in orchestrator,
        "A missing export context must show localized, actionable guidance instead of a raw English error.")
require(f'"{database_error_key}" = "{database_error_key}";' in EN_STRINGS,
        "English must localize the export database error.")
require(
    f'"{database_error_key}" = "Das Backup konnte nicht exportiert werden, weil die lokale Podcast-Datenbank nicht geöffnet werden konnte. '
    'Prüfe den freien Speicherplatz, starte InstacastPlus neu und versuche es erneut.";' in DE_STRINGS,
    "German must localize the export database error with recovery guidance.",
)

cache_snapshot = method_body("- (NSSet<NSString *> *)cachedEpisodeHashesAtStoragePath:")
require(
    "contentsOfDirectoryAtPath:" in cache_snapshot
    and "stringByDeletingPathExtension" in cache_snapshot
    and 'rangeOfString:@" - " options:NSBackwardsSearch' in cache_snapshot,
    "Downloaded-state snapshot must understand both current descriptive filenames and legacy hash filenames.",
)

builder = method_body("- (NSURL *)createEverythingBackupWithContext:")
for forbidden in [
    "DMANAGER.objectContext",
    "DMANAGER.bookmarks",
    "DMANAGER.lists",
    "episodeWithObjectHash:",
    "episodeIsCached:",
]:
    require(
        forbidden not in builder,
        f"Background backup builder must not cross back to main-context state: {forbidden}",
    )
require(
    "executeFetchRequest:" in builder
    and "cachedEpisodeHashes" in builder,
    "Background builder must fetch from its own context and use the immutable cached-episode snapshot.",
)
feed_fetch = builder.split("// Podcasts", 1)[1].split("NSArray* feeds", 1)[0]
require(
    "relationshipKeyPathsForPrefetching" in feed_fetch
    and '@"properties"' in feed_fetch,
    "The independent export context must prefetch feed properties once; otherwise each podcast "
    "fires a cold serial relationship query and makes the spinner-based background export much slower.",
)
require(
    "writeToURL:url options:NSDataWritingAtomic error:" in builder,
    "Backup file writes must be checked instead of opening a share sheet for a missing file.",
)

completion = method_body("- (void)presentPendingFullExportResultIfNeeded")
view_did_appear = method_body("- (void)viewDidAppear:")
require(
    "self.viewIfLoaded.window" in completion
    and "self.navigationController.topViewController != self" in completion
    and "self.presentedViewController" in completion
    and "presentPendingFullExportResultIfNeeded" in view_did_appear,
    "A finished export must wait until its settings screen is visible before presenting share or error UI.",
)

for strings, language in [(EN_STRINGS, "English"), (DE_STRINGS, "German")]:
    for key in [
        "Backup wird exportiert…",
        "Das Backup konnte nicht exportiert werden. Prüfe den freien Speicherplatz und versuche es erneut.",
    ]:
        require(f'"{key}" =' in strings, f"{language} localization is missing: {key}")


print("backup export responsiveness regression checks passed")
