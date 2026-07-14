#!/usr/bin/env python3
"""Pins the additive episode-state semantics promised by backup Merge."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text()
PREVIEW = (ROOT / "Classes" / "InstacastBackupImportViewController.m").read_text()
EXPORTER = (ROOT / "Classes" / "ImportExportSettingsViewController.m").read_text()


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


episode_import = method_body(IMPORTER, "+ (NSInteger)_importEpisodeStatusForPodcastAtIndex:")
require("backupEp.played && !episode.consumed" in episode_import,
        "Merge may add Played, but an older backup must never mark a locally played episode unplayed.")
require("backupEp.starred && !episode.starred" in episode_import,
        "Merge may add Starred, but an older backup must never remove a local star.")
require("backupEp.archived && !episode.archived" in episode_import,
        "Merge may add Archived, but must not reverse current local state.")
require("backupEp.position > episode.position" in episode_import,
        "Merge must retain the furthest playback position from backup or device.")
require("episode.consumed = NO" not in episode_import,
        "Episodes omitted by the sparse backup are unspecified and must remain unchanged.")
require("episode.consumed = NO" not in episode_import and
        "episode.starred = backupEp.starred" not in episode_import and
        "episode.consumed = shouldBeConsumed" not in episode_import,
        "The merge implementation must contain no destructive state assignment.")
require("save:&saveError" in episode_import and "count = 0" in episode_import,
        "A failed background-context save must not be counted as a successful merge.")

require("Existing data will be merged" in PREVIEW,
        "The UI explicitly promises merge semantics; the importer test must match that contract.")
require("episode.consumed || episode.starred || episode.archived || episode.position > 0 || isCached" in EXPORTER,
        "Episode backup is intentionally sparse, so absence can never mean a false state.")

print("Backup episode merge regression checks passed")
