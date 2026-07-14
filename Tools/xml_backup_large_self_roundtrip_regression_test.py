#!/usr/bin/env python3
"""Runtime regression proof for large, app-generated XML backups."""

from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PARSER = ROOT / "Classes" / "InstacastBackupParser.m"
BACKUP_DATA = ROOT / "Classes" / "InstacastBackupData.m"
EXPORTER = ROOT / "Classes" / "ImportExportSettingsViewController.m"
LOCALIZATION_HEADER = ROOT / "VemedioKit" / "Foundation+Localization.h"
MAXIMUM_BACKUP_BYTES = 16 * 1024 * 1024
LARGE_EPISODE_COUNT = 25_001

PARSER_SOURCE = PARSER.read_text(encoding="utf-8")
EXPORTER_SOURCE = EXPORTER.read_text(encoding="utf-8")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def exporter_episode(index: int) -> bytes:
    return (
        f'        <episode media="https://cdn.example.test/audio/{index}.mp3" '
        f'guid="episode-{index}">\n'
        "          <played>true</played>\n"
        "        </episode>\n"
    ).encode("utf-8")


BACKUP_PREFIX = (
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<instacast version="1" date="2026-07-13T12:00:00+0000">\n'
    "  <podcasts>\n"
    '    <podcast url="https://example.test/feed.xml" rank="0" title="Large Feed">\n'
    "      <episodes>\n"
).encode("utf-8")

BACKUP_SUFFIX = (
    "      </episodes>\n"
    "    </podcast>\n"
    "  </podcasts>\n"
    "</instacast>\n"
).encode("utf-8")


def make_backup(episode_count: int) -> bytes:
    parts = [BACKUP_PREFIX]
    parts.extend(exporter_episode(index) for index in range(episode_count))
    parts.append(BACKUP_SUFFIX)
    return b"".join(parts)


def make_near_limit_backup() -> tuple[bytes, int]:
    parts = [BACKUP_PREFIX]
    length = len(BACKUP_PREFIX) + len(BACKUP_SUFFIX)
    episode_count = 0
    while True:
        episode = exporter_episode(episode_count)
        if length + len(episode) > MAXIMUM_BACKUP_BYTES:
            break
        parts.append(episode)
        length += len(episode)
        episode_count += 1
    parts.append(BACKUP_SUFFIX)
    return b"".join(parts), episode_count


def compile_parser_probe(directory: Path) -> Path:
    harness = directory / "parser_probe.m"
    harness.write_text(
        r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "InstacastBackupParser.h"
#import "InstacastBackupData.h"

@implementation NSString (Localization)
- (NSString *)ls { return self; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 64;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSUInteger expectedEpisodeCount = (NSUInteger)strtoull(argv[2], NULL, 10);
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return 65;

        [InstacastBackupParser parseData:data completion:^(InstacastBackupData *backup, NSError *error) {
            if (error) {
                fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
                fflush(stderr);
                exit(66);
            }
            ICBackupPodcast *podcast = backup.podcasts.firstObject;
            if (backup.podcasts.count != 1 || podcast.episodes.count != expectedEpisodeCount) {
                fprintf(stderr, "parsed podcasts=%lu episodes=%lu, expected episodes=%lu\n",
                        (unsigned long)backup.podcasts.count,
                        (unsigned long)podcast.episodes.count,
                        (unsigned long)expectedEpisodeCount);
                fflush(stderr);
                exit(67);
            }
            exit(0);
        }];
        dispatch_main();
    }
}
''',
        encoding="utf-8",
    )

    binary = directory / "parser_probe"
    clang = subprocess.run(
        ["xcrun", "--find", "clang"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    compile_result = subprocess.run(
        [
            clang,
            "-fobjc-arc",
            "-fblocks",
            "-Wno-deprecated-declarations",
            "-include",
            str(LOCALIZATION_HEADER),
            "-I",
            str(ROOT / "Classes"),
            str(PARSER),
            str(BACKUP_DATA),
            str(harness),
            "-framework",
            "Foundation",
            "-o",
            str(binary),
        ],
        capture_output=True,
        text=True,
    )
    require(
        compile_result.returncode == 0,
        "Could not compile the real backup parser probe:\n" + compile_result.stderr,
    )
    return binary


def run_parser_probe(binary: Path, directory: Path, name: str, data: bytes, episode_count: int) -> None:
    path = directory / name
    path.write_bytes(data)
    result = subprocess.run(
        [str(binary), str(path), str(episode_count)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    require(
        result.returncode == 0,
        f"The real parser rejected its own {len(data) / (1024 * 1024):.2f}-MiB export "
        f"with {episode_count} status episodes: {result.stderr.strip()}",
    )


require(
    '[xml appendFormat:@"        <episode media=\\"%@\\" guid=\\"%@\\">\\n",' in EXPORTER_SOURCE
    and '[xml appendString:@"          <played>true</played>\\n"]' in EXPORTER_SOURCE,
    "The runtime fixture must stay aligned with the app's status-episode exporter format.",
)

large_backup = make_backup(LARGE_EPISODE_COUNT)
require(len(large_backup) < MAXIMUM_BACKUP_BYTES,
        "The >25k regression fixture must remain within the supported 16-MiB file size.")

near_limit_backup, near_limit_episode_count = make_near_limit_backup()
require(len(near_limit_backup) <= MAXIMUM_BACKUP_BYTES,
        "The near-limit self-roundtrip fixture crossed the 16-MiB contract.")
require(MAXIMUM_BACKUP_BYTES - len(near_limit_backup) < len(exporter_episode(near_limit_episode_count)),
        "The self-roundtrip fixture is not the largest app-format backup below 16 MiB.")

with tempfile.TemporaryDirectory(prefix="instacast-backup-parser-") as temporary_directory:
    directory = Path(temporary_directory)
    probe = compile_parser_probe(directory)
    run_parser_probe(probe, directory, "large.xml", large_backup, LARGE_EPISODE_COUNT)
    run_parser_probe(
        probe,
        directory,
        "near-limit.xml",
        near_limit_backup,
        near_limit_episode_count,
    )

element_ratio = re.search(
    r"ICXMLImportMaximumElementCount\s*=\s*ICXMLImportMaximumDataLength\s*/\s*"
    r"ICXMLImportMinimumSerializedBytesPerElement",
    PARSER_SOURCE,
)
object_ratio = re.search(
    r"ICXMLImportMaximumObjectCount\s*=\s*ICXMLImportMaximumDataLength\s*/\s*"
    r"ICXMLImportMinimumSerializedBytesPerSemanticObject",
    PARSER_SOURCE,
)
require(element_ratio is not None and object_ratio is not None,
        "Parser structure budgets must be derived from the bounded serialized input, not arbitrary counts.")
require("static const NSUInteger ICXMLImportMinimumSerializedBytesPerElement = 8;" in PARSER_SOURCE,
        "The element budget needs the documented conservative eight-byte serialization floor.")
require("static const NSUInteger ICXMLImportMinimumSerializedBytesPerSemanticObject = 32;" in PARSER_SOURCE,
        "The semantic-object budget needs the documented conservative 32-byte serialization floor.")

print(
    "Large XML backup self-roundtrip regression checks passed "
    f"({LARGE_EPISODE_COUNT} and {near_limit_episode_count} episodes)"
)
