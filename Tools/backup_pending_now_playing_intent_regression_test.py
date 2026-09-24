#!/usr/bin/env python3
"""Runtime proof that late backup Now Playing cannot override newer playback intent."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = (ROOT / "Classes" / "InstacastBackupImporter.m").read_text(encoding="utf-8")


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

print("Backup pending Now Playing intent regression checks passed")
