//
//  silence_trim_glitch_probe.swift
//
//  Rebuilds the audio that ICSilenceTrimPlayer actually hands to the renderer (all enqueued
//  buffers minus everything a flush removed) and checks it for glitches against an offline
//  reference made by the production compressor from the same source position. Runs on macOS
//  with the production Swift files, muted.
//
//  Failure modes this detects (not reliably audible in an E2E, and not visible in time values):
//   G1 the played stream has gaps or overlaps (PTS not contiguous inside a session)
//   G2 the played stream differs from the reference (wrong chunking, channel mix-up, lost or
//      repeated samples, decoder restart offsets) - must be sample-exact
//   G3 output depends on input chunk sizes (reference uses random chunk sizes)
//   G4 NaN/Inf or peaks above the input's own peak (overlap-add gain errors)
//   G5 pause/resume inside a shortened pause changes or loses audio, or time keeps running
//   G6 seeking into / starting inside a pause produces a click (first samples not faded in)
//   G7 seams after a level change or an automatic renderer flush produce a click (step at the
//      seam larger than the signal's own steps around it) or a dropout/repeat: after automatic
//      flushes every session must equal its reference and every restart must continue at the
//      exact source sample, also in the last unshortened hop before a pause (targeted flushes)
//
//  Build:
//    swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_glitch_probe \
//      Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
//      Classes/SilenceTrim/ICSilenceTrimPlayer.swift Tools/SilenceTrim/silence_trim_glitch_probe.swift
//  Run:
//    build/SilenceTrim/silence_trim_glitch_probe <episode.mp3> [report.json]
//

import AVFoundation
import Foundation

// MARK: Reference

struct Decoded {
    var sampleRate: Double
    var channels: Int
    var samples: [Float]
    var frames: Int { samples.count / channels }
}

/// The true audio needs exact positions: without the precise key AVAssetReader can place a
/// mid-file MP3 start one frame off. One scanned asset per file, reused for every decode.
var preciseAssets: [URL: AVURLAsset] = [:]

func decode(_ url: URL, fromSample start: Int64, seconds: Double, sampleRate: Double, channels: Int) throws -> Decoded {
    let asset = preciseAssets[url] ?? AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    preciseAssets[url] = asset
    let track = asset.tracks(withMediaType: .audio).first!
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: channels, AVSampleRateKey: sampleRate,
    ])
    reader.add(output)
    // The true audio at `start`: decoded continuously from 10 s earlier, so no decoder warm-up
    // lands in the reference (a mid-file start decodes its first ~60 ms wrongly).
    let lead = min(start, Int64(10 * sampleRate))
    if start - lead > 0 {
        reader.timeRange = CMTimeRange(start: CMTime(value: start - lead, timescale: CMTimeScale(sampleRate)), duration: .positiveInfinity)
    }
    reader.startReading()
    var samples = [Float]()
    let wanted = (Int(seconds * sampleRate) + Int(lead)) * channels
    while samples.count < wanted, let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)
        chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        samples.append(contentsOf: chunk)
    }
    reader.cancelReading()
    samples.removeFirst(min(samples.count, Int(lead) * channels))
    return Decoded(sampleRate: sampleRate, channels: channels, samples: samples)
}

/// Offline reference with random input chunk sizes (G3). Returns output and the pause plans.
func reference(_ input: Decoded, startSample: Int64, level: ICSilenceTrimLevel, outputFrames: Int, seed: UInt64, primed: Bool = false)
    -> (output: [Float], pauses: [ICSilenceCompressor.PauseRecord], mapOutput: [Int64], mapInput: [Int64]) {
    // `input` must start at the compressor's session start (one hop earlier when primed).
    let compressor = ICSilenceCompressor(sampleRate: input.sampleRate, channelCount: input.channels, parameters: level.compressorParameters!)
    compressor.recordsPauses = true
    compressor.reset(atSourceSample: startSample, primed: primed)
    var generator = seed
    func nextChunk() -> Int {
        generator = generator &* 6364136223846793005 &+ 1442695040888963407
        return 64 + Int((generator >> 33) % 9000)
    }
    var out = [Float]()
    var mapOutput = [Int64]()
    var mapInput = [Int64]()
    var position = 0
    input.samples.withUnsafeBufferPointer { all in
        while out.count < outputFrames * input.channels {
            while compressor.wantsInput && position < input.frames {
                let n = min(nextChunk(), input.frames - position)
                compressor.append(interleaved: UnsafeBufferPointer(rebasing: all[(position * input.channels)..<((position + n) * input.channels)]), frameCount: n)
                position += n
            }
            if position >= input.frames { compressor.finishInput() }
            guard let chunk = compressor.produce(maximumFrames: 4096) else {
                if compressor.isFinished || (!compressor.wantsInput && position >= input.frames) { break }
                continue
            }
            out.append(contentsOf: chunk.samples)
            for index in 0..<chunk.mapOutput.count where mapOutput.last.map({ chunk.mapOutput[index] > $0 }) ?? true {
                mapOutput.append(chunk.mapOutput[index])
                mapInput.append(chunk.mapInput[index])
            }
        }
    }
    return (out, compressor.pauseRecords, mapOutput, mapInput)
}

// MARK: Recording the player

final class Recorder: @unchecked Sendable {
    struct Segment { var pts: Int64; var samples: [Float] }
    private let lock = NSLock()
    private(set) var segments: [Segment] = []
    private(set) var seams: [Int64] = []        // flushFrom output samples (continuing timeline)
    private(set) var resets = 0
    var channels = 2
    var sampleRate: Double = 44100

    func handle(_ event: ICSilenceTrimPlayer.RenderEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .flushAll:
            segments.removeAll()
            seams.removeAll()
            resets += 1
        case .flushFrom(let time):
            // Every sample from the flush time on is gone (the automatic-flush notification names
            // the first flushed sample; explicit flushes in the player only use buffer starts).
            let cut = time.convertScale(Int32(sampleRate), method: .roundHalfAwayFromZero).value
            seams.append(cut)
            segments = segments.compactMap { segment in
                let frames = Int64(segment.samples.count / channels)
                if segment.pts >= cut { return nil }
                if segment.pts + frames <= cut { return segment }
                return Segment(pts: segment.pts, samples: Array(segment.samples[0..<(Int(cut - segment.pts) * channels)]))
            }
        case .enqueue(let buffer):
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer).convertScale(Int32(sampleRate), method: .roundHalfAwayFromZero).value
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / 4)
            samples.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            segments.append(Segment(pts: pts, samples: samples))
        }
    }

    /// The played stream in PTS order plus every discontinuity found (G1).
    func stream() -> (samples: [Float], start: Int64, gaps: [String]) {
        lock.lock(); defer { lock.unlock() }
        let ordered = segments.sorted { $0.pts < $1.pts }
        var result = [Float]()
        var gaps = [String]()
        guard let first = ordered.first else { return ([], 0, []) }
        var expected = first.pts
        for segment in ordered {
            if segment.pts != expected {
                gaps.append("expected pts \(expected), got \(segment.pts)")
            }
            result.append(contentsOf: segment.samples)
            expected = segment.pts + Int64(segment.samples.count / channels)
        }
        return (result, first.pts, gaps)
    }

    /// First recorded buffer start at or after `sample` (what the system reports as flush time).
    func firstBufferStart(atOrAfter sample: Int64) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return segments.map { $0.pts }.filter { $0 >= sample }.min()
    }

    func reset() {
        lock.lock(); segments.removeAll(); seams.removeAll(); resets = 0; lock.unlock()
    }
}

final class Delegate: NSObject, ICSilenceTrimPlayerDelegate {
    var ready = false
    var failure: Error?
    var ended = false
    func silenceTrimPlayerDidBecomeReady(_ player: ICSilenceTrimPlayer) { ready = true }
    func silenceTrimPlayer(_ player: ICSilenceTrimPlayer, didFailWithError error: Error) { failure = error }
    func silenceTrimPlayerRateDidChange(_ player: ICSilenceTrimPlayer) {}
    func silenceTrimPlayerDidPlayToEnd(_ player: ICSilenceTrimPlayer) { ended = true }
}

// MARK: Checks

var results: [[String: Any]] = []
var failed: [String] = []
func check(_ name: String, _ ok: Bool, _ detail: String) {
    print((ok ? "PASS " : "FAIL ") + name + "  " + detail)
    results.append(["name": name, "passed": ok, "detail": detail])
    if !ok { failed.append(name) }
}

func wait(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

func compare(_ played: [Float], _ ref: [Float]) -> (count: Int, maxDiff: Float, firstMismatch: Int?) {
    let n = min(played.count, ref.count)
    var maxDiff: Float = 0
    var first: Int?
    for i in 0..<n {
        let d = abs(played[i] - ref[i])
        if d > maxDiff { maxDiff = d }
        if d > 1e-5 && first == nil { first = i }
    }
    return (n, maxDiff, first)
}

/// Best constant lag (frames) of `played` against `ref` and the max difference under it.
func lagged(_ played: [Float], _ ref: [Float], channels: Int, candidates: [Int]) -> (lag: Int, maxDiff: Float, frames: Int) {
    var best = (lag: 0, maxDiff: Float.infinity, frames: 0)
    for lag in candidates {
        var maxDiff: Float = 0
        var frames = 0
        let start = max(0, -lag)
        var f = start
        while (f + 1) * channels <= played.count && (f + lag + 1) * channels <= ref.count {
            for c in 0..<channels { maxDiff = max(maxDiff, abs(played[f * channels + c] - ref[(f + lag) * channels + c])) }
            frames += 1
            f += 1
        }
        if frames > 0 && maxDiff < best.maxDiff { best = (lag, maxDiff, frames) }
    }
    return best
}

/// The instant-start decoder may deliver the audio of start±1152 labelled as `start`. Its
/// session must then equal the compressor's output for exactly that true position.
func firstSessionMatch(_ played: [Float], url: URL, start: Int64, rate: Double, channels: Int) throws -> (offset: Int64, maxDiff: Float, frames: Int) {
    var best: (offset: Int64, maxDiff: Float, frames: Int) = (0, .infinity, 0)
    for offset: Int64 in [0, 1152, -1152] {
        let input = try decode(url, fromSample: start + offset, seconds: Double(played.count / channels) / rate + 30, sampleRate: rate, channels: channels)
        let ref = reference(input, startSample: start + offset, level: .medium, outputFrames: played.count / channels + 4096, seed: 5)
        let c = compare(played, ref.output)
        if c.maxDiff < best.maxDiff { best = (offset, c.maxDiff, c.count / channels) }
    }
    return best
}

func health(_ samples: [Float], inputPeak: Float) -> (finite: Bool, peak: Float) {
    var peak: Float = 0
    for v in samples {
        if !v.isFinite { return (false, .infinity) }
        peak = max(peak, abs(v))
    }
    return (true, peak)
}

/// Step at `frame` relative to the largest step of the same stream in the 20 ms before it, and the
/// RMS of the 6 ms after the seam relative to the 6 ms before it.
func seamQuality(_ samples: [Float], frame: Int, channels: Int, sampleRate: Double) -> (stepRatio: Float, energyRatio: Float, levelDB: Float, step: Float) {
    let window = Int(0.02 * sampleRate)
    let short = Int(0.006 * sampleRate)
    guard frame > window + 1, (frame + short) * channels <= samples.count else { return (0, 1, -120, 0) }
    var seamStep: Float = 0
    var localStep: Float = 0
    for c in 0..<channels {
        seamStep = max(seamStep, abs(samples[frame * channels + c] - samples[(frame - 1) * channels + c]))
        for f in (frame - window)..<(frame - 1) {
            localStep = max(localStep, abs(samples[(f + 1) * channels + c] - samples[f * channels + c]))
        }
    }
    func rms(_ from: Int, _ to: Int) -> Float {
        var sum: Float = 0
        for f in from..<to { for c in 0..<channels { let v = samples[f * channels + c]; sum += v * v } }
        return sqrt(sum / Float(max(1, (to - from) * channels)))
    }
    let before = rms(frame - short, frame)
    let after = rms(frame, frame + short)
    let level = 20 * log10(max(before, 1e-7))
    return (seamStep / max(localStep, 1e-6), (after + 1e-7) / (before + 1e-7), level, seamStep)
}

// MARK: Main

@main
struct GlitchProbe {
    static func makePlayer(_ url: URL, level: ICSilenceTrimLevel, recorder: Recorder) -> (ICSilenceTrimPlayer, Delegate) {
        let player = ICSilenceTrimPlayer(url: url, level: level)
        let delegate = Delegate()
        player.delegate = delegate
        player.volume = 0
        player.renderEventObserver = { recorder.handle($0) }
        return (player, delegate)
    }

    static func prepare(_ player: ICSilenceTrimPlayer, _ delegate: Delegate, at time: Double) -> Bool {
        player.prepare(at: time)
        let deadline = Date().addingTimeInterval(10)
        while !delegate.ready && delegate.failure == nil && Date() < deadline { wait(0.02) }
        return delegate.ready
    }

    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let reportURL = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : nil
        let asset = AVURLAsset(url: url)
        let track = asset.tracks(withMediaType: .audio).first!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(track.formatDescriptions.first as! CMAudioFormatDescription)!.pointee
        let rate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        print("file \(url.lastPathComponent): \(rate) Hz, \(channels) ch")

        // ---- Run 1: plain playback with pause/resume inside a shortened pause (G1-G5).
        let fileDuration = CMTimeGetSeconds(asset.duration)
        let t0 = min(600.0, fileDuration * 0.25)
        let start0 = Int64((t0 * rate).rounded())
        let input0 = try decode(url, fromSample: start0, seconds: 120, sampleRate: rate, channels: channels)
        let inputPeak0 = health(input0.samples, inputPeak: 1).peak
        let ref0 = reference(input0, startSample: start0, level: .medium, outputFrames: Int(90 * rate), seed: 1)
        let ref0b = reference(input0, startSample: start0, level: .medium, outputFrames: Int(90 * rate), seed: 99)
        let chunkDiff = compare(ref0.output, ref0b.output)
        check("G3 reference independent of input chunk sizes", chunkDiff.maxDiff == 0, "compared \(chunkDiff.count / channels) frames, max diff \(chunkDiff.maxDiff)")

        let recorder = Recorder()
        recorder.channels = channels
        recorder.sampleRate = rate
        var (player, delegate) = makePlayer(url, level: .medium, recorder: recorder)
        check("setup ready at 600 s", prepare(player, delegate, at: t0), "")
        player.play()
        // Wait until the source time is inside the core of a shortened pause, then pause there.
        var cmp: (count: Int, maxDiff: Float, firstMismatch: Int?)
        let pauseTargets = ref0.pauses.filter { Double($0.coreStart) / rate > t0 + 5 && $0.rate > 1 && Double($0.coreEnd - $0.coreStart) / rate > 0.25 }
        var pausedInside = false
        var pausedAt = 0.0
        var deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            wait(0.005)
            let now = player.currentTime
            if pauseTargets.contains(where: { now * rate > Double($0.coreStart) + 0.03 * rate && now * rate < Double($0.coreEnd) - 0.03 * rate }) {
                player.pause()
                pausedAt = player.currentTime
                pausedInside = true
                break
            }
        }
        check("G5 paused while the playhead was inside a shortened pause", pausedInside, String(format: "paused at %.3f s", pausedAt))
        wait(1.5)
        let whilePaused = player.currentTime
        check("G5 time stands still while paused inside the pause", abs(whilePaused - pausedAt) < 0.002, String(format: "%.4f -> %.4f", pausedAt, whilePaused))
        player.play()
        wait(0.6)
        let afterResume = player.currentTime
        check("G5 resume continues from the paused point", afterResume > pausedAt && afterResume < pausedAt + 1.5, String(format: "%.3f -> %.3f", pausedAt, afterResume))
        // Keep playing until the precise decoder took over inside a pause (warm-up 0.5-3 s).
        deadline = Date().addingTimeInterval(40)
        while player.realignCount == 0 && Date() < deadline { wait(0.1) }
        wait(4)
        player.pause()
        wait(0.3)
        var stream = recorder.stream()
        check("G1 run 1 stream contiguous", stream.gaps.isEmpty, "\(stream.gaps.prefix(3))")
        check("G8 precise decoder took over during playback", player.realignCount == 1 && player.decodesPrecisely, "realigns \(player.realignCount)")
        if let realign = player.lastRealign {
            let seamFrame = Int(realign.output - stream.start)
            // Before the switch: the instant-start decoder may sit one MP3 frame off, otherwise exact.
            let before = Array(stream.samples[0..<(seamFrame * channels)])
            let first = try firstSessionMatch(before, url: url, start: start0, rate: rate, channels: channels)
            check("G2 first session is the exact shortening of the true audio, at most one MP3 frame off", first.maxDiff <= 1e-6 && first.frames > Int(1 * rate),
                  String(format: "decoder offset %lld frames, max diff %.2e over %d frames", first.offset, first.maxDiff, first.frames))
            let q = seamQuality(stream.samples, frame: seamFrame, channels: channels, sampleRate: rate)
            check("G8 the switch happens inside a pause without a click", q.levelDB < -30 && q.stepRatio <= 1.5,
                  String(format: "level %.0f dB, step x%.2f, energy x%.2f", q.levelDB, q.stepRatio, q.energyRatio))
            // After the switch: sample-exact true audio (primed restart at the switch point).
            let hop = ICSilenceCompressor.hopLength(sampleRate: rate)
            let inputR = try decode(url, fromSample: realign.source - Int64(hop), seconds: 30, sampleRate: rate, channels: channels)
            let refR = reference(inputR, startSample: realign.source, level: .medium, outputFrames: Int(20 * rate), seed: 3, primed: true)
            let after = Array(stream.samples[(seamFrame * channels)...])
            cmp = compare(after, refR.output)
            check("G2 after the switch the played audio equals the true audio", cmp.maxDiff <= 1e-6 && cmp.count / channels > Int(2 * rate),
                  String(format: "%d frames, max diff %.2e", cmp.count / channels, cmp.maxDiff))
        }
        var hl = health(stream.samples, inputPeak: inputPeak0)
        check("G4 run 1 finite, no gain above the input peak", hl.finite && hl.peak <= inputPeak0 + 1e-4, String(format: "peak %.4f, input peak %.4f", hl.peak, inputPeak0))
        player.invalidate()

        // ---- Run 2: seek into the middle of a long pause (G6) and Run 3: start inside it.
        guard let long = ref0.pauses.first(where: { Double($0.coreEnd - $0.coreStart) / rate > 0.6 && Double($0.coreStart) / rate > t0 + 3 }) else {
            check("G6 a long pause exists in the fixture", false, ""); return
        }
        let tp = Double(long.coreStart) / rate + 0.25
        let startP = Int64((tp * rate).rounded())
        let inputP = try decode(url, fromSample: startP, seconds: 60, sampleRate: rate, channels: channels)
        let refP = reference(inputP, startSample: startP, level: .medium, outputFrames: Int(40 * rate), seed: 7)
        for (label, viaSeek) in [("seek into pause", true), ("start inside pause", false)] {
            recorder.reset()
            (player, delegate) = makePlayer(url, level: .medium, recorder: recorder)
            _ = prepare(player, delegate, at: viaSeek ? t0 : tp)
            if viaSeek {
                player.play()
                let ready = Date().addingTimeInterval(20)
                while !player.hasPreciseDecoder && Date() < ready { wait(0.05) }
                var done = false
                player.seek(to: tp) { _ in done = true }
                while !done { wait(0.01) }
                // The seek's flushAll already cleared the old session in the recorder.
            } else {
                player.play()
            }
            wait(8)
            player.pause()
            wait(0.2)
            stream = recorder.stream()
            check("G1 \(label): stream contiguous", stream.gaps.isEmpty, "\(stream.gaps.prefix(3))")
            if viaSeek {
                cmp = compare(stream.samples, refP.output)
                check("G2 seek with the precise decoder lands sample-exactly on the true audio", cmp.maxDiff <= 1e-6 && cmp.count / channels > Int(5 * rate),
                      String(format: "%d frames, max diff %.2e, precise %@", cmp.count / channels, cmp.maxDiff, player.decodesPrecisely ? "yes" : "no"))
            } else {
                let seamFrame = player.lastRealign.map { Int($0.output - stream.start) } ?? stream.samples.count / channels
                let before = Array(stream.samples[0..<(seamFrame * channels)])
                let first = try firstSessionMatch(before, url: url, start: startP, rate: rate, channels: channels)
                check("G2 instant start inside a pause is the exact shortening of the true audio, at most one MP3 frame off",
                      first.maxDiff <= 1e-6 && first.frames > Int(1 * rate),
                      String(format: "decoder offset %lld frames, max diff %.2e over %d frames, realigned %d", first.offset, first.maxDiff, first.frames, player.realignCount))
                if let realign = player.lastRealign {
                    let hop = ICSilenceCompressor.hopLength(sampleRate: rate)
                    let inputR = try decode(url, fromSample: realign.source - Int64(hop), seconds: 30, sampleRate: rate, channels: channels)
                    let refR = reference(inputR, startSample: realign.source, level: .medium, outputFrames: Int(20 * rate), seed: 4, primed: true)
                    let c = compare(Array(stream.samples[(seamFrame * channels)...]), refR.output)
                    check("G2 instant start: after the switch the audio equals the true audio", c.maxDiff <= 1e-6 && c.count / channels > Int(rate),
                          String(format: "%d frames, max diff %.2e", c.count / channels, c.maxDiff))
                    let q = seamQuality(stream.samples, frame: seamFrame, channels: channels, sampleRate: rate)
                    check("G8 instant start: switch inside a pause without a click", q.levelDB < -30 && q.stepRatio <= 1.5,
                          String(format: "level %.0f dB, step x%.2f", q.levelDB, q.stepRatio))
                }
            }
            // A session starts with a 5.8 ms fade-in: the first sample must be near zero.
            let firstPeak = stream.samples.prefix(channels * 8).map { abs($0) }.max() ?? 0
            check("G6 \(label): no click at the start (fade-in)", firstPeak < 0.01, String(format: "first samples peak %.5f", firstPeak))
            hl = health(stream.samples, inputPeak: inputPeak0)
            check("G4 \(label): finite, bounded", hl.finite && hl.peak <= max(inputPeak0, health(inputP.samples, inputPeak: 1).peak) + 1e-4, String(format: "peak %.4f", hl.peak))
            player.invalidate()
        }

        // ---- Run 4: level changes during playback (partial flush at the next pause) (G7).
        recorder.reset()
        (player, delegate) = makePlayer(url, level: .medium, recorder: recorder)
        _ = prepare(player, delegate, at: fileDuration * 0.5)
        player.play()
        var levels: [ICSilenceTrimLevel] = [.strong, .mild, .medium, .strong, .mild, .medium, .strong, .medium]
        for next in levels {
            wait(2.5)
            player.level = next
        }
        wait(4)
        player.pause()
        wait(0.3)
        stream = recorder.stream()
        check("G1 level changes: stream contiguous", stream.gaps.isEmpty, "\(stream.gaps.prefix(3))")
        var seamReports = [String]()
        var worstStep: Float = 0
        var worstNotch: Float = 1
        for seam in recorder.seams {
            let frame = Int(seam - stream.start)
            let q = seamQuality(stream.samples, frame: frame, channels: channels, sampleRate: rate)
            seamReports.append(String(format: "@%.2fs step x%.2f (%.4f) energy x%.2f level %.0f dB", Double(seam) / rate, q.stepRatio, q.step, q.energyRatio, q.levelDB))
            worstStep = max(worstStep, q.stepRatio)
            worstNotch = min(worstNotch, q.energyRatio)
        }
        print("  level-change seams: \(recorder.seams.count) \(seamReports)")
        // Locally the renderer refuses partial flushes (it already took the ~1.5 s it asked for);
        // the new level then follows that audio. Every change must end in one of the two.
        check("G7 each level change either cut at a buffer start or was refused cleanly",
              recorder.seams.count + player.partialFlushRefusals == levels.count,
              "seams \(recorder.seams.count), refused \(player.partialFlushRefusals), changes \(levels.count)")
        check("G7 level-change seams have no click (step within the signal's own steps)", worstStep <= 1.5,
              "seams \(recorder.seams.count), worst step ratio \(worstStep)")
        check("G7 level-change seams have no dropout", worstNotch >= 0.5, "lowest energy ratio \(worstNotch)")
        hl = health(stream.samples, inputPeak: 1)
        check("G4 level changes: finite", hl.finite, String(format: "peak %.4f", hl.peak))
        player.invalidate()

        // ---- Run 5: automatic flushes as AirPlay does them (G7), mid-speech and mid-pause.
        recorder.reset()
        (player, delegate) = makePlayer(url, level: .medium, recorder: recorder)
        _ = prepare(player, delegate, at: fileDuration * 0.7)
        player.play()
        let warm = Date().addingTimeInterval(20)
        while !player.decodesPrecisely && Date() < warm { wait(0.05) }
        check("G8 run 5 decodes precisely before the flushes", player.decodesPrecisely, "realigns \(player.realignCount)")
        let hop = ICSilenceCompressor.hopLength(sampleRate: rate)
        let flushCount = 8
        var targetedFlushes = 0
        for n in 0..<flushCount {
            wait(2.2)
            // What the system does: flush from a time slightly ahead, then notify. The real
            // renderer cannot be made to flush mid-buffer (it refuses partial flushes of audio it
            // already took), so this checks the player's restart against the documented semantics.
            let now = player.renderer.timebase.time
            var at = CMTimeAdd(now, CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(rate)))
            if n % 2 == 1, let session = player.automaticFlushRestarts.last ?? player.lastRealign {
                // Every second flush hits the hardest case for the source lookup: the middle of
                // the last unshortened hop in front of a shortened pause.
                let nowSample = now.convertScale(Int32(rate), method: .roundHalfAwayFromZero).value
                let from = nowSample + Int64(0.35 * rate) - session.output
                let to = nowSample + Int64(1.2 * rate) - session.output
                let input = try decode(url, fromSample: session.source - Int64(hop), seconds: Double(to) / rate * 4 + 10, sampleRate: rate, channels: channels)
                let ref = reference(input, startSample: session.source, level: .medium, outputFrames: Int(to) + 4096, seed: 40 + UInt64(n), primed: true)
                let candidates = ref.mapOutput.count > 2 ? Array(1..<(ref.mapOutput.count - 1)) : []
                if let k = candidates.first(where: { ref.mapOutput[$0] >= from && ref.mapOutput[$0] < to
                    && ref.mapInput[$0] - ref.mapInput[$0 - 1] == Int64(hop) && ref.mapInput[$0 + 1] - ref.mapInput[$0] > Int64(hop) }) {
                    let target = session.output + ref.mapOutput[k] + Int64(hop / 2)
                    let stillAhead = player.renderer.timebase.time.convertScale(Int32(rate), method: .roundHalfAwayFromZero).value + Int64(0.1 * rate)
                    if target > stillAhead {
                        at = CMTime(value: target, timescale: CMTimeScale(rate))
                        targetedFlushes += 1
                    }
                }
            }
            NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: player.renderer,
                                            userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: at)])
        }
        wait(3)
        player.pause()
        wait(0.3)
        stream = recorder.stream()
        check("G1 automatic flushes: stream contiguous", stream.gaps.isEmpty, "\(stream.gaps.prefix(3))")
        seamReports = []
        worstStep = 0
        for seam in recorder.seams {
            let frame = Int(seam - stream.start)
            let q = seamQuality(stream.samples, frame: frame, channels: channels, sampleRate: rate)
            seamReports.append(String(format: "@%.2fs step x%.2f (%.4f) energy x%.2f level %.0f dB", Double(seam) / rate, q.stepRatio, q.step, q.energyRatio, q.levelDB))
            worstStep = max(worstStep, q.stepRatio)
        }
        print("  automatic-flush seams: \(seamReports)")
        // Dropouts and repeats, sample-exactly. Each session (from the switch to the precise
        // decoder on) must play exactly the offline reference from where it started, and each
        // restart must continue at the source sample that reference plays at the flush point.
        // In unshortened audio that is the continuation without a lost or repeated sample.
        var sessions: [(output: Int64, source: Int64)] = []
        if let realign = player.lastRealign { sessions.append(realign) }
        sessions.append(contentsOf: player.automaticFlushRestarts)
        let streamEnd = stream.start + Int64(stream.samples.count / channels)
        var exactSessions = 0
        var exactRestarts = 0
        var unshortenedSeams = 0
        var boundarySeams = 0
        var sessionProblems = [String]()
        var restartProblems = [String]()
        for (i, session) in sessions.enumerated() {
            let end = i + 1 < sessions.count ? sessions[i + 1].output : streamEnd
            let frames = Int(end - session.output)
            let first = Int(session.output - stream.start)
            guard first >= 0, frames > 0 else { sessionProblems.append("session \(i) outside the stream"); continue }
            let input = try decode(url, fromSample: session.source - Int64(hop), seconds: Double(frames) / rate * 4 + 10, sampleRate: rate, channels: channels)
            let ref = reference(input, startSample: session.source, level: .medium, outputFrames: frames + 4096, seed: 60 + UInt64(i), primed: true)
            let played = compare(Array(stream.samples[(first * channels)..<((first + frames) * channels)]), ref.output)
            if played.maxDiff <= 1e-6 && played.count / channels == frames {
                exactSessions += 1
            } else {
                sessionProblems.append(String(format: "session %d: %d of %d frames, max diff %.2e", i, played.count / channels, frames, played.maxDiff))
            }
            guard i + 1 < sessions.count, let k = ref.mapOutput.lastIndex(where: { $0 <= Int64(frames) }), k > 0 else { continue }
            let expected = ref.mapInput[k] + (Int64(frames) - ref.mapOutput[k])
            let unshortened = ref.mapInput[k] - ref.mapInput[k - 1] == Int64(hop)
            if unshortened { unshortenedSeams += 1 }
            if unshortened && k + 1 < ref.mapInput.count && ref.mapInput[k + 1] - ref.mapInput[k] > Int64(hop) { boundarySeams += 1 }
            if sessions[i + 1].source == expected {
                exactRestarts += 1
            } else {
                restartProblems.append("restart \(i + 1): source \(sessions[i + 1].source), the audio playing there is \(expected) (\(unshortened ? "unshortened" : "shortened") hop)")
            }
        }
        print("  sessions \(sessions.count), seams in unshortened audio \(unshortenedSeams), of them in the last hop before a pause \(boundarySeams), targeted \(targetedFlushes)")
        check("G7 every session after an automatic flush plays exactly the true audio", exactSessions == sessions.count && sessions.count == flushCount + 1,
              "\(exactSessions) of \(sessions.count) sessions exact \(sessionProblems.prefix(3))")
        check("G7 every automatic flush continues at the exact source sample (no dropout, no repeat)", exactRestarts == flushCount,
              "\(exactRestarts) of \(flushCount) restarts exact, \(unshortenedSeams) in unshortened audio \(restartProblems.prefix(3))")
        check("G7 the flushes covered the last hop before a shortened pause", boundarySeams >= 1, "\(boundarySeams) seams")
        // A click needs a step that is large for the local signal and large in absolute terms;
        // inside shortened pauses the room tone is below -40 dB and its joins are inaudible.
        var audibleClicks = 0
        for seam in recorder.seams {
            let q = seamQuality(stream.samples, frame: Int(seam - stream.start), channels: channels, sampleRate: rate)
            if q.stepRatio > 1.5 && q.step > 0.01 { audibleClicks += 1 }
        }
        check("G7 automatic-flush seams have no click", audibleClicks == 0, "seams \(recorder.seams.count), worst step ratio \(worstStep), audible clicks \(audibleClicks)")
        check("automatic flushes were handled", player.automaticFlushCount == flushCount, "\(player.automaticFlushCount)")
        player.invalidate()
        levels = []

        if let reportURL {
            let data = try JSONSerialization.data(withJSONObject: ["file": url.lastPathComponent, "results": results], options: [.prettyPrinted])
            try data.write(to: reportURL)
        }
        print(failed.isEmpty ? "GLITCH PROBE PASSED (\(results.count) checks)" : "GLITCH PROBE FAILED: \(failed)")
        exit(failed.isEmpty ? 0 : 1)
    }
}
