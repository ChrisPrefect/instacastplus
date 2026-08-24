#!/usr/bin/env python3
"""Pins the add-keyword example placeholder to both app locales."""

import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ChapterSkipListViewController.m").read_text()


def strings(path: str) -> dict[str, str]:
    output = subprocess.check_output([
        "plutil", "-convert", "json", "-o", "-", str(ROOT / path)
    ])
    return json.loads(output)


key = "e.g. Ads, Intro, Sponsor"
assert '@"e.g. Ads, Intro, Sponsor".ls' in SOURCE, \
    "The chapter-skip keyword example must be localized at its UIKit assignment."

english = strings("Resources/en.lproj/Localizable.strings")
german = strings("Resources/de.lproj/Localizable.strings")
assert english.get(key) == key, "English chapter-skip placeholder is missing."
assert german.get(key) == "z. B. Werbung, Intro, Sponsor", \
    "German chapter-skip placeholder is missing or unclear."

print("Chapter-skip placeholder localization regression checks passed")
