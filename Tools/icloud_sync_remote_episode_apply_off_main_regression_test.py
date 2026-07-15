#!/usr/bin/env python3
"""Pins mass remote episode application off-main without creating outbox echoes."""

import unittest
from pathlib import Path

from _icloud_sync_episode_apply_test_support import (
    common_episode_background_worker,
    function,
    transitive_source,
)


ROOT = Path(__file__).resolve().parents[1]
REMOTE = (ROOT / "Classes" / "ICiCloudSyncManager+RemoteApply.swift").read_text()
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


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


def swift_function_bodies(source: str):
    cursor = 0
    while True:
        marker = source.find("func ", cursor)
        if marker == -1:
            return
        brace = source.find("{", marker)
        if brace == -1:
            return
        depth = 0
        for index in range(brace, len(source)):
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
                if depth == 0:
                    yield source[marker:index + 1]
                    cursor = index + 1
                    break
        else:
            return


class ICloudRemoteEpisodeApplyOffMainRegressionTests(unittest.TestCase):
    def test_episode_mutations_use_the_shared_explicit_background_context(self):
        fetched = method_body(REMOTE, "func handleFetchedRecordZoneChanges")
        worker = common_episode_background_worker()
        self.assertIsNotNone(worker)
        self.assertIn(worker.name, fetched)
        closure = transitive_source(worker.name)
        self.assertIn("newICloudSyncBackgroundContext()", closure)
        self.assertNotIn("databaseManager.objectContext", closure)
        self.assertNotIn("performSynchronousRemoteApplyBatch", closure)

    def test_episode_worker_never_saves_the_main_context(self):
        worker = common_episode_background_worker()
        self.assertIsNotNone(worker)
        closure = transitive_source(worker.name)
        self.assertNotIn("databaseManager.saveReturningError()", closure)
        self.assertIn("context.save()", closure)

    def test_background_save_origin_is_filtered_before_outbox_capture(self):
        process_ids = method_body(LOCAL, "func processSyncObjectIDs")
        self.assertIn(
            "discardRemoteAppliedObjectIDs",
            process_ids,
            "The later main-context merge notification still needs exact object-ID suppression.",
        )

    def test_remote_ids_are_registered_before_the_background_context_commits(self):
        candidates = []
        for body in swift_function_bodies(REMOTE):
            registration_markers = (
                "remoteAppliedObjectIDs.formUnion",
                "remoteAppliedObjectIDs.insert",
                "registerRemoteAppliedObjectIDs",
                "remoteOriginGate.register",
            )
            registration = next(
                (body.find(marker) for marker in registration_markers if marker in body),
                -1,
            )
            save = body.find("context.save()")
            if registration != -1 and save != -1:
                candidates.append((body, registration, save))
        self.assertTrue(
            candidates,
            "A background apply commit must register its exact object IDs before saving.",
        )
        for _, registration, save in candidates:
            self.assertLess(
                registration,
                save,
                "The background save notification can arrive immediately; suppression IDs must already exist.",
            )


if __name__ == "__main__":
    unittest.main()
