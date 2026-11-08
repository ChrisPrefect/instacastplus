#!/usr/bin/env python3
"""Exhaust the production playback reducer's state/event contract.

Failure analysis: unknown events/states, Play/Ready after Close or Failure,
Pause leaving initialization, Ready overwriting the latest intent, and
rate callbacks advancing an unopened item. The simulator E2E reproduces the
loading bug; exhaustive invalid event permutations cannot be driven reliably
through asynchronous AVFoundation callbacks, so this boundary is also isolated.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
s = (ROOT / 'Classes/PlaybackManager.m').read_text()
start = s.index('typedef NS_ENUM(NSInteger, ICPlaybackState)')
end = s.index('\n#if TARGET_OS_IPHONE', start)
types_and_reducer = s[start:end]
test = r'''
#import <Foundation/Foundation.h>
REDUCER
int main(void) {
    NSArray *states = @[@(IdleState), @(InitializedState), @(LoadingPausedState),
        @(ShouldRunState), @(RunningState), @(PausedState), @(FailedState)];
    // Expected successful edges, written as the externally meaningful event contract.
    NSArray *contract = @[
        @[@(IdleState), @(ICPlaybackEventOpenPlaying), @(InitializedState)],
        @[@(IdleState), @(ICPlaybackEventOpenPaused), @(LoadingPausedState)],
        @[@(IdleState), @(ICPlaybackEventPause), @(IdleState)],
        @[@(InitializedState), @(ICPlaybackEventReady), @(ShouldRunState)],
        @[@(InitializedState), @(ICPlaybackEventPlay), @(InitializedState)],
        @[@(InitializedState), @(ICPlaybackEventPause), @(LoadingPausedState)],
        @[@(ShouldRunState), @(ICPlaybackEventPlay), @(ShouldRunState)],
        @[@(ShouldRunState), @(ICPlaybackEventPause), @(PausedState)],
        @[@(ShouldRunState), @(ICPlaybackEventStarted), @(RunningState)],
        @[@(RunningState), @(ICPlaybackEventPlay), @(RunningState)],
        @[@(RunningState), @(ICPlaybackEventPause), @(PausedState)],
        @[@(RunningState), @(ICPlaybackEventStarted), @(RunningState)],
        @[@(RunningState), @(ICPlaybackEventStopped), @(PausedState)],
        @[@(PausedState), @(ICPlaybackEventPlay), @(ShouldRunState)],
        @[@(PausedState), @(ICPlaybackEventPause), @(PausedState)],
        @[@(PausedState), @(ICPlaybackEventStarted), @(RunningState)],
        @[@(PausedState), @(ICPlaybackEventStopped), @(PausedState)],
        @[@(LoadingPausedState), @(ICPlaybackEventReady), @(PausedState)],
        @[@(LoadingPausedState), @(ICPlaybackEventPlay), @(InitializedState)],
        @[@(LoadingPausedState), @(ICPlaybackEventPause), @(LoadingPausedState)],
        @[@(FailedState), @(ICPlaybackEventOpenPlaying), @(InitializedState)],
        @[@(FailedState), @(ICPlaybackEventOpenPaused), @(LoadingPausedState)],
        @[@(FailedState), @(ICPlaybackEventPause), @(FailedState)],
    ];
    NSMutableDictionary *edges = [NSMutableDictionary dictionary];
    for (NSArray *edge in contract) edges[[NSString stringWithFormat:@"%@:%@", edge[0], edge[1]]] = edge[2];
    int failures = 0;
    for (NSNumber *state in states) for (NSInteger event = 0; event <= ICPlaybackEventFail; event++) {
        ICPlaybackState next = (ICPlaybackState)999;
        NSNumber *expected = edges[[NSString stringWithFormat:@"%ld:%ld", state.integerValue, event]];
        if (event == ICPlaybackEventClose) expected = @(IdleState);
        if (event == ICPlaybackEventFail && state.integerValue != IdleState && state.integerValue != FailedState) expected = @(FailedState);
        BOOL accepted = ICPlaybackNextState(state.integerValue, event, &next);
        if (accepted != (expected != nil) || (accepted && next != expected.integerValue)) {
            NSLog(@"FAIL state=%@ event=%ld accepted=%d next=%ld expected=%@",state,event,accepted,next,expected);
            failures++;
        }
    }
    ICPlaybackState next = IdleState;
    if (ICPlaybackNextState(999, ICPlaybackEventClose, &next) || ICPlaybackNextState(IdleState, 999, &next)) failures++;
    if (failures) return 1;
    puts("PASS: all 63 state/event pairs and unknown values obey the production playback transition contract");
    return 0;
}
'''.replace('REDUCER', types_and_reducer)
with tempfile.TemporaryDirectory(prefix='instacast-playback-state-') as directory:
    p = Path(directory)
    (p / 'main.m').write_text(test)
    subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', str(p / 'main.m'), '-o', str(p / 'test')], check=True)
    subprocess.run([str(p / 'test')], check=True)
