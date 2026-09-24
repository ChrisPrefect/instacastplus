#!/usr/bin/env python3
"""Decode running, paused and disabled timer snapshots with the production model."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
probe = r'''
import Foundation

func snapshot(paused: Bool, remaining: Double?, deadline: Date?) throws -> WNowPlaying {
    let formatter = ISO8601DateFormatter()
    var json: [String: Any] = ["isPaused": paused, "timestamp": formatter.string(from: Date())]
    if let remaining { json["sleepTimerRemaining"] = remaining }
    if let deadline { json["sleepTimerStopDate"] = formatter.string(from: deadline) }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WNowPlaying.self, from: JSONSerialization.data(withJSONObject: json))
}

func check(_ condition: Bool, _ message: String) {
    if !condition { print("FAIL: \(message)"); exit(1) }
}

let paused = try snapshot(paused: true, remaining: 1200, deadline: nil)
check(paused.hasSleepTimer, "A paused timer must remain armed in the widget")
check(paused.sleepTimerFormatted == "20:00", "Paused time must remain fixed")
// Previously exported paused snapshots may still contain an absolute deadline.
let oldPaused = try snapshot(paused: true, remaining: 1200, deadline: Date(timeIntervalSince1970: 0))
check(oldPaused.hasSleepTimer && oldPaused.sleepTimerFormatted == "20:00", "Paused state uses stored seconds")
let running = try snapshot(paused: false, remaining: 1200, deadline: Date().addingTimeInterval(1200))
check(running.hasSleepTimer, "A future deadline is active")
let expired = try snapshot(paused: false, remaining: 1200, deadline: Date(timeIntervalSince1970: 0))
check(!expired.hasSleepTimer, "Stale stored seconds cannot reactivate an expired countdown")
let off = try snapshot(paused: true, remaining: nil, deadline: nil)
check(!off.hasSleepTimer && off.sleepTimerFormatted == nil, "An off timer remains off")
print("Sleep timer widget model checks passed")
'''

with tempfile.TemporaryDirectory(prefix="instacast-sleep-widget-") as directory:
    path = Path(directory)
    main = path / "main.swift"
    main.write_text(probe)
    binary = path / "probe"
    subprocess.run(["xcrun", "swiftc", str(root / "Shared/WidgetModels.swift"), str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
