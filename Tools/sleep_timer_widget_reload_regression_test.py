#!/usr/bin/env python3
"""Semantic widget changes coalesce bursts without dropping a later state change."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Classes/WidgetKitHelper.swift').read_text()

def method(name):
    signature = '@objc public static func ' + name + '()'
    start = source.index(signature)
    brace = source.index('{', start)
    depth = 0
    for end in range(brace, len(source)):
        depth += (source[end] == '{') - (source[end] == '}')
        if not depth:
            return source[start:end + 1].replace('ProcessInfo.processInfo.isiOSAppOnMac', 'false')
    raise ValueError(name)

normal = method('reloadNowPlayingTimeline')
# Throttled requests are performed once when the interval ends (they used to be dropped).
helper_start = source.index('    private static func _reloadWhenIntervalEnds')
helper_brace = source.index('{', helper_start)
depth = 0
for helper_end in range(helper_brace, len(source)):
    depth += (source[helper_end] == '{') - (source[helper_end] == '}')
    if not depth:
        break
trailing = source[helper_start:helper_end + 1]
state = (method('reloadNowPlayingTimelineForStateChange')
         if 'func reloadNowPlayingTimelineForStateChange()' in source
         else normal.replace('func reloadNowPlayingTimeline()', 'func reloadNowPlayingTimelineForStateChange()'))
probe = r'''
import Foundation
enum ICWidgetConstants {static let nowPlayingWidgetKind = "NowPlaying"}
final class WidgetCenter {
    static let shared = WidgetCenter()
    var reloads = 0
    func reloadTimelines(ofKind: String) {reloads += 1}
}
final class WidgetKitHelper: NSObject {
    private static var _lastReloadNowPlaying: Date?
    private static let _minInterval: TimeInterval = 2
    private static var _stateChangeReloadPending = false
    private static var _trailingReloadKeys = Set<String>()
    TRAILING
    NORMAL
    STATE
}
WidgetKitHelper.reloadNowPlayingTimeline()
precondition(WidgetCenter.shared.reloads == 1)
for _ in 0..<20 {WidgetKitHelper.reloadNowPlayingTimelineForStateChange()}
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(WidgetCenter.shared.reloads == 2, "Latest state must survive the normal reload throttle, with bursts coalesced")
WidgetKitHelper.reloadNowPlayingTimelineForStateChange()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
precondition(WidgetCenter.shared.reloads == 3, "A later explicit cancellation must not be dropped")
WidgetKitHelper.reloadNowPlayingTimeline()
WidgetKitHelper.reloadNowPlayingTimeline()
precondition(WidgetCenter.shared.reloads == 3, "Throttled requests wait for the interval end")
RunLoop.main.run(until: Date().addingTimeInterval(2.4))
precondition(WidgetCenter.shared.reloads == 4, "A throttled request reloads once at the interval end instead of being dropped")
print("Semantic widget reload checks passed")
'''.replace('NORMAL', normal).replace('STATE', state).replace('TRAILING', trailing)
with tempfile.TemporaryDirectory(prefix='instacast-widget-reload-') as directory:
    path = Path(directory)
    file = path / 'main.swift'
    file.write_text(probe)
    subprocess.run(['xcrun', 'swiftc', str(file), '-o', str(path / 'probe')], check=True)
    subprocess.run([str(path / 'probe')], check=True)
