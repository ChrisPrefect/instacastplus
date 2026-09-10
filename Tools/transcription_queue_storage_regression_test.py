#!/usr/bin/env python3
"""Both queue owners must distinguish unreadable persistence from an empty queue."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]

def body(source, signature):
 start=source.index('{',source.index(signature));depth=0
 for end in range(start,len(source)):
  depth+=(source[end]=='{')-(source[end]=='}')
  if depth==0:return source[start+1:end]
 raise AssertionError(signature)
class StorageContracts(unittest.TestCase):
 def assertIn(self, key, value):
  self.assertTrue(key in value, "Missing storage contract: "+key)
 def test_both_queues_keep_failed_load_owned(self):
  for name in ('TranscriptionQueue.swift','ServerTranscriptionManager.swift'):
   with self.subTest(name=name):
    s=(ROOT/'Classes'/name).read_text()
    self.assertIn('queueLoadError',body(s,'private func loadPersistedQueue()'))
    self.assertIn('queueLoadError',body(s,'private func persistQueue('))
    self.assertIn('queueLoadError',body(s,'private func processNext()'))
 def test_owner_belongs_to_atomic_snapshot(self):
  s=(ROOT/'Classes/ServerTranscriptionManager.swift').read_text()
  self.assertIn('ownerClientID',s[s.index('private struct ICPersistedServerTranscriptionQueue'):s.index('private struct ICServerCancellation:')])
  self.assertIn('ownerClientID',body(s,'private func persistQueue()'))
  self.assertNotIn('UUID().uuidString',body(s,'private func clientIdentifier()'))
 def test_storage_error_is_reachable_and_retryable(self):
  q=(ROOT/'Classes/TranscriptionQueue.swift').read_text()
  ui=(ROOT/'Classes/TranscriptionQueueViewController.m').read_text()
  self.assertIn('queueStorageError',body(q,'@objc var hasVisibleItems:'))
  self.assertIn('queueStorageError',body(q,'@objc var canAddQueueItem:'))
  self.assertIn('_retryQueueStorage',ui)
 def test_external_retry_interval_is_bounded(self):
  s=(ROOT/'Classes/ServerTranscriptionManager.swift').read_text()
  self.assertIn('86400',s)
  self.assertIn('requiresExplicitRetryAfterCrash',body(s,'private func schedulePoll('))
  self.assertIn('requiresExplicitRetryAfterCrash',body(s,'private func processNext()'))
if __name__=='__main__':unittest.main()
