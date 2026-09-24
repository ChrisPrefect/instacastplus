#!/usr/bin/env python3
"""Ensure overnight playback diagnostics explain timer resets and skipped end checks."""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
audio = (root / 'Classes/AudioSession.m').read_text()
app = (root / 'Classes/Application.m').read_text()
player = (root / 'Classes/PlaybackManager.m').read_text()
def body(source, signature):
    return source.split(signature, 1)[1].split('\n- (', 1)[0]
assert 'logEvent:@"sleep-timer"' in audio, 'Missing sleep-timer lifecycle diagnostics'
for key in ['timerValue', 'timerValid', 'stopDate', 'lastTimerTick', 'alwaysActive', 'intelligentActive', 'touchEnabled', 'motionEnabled', 'volumeEnabled', 'motionThreshold', 'carPlayConnected', 'defaultMinutes', 'lastSelectedMinutes', 'uncompletedSeconds', 'touchResetCount', 'motionResetCount', 'volumeResetCount', 'lastResetDate', 'lastResetReason']:
    assert f'@"{key}"' in audio, f'Missing timer evidence: {key}'
for signature in ['- (void) setTimerValue:', '- (void)setTimerWithDuration:']:
    assert '_logSleepTimerEvent:' in body(audio, signature), f'Missing applied timer configuration: {signature}'
expiry = body(audio, '- (void)stopPlaybackTimer:')
assert expiry.index('@"expired"') < expiry.index('[[PlaybackManager playbackManager] pause]') < expiry.index('@"pause-completed"')
assert 'self.lastSleepTimerTick = ' in expiry
for reason in ['touch', 'motion', 'volume']:
    assert f'_resetSleepTimerForActivity:@"{reason}"' in app, f'Missing {reason} activity source'
assert '[session resetSleepTimerForActivity:reason]' in body(app, '- (void)_resetSleepTimerForActivity:')
assert '_logSleepTimerEvent:reason' in body(audio, '- (void)resetSleepTimerForActivity:')
assert '30.0' in body(audio, '- (void)_logSleepTimerEvent:'), 'Repeated sensor resets must not flood the log'
assert 'sleepTimerDiagnosticsMetadata' in body(player, '- (void)_logBackgroundPlaybackCheckpointIfNeeded'), 'Background playback must expose inactive/stalled timers too'
metadata = body(player, '- (NSMutableDictionary*)_playbackDiagnosticsMetadataForEpisode:')
for key in ['feedSkipEndPeriod', 'globalSkipEndPeriod', 'skipEndPeriod', 'canPerformAutomaticSkip']:
    assert f'@"{key}"' in metadata, f'Missing end-skip eligibility: {key}'
print('Sleep timer and end-skip diagnostics contracts passed')
