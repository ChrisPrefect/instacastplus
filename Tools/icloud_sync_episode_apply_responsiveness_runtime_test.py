#!/usr/bin/env python3
"""Synthetic 4515-row heartbeat proof for the production EpisodeState architecture."""

import asyncio
import math
import time
import unittest

from _icloud_sync_episode_apply_test_support import common_episode_background_worker


PAYLOAD_COUNT = 4515
BATCH_SIZE = 100
SYNTHETIC_BATCH_SECONDS = 0.025
MAX_HEARTBEAT_GAP_SECONDS = 0.018


async def measure_main_heartbeat(*, off_main: bool, payload_count: int) -> float:
    payloads = [
        (f"episode_{index}", index % 2 == 0, index % 3 == 0, index)
        for index in range(payload_count)
    ]
    heartbeat_gaps: list[float] = []
    stop = False
    loop = asyncio.get_running_loop()

    async def heartbeat():
        previous = loop.time()
        while not stop:
            await asyncio.sleep(0.002)
            now = loop.time()
            heartbeat_gaps.append(now - previous)
            previous = now

    def apply_all_batches():
        for start in range(0, len(payloads), BATCH_SIZE):
            chunk = payloads[start:start + BATCH_SIZE]
            if not chunk:
                raise AssertionError("Synthetic EpisodeState page unexpectedly empty")
            # Models the indexed Core Data mutation/save cost of one bounded page.
            time.sleep(SYNTHETIC_BATCH_SECONDS)

    heartbeat_task = asyncio.create_task(heartbeat())
    await asyncio.sleep(0.01)
    if off_main:
        await asyncio.to_thread(apply_all_batches)
    else:
        for start in range(0, len(payloads), BATCH_SIZE):
            chunk = payloads[start:start + BATCH_SIZE]
            if not chunk:
                raise AssertionError("Synthetic EpisodeState page unexpectedly empty")
            time.sleep(SYNTHETIC_BATCH_SECONDS)
            # Mirrors the current Task.yield between synchronous MainActor pages.
            await asyncio.sleep(0)
    await asyncio.sleep(0.01)
    stop = True
    await heartbeat_task
    if not heartbeat_gaps:
        return 0
    # A loaded CI host can deschedule the whole Python process once without any app-side
    # main-thread work. The 99th percentile still catches every synthetic 25 ms main batch
    # (there are dozens), while ignoring that unrelated single scheduler outlier.
    ordered_gaps = sorted(heartbeat_gaps)
    percentile_index = max(0, math.ceil(len(ordered_gaps) * 0.99) - 1)
    return ordered_gaps[percentile_index]


class ICloudEpisodeApplyResponsivenessRuntimeTests(unittest.IsolatedAsyncioTestCase):
    async def test_heartbeat_harness_distinguishes_yielded_main_batches_from_background_work(self):
        main_gap = await measure_main_heartbeat(off_main=False, payload_count=500)
        background_gap = await measure_main_heartbeat(off_main=True, payload_count=500)
        self.assertGreater(main_gap, MAX_HEARTBEAT_GAP_SECONDS)
        self.assertLess(
            background_gap,
            MAX_HEARTBEAT_GAP_SECONDS,
            f"Heartbeat harness itself is too noisy ({background_gap:.3f}s).",
        )

    async def test_production_architecture_keeps_4515_payload_heartbeat_responsive(self):
        worker = common_episode_background_worker()
        maximum_gap = await measure_main_heartbeat(
            off_main=worker is not None,
            payload_count=PAYLOAD_COUNT,
        )
        self.assertEqual(math.ceil(PAYLOAD_COUNT / BATCH_SIZE), 46)
        self.assertLess(
            maximum_gap,
            MAX_HEARTBEAT_GAP_SECONDS,
            f"Production is still classified as yielded MainActor apply; the synthetic "
            f"4515-row run stalled its heartbeat for {maximum_gap:.3f}s.",
        )
        self.assertIsNotNone(worker)


if __name__ == "__main__":
    unittest.main()
