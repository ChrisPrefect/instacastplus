//
//  silence_trim_player_probe.swift
//
//  Drives the production ICSilenceTrimPlayer on macOS against a real episode (muted) and checks
//  the timing contract the app relies on. Failure modes it detects:
//   P1 never ready / failure callback for a valid file
//   P2 source time does not advance faster than wall time at medium level (no shortening)
//   P3 source time runs away (advances more than the strongest possible speed-up allows)
//   P4 seek does not land at the requested source time
//   P5 speed change is not applied (source advance must scale with the rate)
//   P6 level change mid-stream breaks playback (time stops or jumps backwards)
//   P7 end of file does not report didPlayToEnd
//
//  Build:
//    swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_player_probe \
//      Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
//      Classes/SilenceTrim/ICSilenceTrimPlayer.swift Classes/SilenceTrim/ICSilenceTrimHTTPSource.swift \
//      Classes/SilenceTrim/ICSileroVAD.swift Tools/SilenceTrim/silence_trim_player_probe.swift
//

import Foundation
import AVFoundation

final class ProbeDelegate: NSObject, ICSilenceTrimPlayerDelegate {
    var ready = false
    var ended = false
    var failure: Error?
    var rateChanges = 0
    func silenceTrimPlayerDidBecomeReady(_ player: ICSilenceTrimPlayer) { ready = true }
    func silenceTrimPlayer(_ player: ICSilenceTrimPlayer, didFailWithError error: Error) { failure = error }
    func silenceTrimPlayerRateDidChange(_ player: ICSilenceTrimPlayer) { rateChanges += 1 }
    func silenceTrimPlayerDidPlayToEnd(_ player: ICSilenceTrimPlayer) { ended = true }
}

@main
struct Probe {
    static func wait(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func main() {
        let path = CommandLine.arguments.dropFirst().first ?? ""
        let player = ICSilenceTrimPlayer(url: URL(fileURLWithPath: path), level: .medium)
        let delegate = ProbeDelegate()
        player.delegate = delegate
        player.volume = 0
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print((ok ? "PASS " : "FAIL ") + label)
            if !ok { failures.append(label) }
        }

        player.prepare(at: 600)
        let readyDeadline = Date().addingTimeInterval(10)
        while !delegate.ready && delegate.failure == nil && Date() < readyDeadline { wait(0.05) }
        check(delegate.ready && delegate.failure == nil, "P1 ready (duration \(player.duration), error \(String(describing: delegate.failure)))")
        guard delegate.ready else { exit(1) }

        let t0 = player.currentTime
        check(abs(t0 - 600) < 0.5, String(format: "P4 prepared position %.2f ~ 600", t0))
        player.play()
        let wall0 = Date()
        wait(12)
        let t1 = player.currentTime
        let wall1 = Date().timeIntervalSince(wall0)
        let advance = t1 - t0
        print(String(format: "  played %.2f s wall, source advanced %.2f s, saved %.2f s, factor %.3f", wall1, advance, player.savedSeconds, player.pauseSpeedupFactor))
        check(advance > wall1 * 1.01, "P2 shortening at medium level (advance > wall)")
        check(advance < wall1 * 3.5 + 0.5, "P3 advance within bounds")

        var seekDone = false
        player.seek(to: 3000) { _ in seekDone = true }
        while !seekDone { wait(0.02) }
        wait(0.3)
        let t2 = player.currentTime
        check(t2 >= 2999.5 && t2 < 3002, String(format: "P4 seek landed at %.2f", t2))
        wait(3)
        let t3 = player.currentTime
        print(String(format: "  after seek: %.2f -> %.2f", t2, t3))

        player.requestedRate = 1.5
        let t4 = player.currentTime
        let wall4 = Date()
        wait(6)
        let advance15 = player.currentTime - t4
        let wall15 = Date().timeIntervalSince(wall4)
        print(String(format: "  rate 1.5: %.2f s wall, source %.2f s, automatic flushes so far %d", wall15, advance15, player.automaticFlushCount))
        check(advance15 > wall15 * 1.45, "P5 speed 1.5 applied")

        player.requestedRate = 1.0
        player.level = .strong
        var previous = player.currentTime
        var monotonic = true
        for _ in 0..<40 {
            wait(0.25)
            let now = player.currentTime
            if now < previous - 0.05 { monotonic = false }
            previous = now
        }
        print(String(format: "  after level change: %.2f s, saved %.2f s, factor %.3f", previous, player.savedSeconds, player.pauseSpeedupFactor))
        check(monotonic && previous > t4 + advance15 + 8, "P6 level change keeps time running")

        let duration = player.duration
        seekDone = false
        player.seek(to: duration - 6) { _ in seekDone = true }
        while !seekDone { wait(0.02) }
        let endDeadline = Date().addingTimeInterval(12)
        while !delegate.ended && Date() < endDeadline { wait(0.1) }
        check(delegate.ended, String(format: "P7 end reported (time %.2f of %.2f)", player.currentTime, duration))
        check(delegate.failure == nil, "no failure (\(String(describing: delegate.failure)))")
        player.invalidate()
        print("automatic renderer flushes handled: \(player.automaticFlushCount)")
        print(failures.isEmpty ? "PROBE PASSED" : "PROBE FAILED: \(failures)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
