#!/usr/bin/env python3
"""Pins lossless delegate ordering while reattaching a background download session."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method(signature: str, next_marker: str) -> str:
    start = SOURCE.find(signature)
    require(start != -1, f"Missing method {signature}")
    end = SOURCE.find(next_marker, start)
    require(end != -1, f"Missing end marker for {signature}")
    return SOURCE[start:end]


require("taskInventoryResolved" in SOURCE and "pendingCompletedTask" in SOURCE and
        "pendingCompletionError" in SOURCE and "receivedFinishedDownload" in SOURCE,
        "Delegate events arriving before getTasks completes need explicit pending state.")
require("_taskBelongsToOperation:" in SOURCE,
        "Early callbacks must be authenticated by session and remote URL before adoption.")
require("[self.delegateQueue addOperationWithBlock:" in SOURCE,
        "getTasks reconciliation must be serialized with NSURLSession delegate callbacks.")
require("if (self.receivedFinishedDownload)" in SOURCE and "pendingCompletedTask" in SOURCE.split("getTasksWithCompletionHandler", 1)[1],
        "Task inventory must honor an earlier finished/pending callback before creating a replacement task.")

finish = method("didFinishDownloadingToURL:", "didWriteData:")
require("downloadTask != self.downloadTask" not in finish,
        "A valid early finished callback must not be discarded merely because async adoption has not run.")
require("_taskBelongsToOperation:downloadTask" in finish and "self.downloadTask = downloadTask" in finish,
        "A matching finished task must be adopted immediately while its temporary file still exists.")

complete = method("didCompleteWithError:", "didFinishDownloadingToURL:")
require("!self.taskInventoryResolved" in complete and "self.pendingCompletedTask = (NSURLSessionDownloadTask*)task" in complete,
        "An early completion error must be retained until task inventory chooses the authoritative task.")

print("Download background reattach race regression checks passed")
