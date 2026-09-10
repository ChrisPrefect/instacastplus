#!/usr/bin/env python3
"""Server polling must preserve durable ownership without republishing unchanged UI."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "Classes/ServerTranscriptionManager.swift").read_text()


def body(signature):
    start = SOURCE.index("{", SOURCE.index(signature))
    depth = 0
    for index in range(start, len(SOURCE)):
        depth += (SOURCE[index] == "{") - (SOURCE[index] == "}")
        if depth == 0:
            return SOURCE[start + 1:index]
    raise AssertionError(signature)


class ServerPollEfficiencyTests(unittest.TestCase):
    def test_unchanged_poll_does_not_publish_retry_bookkeeping(self):
        publish = body("private func postQueueChange()")
        self.assertIn("publishedQueueState", publish)
        self.assertLess(publish.index("isEqual"), publish.index("NotificationCenter.default.post"))
        for field in ("status.rawValue", "progress", "statusDetail", "error", "queueStorageError"):
            self.assertIn(field, publish)
        self.assertNotIn("nextRetryAt", publish)
        self.assertNotIn('"isProcessing":', publish)
        self.assertIn("isProcessing", body("private func publishProcessingChange()"))

    def test_background_tasks_observe_separate_server_processing_lifecycle(self):
        delegate = (Path(__file__).resolve().parents[1] / "Classes/InstacastAppDelegate.m").read_text()
        self.assertEqual(2, delegate.count('addObserverForName:@"ICServerTranscriptionProcessingDidChangeNotification"'))
        self.assertEqual(2, delegate.count('removeObserver:serverProcessingObserver'))
        self.assertIn('publishProcessingChange()', body("private func postQueueChange()"))

    def test_serial_background_persistence_retains_ownership(self):
        persist = body("private func persistQueue()")
        self.assertTrue('DispatchQueue(label: "com.instacast.server-transcription.persistence", qos: .utility)' in SOURCE,
                        "Server persistence needs its own serial utility queue")
        self.assertLess(persist.index("persistenceQueue.async"), persist.index("JSONEncoder().encode"))
        self.assertLess(persist.index("persistenceQueue.async"), persist.index("data.write"))
        self.assertIn("pendingPersistenceCount > 0", body("@objc var isProcessing:"))
        process = body("private func processNext()")
        self.assertLess(process.index("pendingPersistenceCount == 0"), process.index("currentItem = item"))
        completion = persist[persist.index("DispatchQueue.main.async"):]
        self.assertIn("pendingPersistenceCount -= 1", completion)
        self.assertLess(completion.index("processNext()"), completion.index("postQueueChange()"))

    def test_existing_jobs_wait_for_server_capacity(self):
        transient = body("private func isTransient(")
        self.assertIn('userInfo["serverRetryable"]', transient)
        self.assertIn("return retryable", transient)
        self.assertLess(transient.index("return retryable"), transient.index("nsError.code == 429"))
        self.assertIn('userInfo["serverRetryable"] = apiError.retryable', body("private func request<"))
        self.assertIn('userInfo["serverErrorCode"] = apiError.code', body("private func request<"))
        self.assertIn('"worker_unavailable"', body("private func localizedServiceUnavailableDetail("))
        self.assertIn("The server transcription queue is full. Your job will retry automatically when capacity is available.",
                      body("private func localizedServiceUnavailableDetail("))

    def test_discovery_acknowledgement_waits_for_server_durability(self):
        wait = body("func whenQueuePersisted(")
        self.assertIn("pendingPersistenceCount == 0", wait)
        self.assertIn("completion(queueStorageError)", wait)
        self.assertIn("persistenceCompletions.append(completion)", wait)
        persist = body("private func persistQueue()")
        self.assertIn("completion(writeError)", persist)

    def test_provider_pause_preserves_job_and_server_retry_hint(self):
        handle = body("private func handle(error:")
        detail = body("private func localizedServiceUnavailableDetail(")
        self.assertIn('"provider_unavailable"', detail)
        self.assertIn("Server processing is paused. The operator must restore service; your job will retry automatically.", detail)
        self.assertIn("localizedServiceUnavailableDetail", handle)
        self.assertIn("schedulePoll(item, after: retryAfter(from: nsError)", handle)
        self.assertNotIn("serverIDByItem.removeValue", handle)
        self.assertNotIn("item.status = .queued", handle[handle.index("guard isTransient(error)"):])
        self.assertIn("(500...599).contains(nsError.code)", body("private func isTransient("))
        apply = body("private func apply(")
        self.assertIn("envelope.serviceStatus", apply)
        self.assertIn("!serviceStatus.available", apply)
        self.assertIn("localizedServiceUnavailableDetail(serviceStatus.code)", apply)
        self.assertIn("schedulePoll(item, after: envelope.retryAfterSeconds)", apply)

    def test_capacity_rejection_preserves_existing_history(self):
        enqueue = body("@objc func enqueueEpisode(")
        self.assertLess(enqueue.index("admitQueueItem("), enqueue.index("items.removeAll"))
        automatic = body("@objc func enqueueAutomaticEpisodes(")
        self.assertLess(automatic.index("admitQueueItem("), automatic.index("items.append(item)"))
        self.assertIn("admitQueueItem(", body("@objc func retryEpisodeHash("))
        self.assertNotIn("maximumActiveItemCount", body("private func loadPersistedQueue()"))


if __name__ == "__main__":
    unittest.main()
