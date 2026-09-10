#!/usr/bin/env python3
"""Admission is a confirmed server fact, separate from a durable local intent."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
MANAGER = (ROOT / 'Classes/ServerTranscriptionManager.swift').read_text()


def body(signature):
    start = MANAGER.index(signature)
    brace = MANAGER.index('{', start)
    depth = 0
    for index in range(brace, len(MANAGER)):
        depth += (MANAGER[index] == '{') - (MANAGER[index] == '}')
        if depth == 0:
            return MANAGER[brace:index + 1]
    raise AssertionError(signature)


class AdmissionContract(unittest.TestCase):
    def test_uncertain_boundary_is_durable_before_post(self):
        process = body('private func processNext()')
        boundary = process.index('= .unconfirmed')
        self.assertLess(boundary, process.index('await self.awaitQueuePersistence()', boundary))
        self.assertLess(process.index('await self.awaitQueuePersistence()', boundary), process.index('await self.submitEpisode', boundary))
        self.assertNotIn('item.status = .transcribing', process)
        self.assertIn('admissionState: admissionByItem', body('private func persistQueue()'))
        self.assertIn('stored.admissionState ??', body('private func loadPersistedQueue()'))

    def test_wire_refusal_and_ambiguous_response_are_distinct(self):
        self.assertIn('let admitted: Bool?', MANAGER)
        self.assertIn('userInfo["serverAdmitted"] = admitted', body('private func request<'))
        handle = body('private func handle(error:')
        admission_branch = handle[handle.index('if admissionByItem[ObjectIdentifier(item)] != .accepted'):]
        self.assertLess(admission_branch.index('!= .accepted'), admission_branch.index('serverAdmitted'))
        retry_header_branch = handle[:handle.index('if admissionByItem[ObjectIdentifier(item)] != .accepted')]
        self.assertIn('nsError.userInfo["serverAdmitted"] as? Bool != false', retry_header_branch)
        self.assertIn('nsError.userInfo["serverAdmitted"] as? Bool == false', admission_branch)
        self.assertIn('rejectAdmission(item', handle)
        self.assertIn('The server has not confirmed the request yet.', handle)
        self.assertIn('fail(item', body('private func rejectAdmission('))
        for code in ['queue_full', 'client_queue_full', 'provider_unavailable', 'worker_unavailable', 'resources_unavailable']:
            self.assertIn('"' + code + '"', body('private func admissionRejectionMessage('))

    def test_success_feedback_requires_validated_receipt(self):
        process = body('private func processNext()')
        self.assertLess(process.index('envelope.apiVersion == "v1"'), process.index('accepted: true'))
        self.assertLess(process.index('envelope.clientRequest?.id == requestID'), process.index('accepted: true'))
        enqueue = body('@objc func enqueueEpisode(')
        self.assertIn('admissionCompletions[ObjectIdentifier(item)] = completion', enqueue)
        self.assertNotIn('Server-Transkription eingereicht', enqueue)
        for filename in ['EpisodesTableViewController.m', 'ICEpisodeSwipeActionHandler.m', 'EpisodeViewController.m']:
            source = (ROOT / 'Classes' / filename).read_text()
            self.assertIn('completion:^(BOOL accepted, NSString* message)', source)
            self.assertNotIn('enqueueEpisode:episode])', source)
            self.assertNotIn('enqueueEpisode:self.episode])', source)

    def test_pending_capacity_and_truthful_headline(self):
        queue = (ROOT / 'Classes/TranscriptionQueue.swift').read_text()
        ui = (ROOT / 'Classes/TranscriptionQueueViewController.m').read_text()
        self.assertIn('maximumActiveItemCount = 25', queue)
        self.assertIn('unconfirmedAdmissionCount', queue)
        self.assertIn('headline = detail;', ui)
        self.assertIn('transcription requests are awaiting confirmation.', queue)
        self.assertIn('wasAdmissionRejectedForEpisodeHash:', ui)
        self.assertIn('networkUnavailable', body('private func processNext()'))


if __name__ == '__main__':
    unittest.main()
