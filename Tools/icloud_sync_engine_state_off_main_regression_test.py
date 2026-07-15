#!/usr/bin/env python3
"""Pins CKSyncEngine state encoding and atomic persistence off MainActor."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / "Classes" / "ICiCloudSyncManager.swift").read_text()
ENGINE = (ROOT / "Classes" / "ICiCloudSyncManager+EngineRecords.swift").read_text()
METADATA = (ROOT / "Classes" / "ICiCloudSyncManager+Metadata.swift").read_text()
ALL = "\n".join((MANAGER, ENGINE, METADATA))


def method_bounds(source: str, signature: str) -> tuple[int, int, int]:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
    brace = source.find("{", start)
    if brace == -1:
        raise AssertionError(f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return start, brace, index
    raise AssertionError(f"Unterminated method: {signature}")


def method_body(source: str, signature: str) -> str:
    _, brace, end = method_bounds(source, signature)
    return source[brace + 1:end]


def method_declaration(source: str, signature: str) -> str:
    start, brace, _ = method_bounds(source, signature)
    return source[start:brace]


class ICloudEngineStateOffMainRegressionTests(unittest.TestCase):
    def test_state_update_is_intercepted_before_the_main_actor_hop(self):
        callback = method_body(ENGINE, "nonisolated func handleEvent")
        state_case = callback.find("case .stateUpdate")
        main_hop = callback.find("handleEventOnMain")
        self.assertGreater(
            state_case,
            -1,
            "Large state serializations must be handled on the nonisolated callback path.",
        )
        self.assertLess(state_case, main_hop)

        main_handler = method_body(ENGINE, "func handleEventOnMain")
        state_branch = main_handler.split("case .stateUpdate", 1)[1].split(
            "case .accountChange", 1
        )[0]
        self.assertNotIn(
            "persistStateSerialization",
            state_branch,
            "MainActor must never encode or atomically write CKSyncEngine state.",
        )

    def test_nonisolated_callback_awaits_durable_state_before_returning(self):
        callback = method_body(ENGINE, "nonisolated func handleEvent")
        self.assertIn(
            "case .stateUpdate",
            callback,
            "The nonisolated callback must own the state-update branch before durability can be checked.",
        )
        state_branch = callback.split("case .stateUpdate", 1)[1].split("default", 1)[0]
        persist = state_branch.find("persistStateSerialization")
        awaited = state_branch.rfind("await", 0, persist)
        self.assertGreater(persist, -1)
        self.assertGreater(
            awaited,
            -1,
            "Off-main persistence still has to finish before CKSyncEngine's event returns.",
        )

    def test_encoding_and_atomic_file_write_run_in_detached_work(self):
        signature = "nonisolated func persistStateSerialization"
        declaration = method_declaration(ALL, signature)
        persistence = method_body(ALL, signature)
        self.assertIn("nonisolated", declaration)
        self.assertIn("async", declaration)
        self.assertIn("Task.detached", persistence)
        self.assertIn("JSONEncoder", persistence)
        self.assertIn("writeSyncMetadataValue", persistence)
        self.assertNotIn(
            "setSyncMetadata",
            persistence,
            "setSyncMetadata is MainActor-isolated and performs the atomic file write synchronously.",
        )


if __name__ == "__main__":
    unittest.main()
