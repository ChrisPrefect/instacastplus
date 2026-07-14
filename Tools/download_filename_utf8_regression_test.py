#!/usr/bin/env python3
"""Pins downloaded filenames to filesystem byte limits for non-ASCII titles."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing function/method: {signature}")
    brace = SOURCE.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(SOURCE)):
        if SOURCE[index] == "{":
            depth += 1
        elif SOURCE[index] == "}":
            depth -= 1
            if depth == 0:
                return SOURCE[brace + 1:index]
    raise AssertionError(f"Unterminated function/method: {signature}")


# Reproduction: both old 80-UTF-16-character components can each consume 320 UTF-8
# bytes before the stable hash/extension suffix is appended.
old_style_name = f"{'🎙️' * 40} - {'界' * 80} - {'a' * 32}.mp3.part"
require(len(old_style_name.encode("utf-8")) > 255,
        "The regression fixture must exceed Darwin's per-component byte limit.")

truncate = body("static NSString* ICStringByTruncatingToUTF8ByteLength")
require("lengthOfBytesUsingEncoding:NSUTF8StringEncoding" in truncate and
        "NSStringEnumerationByComposedCharacterSequences" in truncate,
        "Filename truncation must count UTF-8 bytes without splitting a grapheme cluster.")

sanitize = body("static NSString* ICSanitizeFilenameComponent")
require("ICStringByTruncatingToUTF8ByteLength" in sanitize and "substringToIndex:80" not in sanitize,
        "Human-readable components must be byte-limited, not UTF-16-index limited.")

extension = body("static NSString* ICSanitizeFilenameExtension")
require("alphanumericCharacterSet" in extension and
        "ICStringByTruncatingToUTF8ByteLength" in extension,
        "A remote URL extension must not consume an unbounded or unsafe filename suffix.")

cached_url = body("- (NSURL*) URLForCachedEpisode:")
require("ICSanitizeFilenameExtension" in cached_url and
        cached_url.count("ICSanitizeFilenameComponent") >= 2,
        "Every new and migrated episode path must use the byte-safe central filename components.")

print("Download filename UTF-8 regression checks passed")
