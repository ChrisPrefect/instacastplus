#!/usr/bin/env python3
"""Runtime proof that bounded deferred-download retries cannot starve entry 41."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
IMPORTER = ROOT / "Classes" / "InstacastBackupImporter.m"
SOURCE = IMPORTER.read_text(encoding="utf-8")


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


processor_start = SOURCE.find("+ (void)_processPendingDeferredRestoreForFeedURLs:")
processor_end = SOURCE.find("+ (void)processPendingNowPlaying", processor_start)
require(processor_start >= 0 and processor_end > processor_start,
        "Missing deferred-download processor.")
processor = SOURCE[processor_start:processor_end]

require("const NSUInteger deferredMainBatchSize = 20;" in processor
        and "const NSUInteger deferredMainInspectionLimit = deferredMainBatchSize * 2;" in processor,
        "Deferred restore must retain the 20-start/40-inspection bounds.")
require("inspectedDownloadKeys" in processor,
        "Every bounded main-thread candidate must be tracked for fair retry ordering.")
require("ICBackupRemainingDownloadsWithFairInspectionOrder" in processor,
        "The durable stage must move inspected unresolved work behind unseen work.")

pending_key_function = function_source(
    SOURCE,
    "static NSString *ICBackupPendingDownloadKey",
)
fair_order_function = function_source(
    SOURCE,
    "static NSArray<NSDictionary *> *ICBackupRemainingDownloadsWithFairInspectionOrder",
)


def compile_probe(directory: Path) -> Path:
    harness = directory / "fairness_probe.m"
    harness.write_text(
        f'''#import <Foundation/Foundation.h>

{pending_key_function}

{fair_order_function}

static NSArray<NSString *> *FlattenGUIDs(NSArray<NSDictionary *> *downloads) {{
    NSMutableArray<NSString *> *guids = [NSMutableArray array];
    for (NSDictionary *entry in downloads) {{
        [guids addObjectsFromArray:entry[@"guids"]];
    }}
    return guids;
}}

int main(void) {{
    @autoreleasepool {{
        NSString *feedURL = @"https://example.test/feed.xml";
        NSMutableArray<NSString *> *guids = [NSMutableArray array];
        NSMutableSet<NSString *> *inspectedKeys = [NSMutableSet set];
        NSSet<NSString *> *actionableGUIDs = [NSSet setWithObject:@"guid-41"];
        NSUInteger initialStarts = 0;
        for (NSUInteger index = 1; index <= 41; index++) {{
            NSString *guid = [NSString stringWithFormat:@"guid-%02lu", (unsigned long)index];
            [guids addObject:guid];
            if (index <= 40) {{
                [inspectedKeys addObject:ICBackupPendingDownloadKey(feedURL, guid)];
                if ([actionableGUIDs containsObject:guid] && initialStarts < 20) initialStarts++;
            }}
        }}
        if (initialStarts != 0) return 64;

        NSArray<NSDictionary *> *remaining = ICBackupRemainingDownloadsWithFairInspectionOrder(
            @[],
            @[@{{ @"feedURL": feedURL, @"guids": guids }}],
            [NSSet set],
            inspectedKeys
        );
        NSArray<NSString *> *orderedGUIDs = FlattenGUIDs(remaining);
        if (orderedGUIDs.count != 41 || ![orderedGUIDs.firstObject isEqualToString:@"guid-41"]) {{
            fprintf(stderr, "entry 41 remained starved: %s\\n",
                    [[orderedGUIDs componentsJoinedByString:@","] UTF8String]);
            return 65;
        }}
        for (NSUInteger index = 1; index <= 40; index++) {{
            NSString *expected = [NSString stringWithFormat:@"guid-%02lu", (unsigned long)index];
            if (![orderedGUIDs[index] isEqualToString:expected]) return 66;
        }}
        NSUInteger retryStarts = 0;
        for (NSUInteger index = 0; index < MIN((NSUInteger)40, orderedGUIDs.count); index++) {{
            if ([actionableGUIDs containsObject:orderedGUIDs[index]] && retryStarts < 20) retryStarts++;
        }}
        if (retryStarts != 1) return 68;

        NSSet<NSString *> *resolved = [NSSet setWithObject:ICBackupPendingDownloadKey(feedURL, @"guid-01")];
        remaining = ICBackupRemainingDownloadsWithFairInspectionOrder(
            @[],
            @[@{{ @"feedURL": feedURL, @"guids": guids }}],
            resolved,
            inspectedKeys
        );
        orderedGUIDs = FlattenGUIDs(remaining);
        if (orderedGUIDs.count != 40
            || ![orderedGUIDs.firstObject isEqualToString:@"guid-41"]
            || [orderedGUIDs containsObject:@"guid-01"]) return 67;
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
    binary = directory / "fairness_probe"
    result = subprocess.run(
        [clang, "-fobjc-arc", str(harness), "-framework", "Foundation", "-o", str(binary)],
        capture_output=True,
        text=True,
    )
    require(result.returncode == 0,
            "Could not compile deferred-download fairness probe:\n" + result.stderr)
    return binary


with tempfile.TemporaryDirectory(prefix="instacast-backup-fairness-") as temporary_directory:
    probe = compile_probe(Path(temporary_directory))
    result = subprocess.run([str(probe)], capture_output=True, text=True)
    require(result.returncode == 0,
            "The real deferred-download ordering helper starved a runnable entry after index 40: "
            + result.stderr.strip())

write_call = processor.find("ICBackupWriteDownloadStage(remainingDownloads")
fair_order_call = processor.find("ICBackupRemainingDownloadsWithFairInspectionOrder")
require(fair_order_call >= 0 and write_call > fair_order_call,
        "Fair ordering may become authoritative only through the existing durable stage write.")

print("Backup deferred-download fairness regression checks passed")
