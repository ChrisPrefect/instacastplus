#!/usr/bin/env python3
"""Pin the durable device-source contract before every POST, including replay."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root/'Classes/ServerTranscriptionManager.swift').read_text()
submit = source.split('private func submitEpisode(',1)[1].split('private func fetchEpisode(',1)[0]
assert '"client_audio_sha256": audioSHA256' in submit, 'POST omits the device audio identity'
assert submit.index('submissionAudioSHA256') < submit.index('method: "POST"')
prepare = source.split('private func submissionAudioSHA256(',1)[1].split('private func fetchEpisode(',1)[0]
assert prepare.index('ICAudioIdentity.sha256') < prepare.index('persistQueue()') < prepare.index('awaitQueuePersistence()')
assert 'importAudioIsCurrent' in prepare and 'existing != actual' in prepare
assert source.count('sourceAudioSHA256ByItem') >= 6, 'Source identity must survive restart and be cleared for a new request'
print('Audio identity is measured, persisted and revalidated before POST/replay')
