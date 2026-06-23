#!/usr/bin/env python3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "ICImageCacheOperation.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start >= 0, f"{signature} is missing.")
    candidates = []
    for marker in ("\n- (", "\n+ (", "\n#pragma mark"):
        index = source.find(marker, start + len(signature))
        if index > start:
            candidates.append(index)
    end = min(candidates) if candidates else len(source)
    return source[start:end]


completion_method = method_body(
    SOURCE,
    "- (void) _sendCompletionBlockImage:(IC_IMAGE*)image error:(NSError*)error",
)

require(
    "__weak" not in completion_method and "weakSelf" not in completion_method,
    "Image-cache completions must not dispatch through weakSelf; the operation can be released before the main-queue block runs.",
)
require(
    "dispatch_async(dispatch_get_main_queue(), ^{" in completion_method
    and "[self isCancelled]" in completion_method,
    "Image-cache completions must retain the operation until main-queue delivery and check cancellation at delivery time.",
)
require(
    "void (^completion)(IC_IMAGE*, NSError*) = self.didEndBlock;" in completion_method,
    "Image-cache completion delivery must snapshot the block before invoking it.",
)
require(
    "completion(image, error);" in completion_method
    and "self.didEndBlock(image, error)" not in completion_method,
    "Image-cache completion delivery must call the snapshotted completion block, not re-read the property while invoking it.",
)
