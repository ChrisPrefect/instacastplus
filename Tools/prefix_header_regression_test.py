#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Instacast.xcodeproj" / "project.pbxproj"


def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    source = PROJECT.read_text(encoding="utf-8")
    build_settings = re.findall(r"buildSettings = \{\n(.*?)\n\t\t\t\};", source, re.S)
    prefix_header_settings = [
        settings for settings in build_settings
        if "GCC_PREFIX_HEADER = Instacast_Prefix.pch;" in settings
    ]

    assert_true(prefix_header_settings, "The Instacast app target must keep using Instacast_Prefix.pch.")
    for settings in prefix_header_settings:
        assert_true(
            "GCC_PRECOMPILE_PREFIX_HEADER = NO;" in settings,
            "Instacast_Prefix.pch must not be precompiled because SwiftPM GeneratedModuleMaps can invalidate the cached .gch during Watch/iOS builds.",
        )


if __name__ == "__main__":
    main()
