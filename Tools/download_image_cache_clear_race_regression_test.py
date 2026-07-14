#!/usr/bin/env python3
"""Pins image-cache clear against disk lookups and late operation callbacks."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ImageCacheManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(signature: str) -> str:
    start = MANAGER.index(signature)
    brace = MANAGER.index("{", start)
    depth = 0
    for index in range(brace, len(MANAGER)):
        if MANAGER[index] == "{":
            depth += 1
        elif MANAGER[index] == "}":
            depth -= 1
            if depth == 0:
                return MANAGER[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


request = body("- (void) imageForURL:")
publish = body("- (void) cacheImage:")
clear = body("- (void)cancelImageDownloadsAndClearCacheWithCompletion:")

require("self.clearingImageCache" in request,
        "New image lookups must terminate while a destructive clear owns the cache.")
require("strongSelf.clearingImageCache" in request,
        "A disk lookup already queued before clear must not repopulate memory or start networking.")
require("self.clearingImageCache" in publish,
        "Late public operation callbacks must not repopulate memory during clear.")
require("dispatch_barrier_async(self->_queue" in clear,
        "Clear must drain the separate concurrent disk-lookup queue before deleting files.")
require("waitUntilAllOperationsAreFinished" in clear and
        clear.count("removeAllObjects") >= 2,
        "Clear must wait for image operations and clear memory again after all late writers finish.")
require("dispatch_get_global_queue" not in clear,
        "The disk-lookup barrier itself is the utility worker; a separate queue reopens the race.")

print("Image-cache clear race regression checks passed")
