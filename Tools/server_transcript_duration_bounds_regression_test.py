#!/usr/bin/env python3
from pathlib import Path
s=(Path(__file__).resolve().parents[1]/'Classes/ServerTranscriptionManager.swift').read_text()
def body(signature):
 start=s.index(signature);brace=s.index('{',start);depth=0
 for end in range(brace,len(s)):
  depth+=(s[end]=='{')-(s[end]=='}')
  if not depth:return s[start:end+1]
 raise AssertionError(signature)
validation=body('private func validateDownloadedArtifacts(')
imports=body('private func importArtifacts(')
assert 'try self.validateServerTranscriptBounds(cues, serverDuration: serverDuration)' in validation, 'A validly formatted SRT can currently extend beyond measured audio duration and be committed'
assert validation.index('validateServerSRTData') < validation.index('validateServerTranscriptBounds(cues') < validation.index('return (cues,')
assert imports.index('try await validateDownloadedArtifacts(') < imports.index('saveValidatedServerSRTData')
print('Server transcript duration guard precedes all artifact writes')
