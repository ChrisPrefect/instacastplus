#!/usr/bin/env python3
"""Distributed cancellation must survive lost responses, relaunch and stale tasks."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SERVER = (ROOT / "Classes/ServerTranscriptionManager.swift").read_text()


def body(signature):
    start = SERVER.index("{", SERVER.index(signature))
    depth = 0
    for index in range(start, len(SERVER)):
        depth += (SERVER[index] == "{") - (SERVER[index] == "}")
        if depth == 0:
            return SERVER[start + 1:index]
    raise AssertionError(signature)


class CancellationTests(unittest.TestCase):
    def test_remote_cancellation_precedes_phase_validation(self):
        apply = body("private func apply(")
        self.assertLess(apply.index('episode.status == "canceled"'), apply.index("guard let phase = localizedPhase"))
        self.assertIn("cancelLocally(", apply)
        self.assertIn(".canceled", body("private func cancelLocally("))
        self.assertIn("item.nextRetryAt = nil", body("private func cancelLocally("))

    def test_intents_and_request_identity_are_durable(self):
        for field in ("clientRequestID", "explicitRestart", "cancellations"):
            self.assertIn(field, body("private func persistQueue()"))
            self.assertIn(field, body("private func loadPersistedQueue()"))
        remove = body("@objc func dequeueEpisodeHash(")
        self.assertLess(remove.index("queueCancellation("), remove.index("removeMetadata("))
        self.assertIn("queueCancellation(", body("@objc func cancelAll()"))
        self.assertIn("needsIdentityPersistence", body("@objc func resumeIfNeeded()"))

    def test_tombstone_precedes_retry_and_late_response_is_fenced(self):
        retry = body("@objc func retryEpisodeHash(")
        self.assertLess(retry.index("queueCancellation("), retry.index("UUID()"))
        self.assertIn("explicitRestartByItem", retry)
        process = body("private func processNext()")
        self.assertIn("processPendingCancellation()", process)
        self.assertIn("checkCurrentAttempt", process)
        imports = body("private func importArtifacts(")
        self.assertLess(imports.index("checkCurrentAttempt"), imports.index("saveValidatedServerSRTData"))
        self.assertIn("Task.checkCancellation()", body("private func checkCurrentAttempt("))

    def test_cancellation_uses_idempotent_api_and_ack_before_forgetting(self):
        cancel = body("private func processPendingCancellation()")
        self.assertIn('method: "DELETE"', cancel)
        self.assertIn("client-requests/", cancel)
        self.assertIn("/client-request", cancel)
        self.assertLess(cancel.index("receipt.clientRequest.state"), cancel.index("cancellations.removeAll"))
        self.assertIn("persistQueue()", cancel)
        self.assertIn("nextRetryAt", cancel)
        self.assertIn("hasPendingCancellations", SERVER)

    def test_canceled_releases_capacity_and_is_visible(self):
        defines = (ROOT / "Classes/Defines.h").read_text()
        self.assertIn("ICTranscriptionStatusCanceled", defines)
        queue = (ROOT / "Classes/TranscriptionQueue.swift").read_text()
        active = queue.split("@objc var activeItemCount:", 1)[1].split("\n    }", 1)[0]
        self.assertIn(".canceled", active)
        ui = (ROOT / "Classes/TranscriptionQueueViewController.m").read_text()
        self.assertIn("case ICTranscriptionStatusCanceled:", ui)
        self.assertIn("hasPendingCancellations", queue)


if __name__ == "__main__":
    unittest.main()
