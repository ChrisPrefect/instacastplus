#!/usr/bin/env python3
"""Pins bulk local iCloud outbox reads and rebinding away from the main coordinator."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


def function_body(signature: str) -> str:
    start = LOCAL.find(signature)
    if start == -1:
        raise AssertionError(f"Missing function: {signature}")
    brace = LOCAL.find("{", start)
    if brace == -1:
        raise AssertionError(f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(LOCAL)):
        if LOCAL[index] == "{":
            depth += 1
        elif LOCAL[index] == "}":
            depth -= 1
            if depth == 0:
                return LOCAL[brace + 1:index]
    raise AssertionError(f"Unterminated function: {signature}")


class ICloudOutboxStoreIsolationRegressionTests(unittest.TestCase):
    def test_bulk_outbox_operations_use_the_dedicated_sync_coordinator(self):
        for signature in (
            "nonisolated static func localOutboxEntries(",
            "func bindLocalOutboxEntries(",
        ):
            with self.subTest(signature=signature):
                body = function_body(signature)
                self.assertIn("newICloudSyncBackgroundContext()", body)
                self.assertNotIn("newBackgroundContext()", body)


if __name__ == "__main__":
    unittest.main()
