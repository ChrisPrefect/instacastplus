#!/usr/bin/env python3
"""Pins CacheManager singleton construction against concurrent startup callers."""

from pathlib import Path


SOURCE = (Path(__file__).resolve().parents[1] / "Classes" / "CacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


start = SOURCE.find("+ (CacheManager*) sharedCacheManager")
require(start != -1, "Missing CacheManager singleton accessor.")
brace = SOURCE.find("{", start)
depth = 0
end = None
for index in range(brace, len(SOURCE)):
    if SOURCE[index] == "{":
        depth += 1
    elif SOURCE[index] == "}":
        depth -= 1
        if depth == 0:
            end = index
            break
require(end is not None, "Unterminated CacheManager singleton accessor.")
shared = SOURCE[brace + 1:end]

require("static dispatch_once_t onceToken" in shared and
        "dispatch_once(&onceToken" in shared and
        "gSharedCacheManager = [[self alloc] init]" in shared,
        "Concurrent widget/app/background startup must never observe two or half-initialized CacheManager instances.")
require("if (!gSharedCacheManager)" not in shared,
        "A plain global nil check is not an atomic singleton initialization contract.")

print("CacheManager singleton regression checks passed")
