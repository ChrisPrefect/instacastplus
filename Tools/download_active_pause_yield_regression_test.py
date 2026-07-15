#!/usr/bin/env python3
"""Pins active per-job suspension to a resume-data yield that frees queue slots."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "CacheManager.m").read_text()
OPERATION = (ROOT / "Classes" / "CacheOperation_iOS7.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        if source.find(";", start, brace) == -1:
            break
        search_start = brace
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


require("setMaxConcurrentOperationCount:3" in MANAGER,
        "The physical download concurrency limit must remain bounded at three.")
require("_downloadPauseYieldTokensByIdentifier" in MANAGER,
        "Pause-yield ownership needs an identity token so cancel cannot resurrect a job.")

request_yield = body(MANAGER, "- (BOOL)_requestDownloadOperationYield:")
require("operation isExecuting" in request_yield and "[operation cancel]" in request_yield and
        "_replaceYieldedDownloadOperation" in request_yield,
        "A queued or active suspended operation must end once and be replaced from durable resume data.")

replace_yield = body(MANAGER, "- (BOOL)_replaceYieldedDownloadOperation:")
for required in (
    "_scheduledDownloadOperationIdentifiers removeObject",
    "_downloadOperationsByIdentifier[identifier] = replacement",
    "_persistCachingOperation:replacement",
    "_startNextDownloadOperations",
):
    require(required in replace_yield,
            "Yield replacement must preserve the logical job while freeing and rescheduling its physical slot.")

pause_one = body(MANAGER, "- (void) pauseCachingEpisode:")
require("_requestDownloadOperationYield:operation" in pause_one,
        "Pausing an already running episode must yield its physical queue slot.")

network = body(MANAGER, "- (void) _handleNetworkStatusChanged")
require("_requestDownloadOperationYield:operation" in network and
        "[self _startNextDownloadOperations]" in network,
        "A Wi-Fi-only job suspended by network policy must yield so a cellular-approved job can start.")

scheduler = body(MANAGER, "- (void) _startNextDownloadOperations")
require("!operation.suspended" in scheduler,
        "The bounded scheduler must count runnable operations, not persisted paused jobs.")

did_end = body(MANAGER, "- (void) cacheOperationDidEnd:")
require(did_end.find("_replaceYieldedDownloadOperation") < did_end.find("_removeTrackedDownloadOperation"),
        "A pause-yield must replace the single-use operation before normal terminal cleanup deletes the logical job.")

cancel = body(MANAGER, "- (void) cancelCachingEpisode:")
cancel_after_intent = body(MANAGER, "- (void)_cancelCachingEpisodeAfterDurableIntent:")
cancel_tracked = body(MANAGER, "- (void)_cancelTrackedDownloadOperationAfterDurableIntent:")
require("_cancelCachingEpisode:" in cancel and
        "_cancelTrackedDownloadOperationAfterDurableIntent:operation" in cancel_after_intent and
        "_downloadPauseYieldTokensByIdentifier removeObjectForKey" in cancel_tracked,
        "User cancellation must revoke pause-yield ownership so the callback cannot recreate the job.")

operation_cancel = body(OPERATION, "- (void) main")
require("cancelByProducingResumeData" in operation_cancel and "_saveResumeData" in operation_cancel,
        "The yielded operation must durably save URLSession resume data before its replacement starts.")

print("Download active-pause yield regression checks passed")
