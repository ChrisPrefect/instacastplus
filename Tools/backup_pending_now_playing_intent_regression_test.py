#!/usr/bin/env python3
"""Runtime/source proof that late backup Now Playing cannot override newer playback intent."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text(encoding="utf-8")
AUDIO = (ROOT / "Classes" / "AudioSession.m").read_text(encoding="utf-8")
AUDIO_HEADER = (ROOT / "Classes" / "AudioSession.h").read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def function_source(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"Missing function: {signature}")
    brace = source.find("{", start)
    require(brace >= 0, f"Missing function body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"Unterminated function: {signature}")


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


record_function = function_source(
    IMPORTER,
    "static NSDictionary *ICBackupPendingNowPlayingRecord",
)
matches_function = function_source(
    IMPORTER,
    "static BOOL ICBackupPendingNowPlayingMatchesPlaybackIntent",
)


def compile_probe(directory: Path) -> Path:
    harness = directory / "pending_now_playing_probe.m"
    harness.write_text(
        f'''#import <Foundation/Foundation.h>
#import <stdint.h>

{record_function}

{matches_function}

int main(void) {{
    @autoreleasepool {{
        uint64_t stagedRevision = 7;
        NSDictionary *pendingA = ICBackupPendingNowPlayingRecord(
            @"episode-a", @"https://example.test/a.xml", 123.5, stagedRevision
        );
        if (!ICBackupPendingNowPlayingMatchesPlaybackIntent(pendingA, stagedRevision)) return 64;

        // The user deliberately selects B after backup A was staged.
        uint64_t revisionAfterUserB = stagedRevision + 1;
        BOOL lateAWouldApply = ICBackupPendingNowPlayingMatchesPlaybackIntent(
            pendingA, revisionAfterUserB
        );
        if (lateAWouldApply) return 65;

        // Pre-revision pending dictionaries are ambiguous after an app update and
        // must never overwrite the playback state restored from the newer app run.
        NSDictionary *legacyPendingA = @{{
            @"guid": @"episode-a",
            @"feedURL": @"https://example.test/a.xml",
            @"position": @123.5,
        }};
        if (ICBackupPendingNowPlayingMatchesPlaybackIntent(legacyPendingA, 0)) return 66;
    }}
    return 0;
}}
''',
        encoding="utf-8",
    )
    clang = subprocess.run(
        ["xcrun", "--find", "clang"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    binary = directory / "pending_now_playing_probe"
    result = subprocess.run(
        [clang, "-fobjc-arc", str(harness), "-framework", "Foundation", "-o", str(binary)],
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0,
            "Could not compile pending Now Playing intent probe:\n" + result.stderr)
    return binary


with tempfile.TemporaryDirectory(prefix="instacast-pending-now-playing-") as temporary_directory:
    probe = compile_probe(Path(temporary_directory))
    result = subprocess.run([str(probe)], capture_output=True, text=True)
    require(result.returncode == 0,
            "Late backup A still overrides newer user-selected B or accepts ambiguous legacy state.")

require("+ (uint64_t)playbackIntentRevision" in AUDIO_HEADER
        and "restorePlaybackEpisode:" in AUDIO_HEADER,
        "AudioSession must expose a durable revision read and an explicit non-intent restore path.")

revision_getter = method_body(AUDIO, "+ (uint64_t)playbackIntentRevision")
record_intent = method_body(AUDIO, "- (void)_recordPlaybackIntent")
require("USER_DEFAULTS" in revision_getter and "PlaybackIntentRevision" in AUDIO,
        "Playback intent revision must survive app termination in UserDefaults.")
require("setObject:@(nextRevision)" in record_intent,
        "Each normal playback intent must durably advance the revision.")

normal_play = method_body(
    AUDIO,
    "- (void) playEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent "
    "at:(NSTimeInterval)time autostart:(BOOL)autostart",
)
restore_play = method_body(
    AUDIO,
    "- (void) restorePlaybackEpisode:(CDEpisode*)anEpisode queueUpCurrent:(BOOL)queueUpCurrent "
    "at:(NSTimeInterval)time autostart:(BOOL)autostart",
)
require("recordsPlaybackIntent:YES" in normal_play,
        "Normal explicit playback must advance the durable intent revision exactly in the shared core.")
require("recordsPlaybackIntent:NO" in restore_play and "_recordPlaybackIntent" not in restore_play,
        "Automatic backup restore must not masquerade as a newer user intent.")
play_core = method_body(AUDIO, "- (void) _playEpisode:(CDEpisode*)anEpisode")
require(play_core.find("_recordPlaybackIntent") < play_core.find("playbackURL.absoluteString.length == 0"),
        "An explicit selection with invalid media must still invalidate older pending playback.")

clear = method_body(AUDIO, "- (void) clear")
stop = method_body(AUDIO, "- (void) stop")
require("_recordPlaybackIntent" in clear,
        "Clearing an existing episode must invalidate an older pending backup selection.")
require("playbackIntentRevision" in stop and "_recordPlaybackIntent" in stop,
        "An explicit stop must invalidate pending backup playback even when no episode is loaded.")

import_now_playing = method_body(IMPORTER, "+ (NSInteger)importNowPlayingFromBackup:")
processor = method_body(IMPORTER, "+ (void)_processPendingDeferredRestoreForFeedURLs:")
require(import_now_playing.count("ICBackupPendingNowPlayingRecord") == 2,
        "Both unresolved-episode and unresolved-media staging must capture the same revision baseline.")
require("restorePlaybackEpisode:" in import_now_playing
        and "playEpisode:episode queueUpCurrent:NO" not in import_now_playing,
        "Immediately available backup Now Playing must use the non-intent restore path.")
apply_block = processor[processor.rfind("if (shouldProcessNowPlaying)"):]
current_index = apply_block.find("currentPending")
match_index = apply_block.find("ICBackupPendingNowPlayingMatchesPlaybackIntent")
apply_index = apply_block.find("restorePlaybackEpisode:")
require(0 <= current_index < match_index < apply_index,
        "Deferred backup A must atomically validate both the captured record and revision on main before applying playback or position.")
require("removeObjectForKey:kPendingNowPlayingKey" in apply_block[match_index:apply_index],
        "A stale pending backup selection must discard only its still-current record before it can apply.")

print("Backup pending Now Playing intent regression checks passed")
