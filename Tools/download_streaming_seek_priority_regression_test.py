#!/usr/bin/env python3
"""Pins seek-first range scheduling before stream-cache backfill."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PLAYBACK = (ROOT / "Classes" / "PlaybackManager.m").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")

    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


prioritize = method_body(PLAYBACK, "- (void)_prioritizeHighPriorityRangeFrom:")
require(
    "[self.highPriorityRanges insertObject:" in prioritize
    and "atIndex:0" in prioritize
    and "ICStreamSubtractRangeFromArray" in prioritize
    and "[supersededTask cancel]" in prioritize,
    "A newly requested playback range must move ahead of an earlier start-to-end request "
    "without leaving an overlapping queued range in front of it or waiting for an unrelated "
    "start-of-file chunk to finish.",
)

dequeue = method_body(PLAYBACK, "- (ICStreamByteRange)_dequeueHighPriorityChunk")
require(
    "[self.highPriorityRanges insertObject:" in dequeue
    and "atIndex:0" in dequeue
    and "ICStreamMergeRangeIntoArray(self.highPriorityRanges" not in dequeue,
    "Once playback starts at a seek position, successive chunks from that position to the "
    "end must stay ahead of the start-of-file backfill.",
)

pending = method_body(PLAYBACK, "- (void)_processPendingRequests")
require(
    "_prioritizeHighPriorityRangeFrom:currentOffset to:requestedEnd" in pending
    and "self.forwardDownloadOffset = requestedOffset" in pending,
    "AVFoundation byte requests must enter the playback-priority queue and remember a "
    "non-zero playback offset for seek-to-EOF downloading.",
)
require(
    "isBootstrapToEndRequest" in pending
    and "!isBootstrapToEndRequest || self.forwardDownloadOffset <= 0" in pending
    and "[self.highPriorityRanges removeAllObjects]" in pending,
    "After a non-zero seek, AVFoundation's older 0..EOF bootstrap request must stop "
    "reasserting start-of-file priority on every received data block.",
)

open_episode = method_body(
    PLAYBACK,
    "- (void) openWithEpisode:(CDEpisode*)anEpisode at:(NSTimeInterval)time autostart:(BOOL)autostart",
)
require(
    "loadValuesAsynchronouslyForKeys:" not in open_episode
    and "[self _continueOpeningAsset:self.mediaAsset autostart:autostart];" in open_episode,
    "Opening a streamed MP3 must create the player item immediately. Preloading either "
    "tracks or duration issues a 0..EOF request before the saved playback position can "
    "be sought.",
)

response = method_body(
    PLAYBACK,
    "- (void)URLSession:(NSURLSession *)session\n          dataTask:(NSURLSessionDataTask *)dataTask\ndidReceiveResponse:",
)
receive_data = method_body(
    PLAYBACK,
    "- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:",
)
require(
    "dataTask != self.activeTask" in response
    and "dataTask != self.activeTask" in receive_data,
    "Callbacks from a preempted start-of-file task must never mutate the new seek task's "
    "write offset or sparse file ranges.",
)

backfill = method_body(PLAYBACK, "- (ICStreamByteRange)_nextBackfillChunk")
require(
    "self.forwardDownloadOffset" in backfill
    and "_nextMissingChunkFrom:self.forwardDownloadOffset to:targetLength" in backfill
    and "_nextMissingChunkFrom:0 to:self.forwardDownloadOffset" in backfill
    and backfill.find("_nextMissingChunkFrom:self.forwardDownloadOffset to:targetLength")
    < backfill.find("_nextMissingChunkFrom:0 to:self.forwardDownloadOffset"),
    "After the immediate AVFoundation request is buffered, caching must continue from the "
    "playback offset to EOF before filling 0..playbackOffset.",
)


def subtract(queued: list[tuple[int, int]], priority: tuple[int, int]) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    priority_start, priority_end = priority
    for start, end in queued:
        if end <= priority_start or start >= priority_end:
            result.append((start, end))
            continue
        if start < priority_start:
            result.append((start, priority_start))
        if end > priority_end:
            result.append((priority_end, end))
    return result


# AVFoundation commonly opens with a 0..EOF request. A later seek to the middle must
# split that queued request and put the seek tail first. Only after EOF may 0..seek backfill.
whole_file = [(0, 100_000_000)]
seek_tail = (60_000_000, 100_000_000)
queue = [seek_tail, *subtract(whole_file, seek_tail)]
require(
    queue == [(60_000_000, 100_000_000), (0, 60_000_000)],
    "Seek scheduling must download seek..EOF before 0..seek.",
)


def process_pending(
    queued: list[tuple[int, int]],
    requests: list[tuple[int, int, int, bool]],
    forward_offset: int,
) -> tuple[list[tuple[int, int]], int]:
    for requested_offset, current_offset, requested_end, bootstrap_to_end in requests:
        if requested_offset > 0 and requested_offset != forward_offset:
            forward_offset = requested_offset
            queued.clear()
        if not bootstrap_to_end or forward_offset <= 0:
            priority = (current_offset, requested_end)
            queued = [priority, *subtract(queued, priority)]
    return queued, forward_offset


# Reproduce the real second-cycle failure: after the seek request has been served,
# AVFoundation keeps its older 0..EOF bootstrap request alive. It must not put
# 0..seek back in front; the normal backfill scheduler then continues seek..EOF.
queue, forward_offset = process_pending(
    [(0, 100_000_000)],
    [
        (0, 4_000_000, 100_000_000, True),
        (60_000_000, 60_000_000, 60_500_000, False),
    ],
    0,
)
require(
    queue == [(60_000_000, 60_500_000)] and forward_offset == 60_000_000,
    "The first seek cycle must discard stale bootstrap priority.",
)
queue, forward_offset = process_pending(
    [],
    [(0, 4_000_000, 100_000_000, True)],
    forward_offset,
)
require(
    queue == [] and forward_offset == 60_000_000,
    "The surviving 0..EOF request must not restore start-of-file priority after the "
    "seek request completes.",
)

print("Download streaming seek-priority regression checks passed")
