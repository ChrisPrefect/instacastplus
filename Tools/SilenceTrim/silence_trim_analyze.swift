//
//  silence_trim_analyze.swift
//
//  Offline harness for Classes/SilenceTrim/ICSilenceCompressor.swift. It decodes a real episode
//  with AVAssetReader (the same decoder the player uses), runs the production compressor for
//  every level and reports the measured result: time saved, pause statistics, processing speed,
//  and optionally the processed audio as WAV for listening.
//
//  For comparison it also replays Pocket Casts' published trim-silence rules
//  (AudioReadTask.swift, MPL-2.0: RMS per 1152-frame block, fixed thresholds, re-inserted blocks)
//  on the same decoded samples.
//
//  Build:
//    swiftc -O -parse-as-library -o build/SilenceTrim/silence_trim_analyze \
//      Classes/SilenceTrim/ICSilenceCompressor.swift Classes/SilenceTrim/ICSilenceTrimLevel.swift \
//      Tools/SilenceTrim/silence_trim_analyze.swift
//  Run:
//    build/SilenceTrim/silence_trim_analyze <audio file> [--wav-dir <dir>] [--json <file>] [--seconds <n>]
//

import Foundation
import AVFoundation

struct DecodedAudio {
    var sampleRate: Double
    var channels: Int
    var samples: [Float]   // interleaved
    var frames: Int { samples.count / channels }
}

func decode(url: URL, maximumSeconds: Double?, startSeconds: Double = 0) throws -> DecodedAudio {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
        throw NSError(domain: "analyze", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio track"])
    }
    let description = track.formatDescriptions.first.map { $0 as! CMAudioFormatDescription }
    let asbd = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    let sourceChannels = Int(asbd?.mChannelsPerFrame ?? 2)
    let channels = min(max(sourceChannels, 1), 2)
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        AVNumberOfChannelsKey: channels,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    if maximumSeconds != nil || startSeconds > 0 {
        reader.timeRange = CMTimeRange(start: CMTime(seconds: startSeconds, preferredTimescale: 1000),
                                       duration: maximumSeconds.map { CMTime(seconds: $0, preferredTimescale: 1000) } ?? .positiveInfinity)
    }
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "analyze", code: 2) }
    var samples = [Float]()
    var sampleRate = asbd?.mSampleRate ?? 44100
    while let buffer = output.copyNextSampleBuffer() {
        if let fd = CMSampleBufferGetFormatDescription(buffer),
           let b = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee {
            sampleRate = b.mSampleRate
        }
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / 4)
        chunk.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        samples.append(contentsOf: chunk)
    }
    if reader.status == .failed { throw reader.error ?? NSError(domain: "analyze", code: 3) }
    return DecodedAudio(sampleRate: sampleRate, channels: channels, samples: samples)
}

struct LevelResult {
    var name: String
    var inputSeconds: Double
    var outputSeconds: Double
    var compressedPauses: Int
    var processingSeconds: Double
    var output: [Float]
    var records: [ICSilenceCompressor.PauseRecord]
    var runLengths: [Double]
    var detector: String
    var mapOutput: [Int64]
    var mapInput: [Int64]
    var hop: Int
}

func run(level name: String, parameters: ICSilenceCompressor.Parameters, audio: DecodedAudio, keepOutput: Bool, thresholdRatio: Float? = nil, relativeDB: Float? = nil) -> LevelResult {
    let compressor = ICSilenceCompressor(sampleRate: audio.sampleRate, channelCount: audio.channels, parameters: parameters)
    if let thresholdRatio { compressor.thresholdRatio = thresholdRatio }
    if let relativeDB { compressor.relativeSilenceDB = relativeDB }
    compressor.recordsPauses = true
    var output = [Float]()
    if keepOutput { output.reserveCapacity(audio.samples.count) }
    let chunkFrames = 4096
    var position = 0
    let start = Date()
    var producedFrames = 0
    var mapOutput = [Int64]()
    var mapInput = [Int64]()
    audio.samples.withUnsafeBufferPointer { all in
        while true {
            while compressor.wantsInput && position < audio.frames {
                let n = min(chunkFrames, audio.frames - position)
                let slice = UnsafeBufferPointer(rebasing: all[(position * audio.channels)..<((position + n) * audio.channels)])
                compressor.append(interleaved: slice, frameCount: n)
                position += n
            }
            if position >= audio.frames { compressor.finishInput() }
            if let chunk = compressor.produce(maximumFrames: 8192) {
                producedFrames += chunk.frameCount
                if keepOutput {
                    output.append(contentsOf: chunk.samples)
                    // Per-hop points; the closing point of a chunk repeats as the next chunk's first.
                    mapOutput.append(contentsOf: chunk.mapOutput.dropLast())
                    mapInput.append(contentsOf: chunk.mapInput.dropLast())
                }
                continue
            }
            if compressor.isFinished { break }
            if !compressor.wantsInput && position >= audio.frames && !compressor.isFinished {
                // Defensive: no progress possible.
                FileHandle.standardError.write("stalled at frame \(position)\n".data(using: .utf8)!)
                break
            }
        }
    }
    let elapsed = Date().timeIntervalSince(start)
    return LevelResult(name: name,
                       inputSeconds: Double(audio.frames) / audio.sampleRate,
                       outputSeconds: Double(producedFrames) / audio.sampleRate,
                       compressedPauses: compressor.compressedPauseCount,
                       processingSeconds: elapsed,
                       output: output,
                       records: compressor.pauseRecords,
                       runLengths: compressor.silentRunLengths,
                       detector: String(format: "floor %.1f dB, speech %.1f dB, threshold %.1f dB, silent %.1f %%",
                                        compressor.diagnosticFloorSum / Double(max(compressor.diagnosticFrames, 1)),
                                        compressor.diagnosticSpeechSum / Double(max(compressor.diagnosticFrames, 1)),
                                        compressor.diagnosticThresholdSum / Double(max(compressor.diagnosticFrames, 1)),
                                        100 * Double(compressor.diagnosticSilentFrames) / Double(max(compressor.diagnosticFrames, 1))),
                       mapOutput: mapOutput,
                       mapInput: mapInput,
                       hop: compressor.hop)
}

/// Pocket Casts' rules from AudioReadTask.swift, replayed on the decoded samples.
func pocketCastsSaving(audio: DecodedAudio, minGap: Int, reinsert: Int, minRMS: Float) -> Double {
    let block = 1152
    let blocks = audio.frames / block
    let totalSeconds = Double(audio.frames) / audio.sampleRate
    var removedBlocks = 0
    var gap = 0
    func endGap() {
        if gap >= minGap {
            // reinsert + 1 faded block are kept (loop 0...amountOfSilentFramesToReInsert).
            let kept = min(gap, reinsert + 1)
            removedBlocks += gap - kept
        }
        gap = 0
    }
    for b in 0..<blocks {
        let t = Double((b + 1) * block) / audio.sampleRate
        var rms: Float = 1
        if totalSeconds - t > 5 {
            var sum: Float = 0
            let base = b * block * audio.channels
            for i in 0..<(block * audio.channels) {
                let v = audio.samples[base + i]
                sum += v * v
            }
            rms = sqrt(sum / Float(block * audio.channels))
        }
        if rms < minRMS {
            gap += 1
            if gap > 1000 { endGap() }
        } else {
            endGap()
        }
    }
    endGap()
    return Double(removedBlocks * block) / audio.sampleRate
}

/// Checks the production output against the input. Failure modes it detects, which listening
/// in the app cannot detect reliably:
///  F1 speech changed: every hop whose grain continues the previous one contiguously must equal
///     the input sample for sample (Hann overlap-add sums to 1).
///  F2 speech compressed: every non-contiguous (moved) hop must lie inside a planned pause core.
///  F3 clicks at joins: moved hops must not contain sample steps larger than the steps found in
///     the input pause they come from.
///  F4 broken time map: map points must be strictly increasing and cover the whole input.
func verify(result: LevelResult, audio: DecodedAudio) -> (passed: Bool, lines: [String]) {
    var lines: [String] = []
    var passed = true
    let channels = audio.channels
    let hop = result.hop
    let hops = min(result.mapInput.count, result.output.count / (hop * channels))
    var contiguous = 0
    var moved = 0
    var maxSpeechError: Float = 0
    var movedOutsideCore = 0
    var clickHops = 0
    var worstClickRatio: Float = 0
    let cores = result.records
    var coreIndex = 0
    for k in 1..<hops {
        let p = result.mapInput[k]
        let prev = result.mapInput[k - 1]
        if p - prev == Int64(hop) {
            // Contiguous: output hop k must equal input [p, p + hop).
            guard p + Int64(hop) <= Int64(audio.frames) else { continue }
            contiguous += 1
            for n in 0..<hop {
                for c in 0..<channels {
                    let y = result.output[(k * hop + n) * channels + c]
                    let x = audio.samples[(Int(p) + n) * channels + c]
                    maxSpeechError = max(maxSpeechError, abs(y - x))
                }
            }
        } else if p >= Int64(audio.frames) {
            // Closing hop after the end of the input: only the faded tail of the last grain.
            continue
        } else {
            moved += 1
            while coreIndex < cores.count && cores[coreIndex].coreEnd <= p { coreIndex += 1 }
            let inside = coreIndex < cores.count && cores[coreIndex].coreStart <= p && p + Int64(2 * hop) <= cores[coreIndex].coreEnd
            if !inside {
                movedOutsideCore += 1
                lines.append("   moved hop \(k)/\(hops) at input \(p) (prev \(prev)), next core \(coreIndex < cores.count ? "\(cores[coreIndex].coreStart)-\(cores[coreIndex].coreEnd)" : "none")")
            }
            // F3: compare sample steps of this output hop with the steps inside the input pause.
            if inside {
                let core = cores[coreIndex]
                var inputStep: Float = 0
                var i = Int(core.coreStart) + 1
                while i < Int(core.coreEnd) && i < audio.frames {
                    for c in 0..<channels {
                        inputStep = max(inputStep, abs(audio.samples[i * channels + c] - audio.samples[(i - 1) * channels + c]))
                    }
                    i += 1
                }
                var outputStep: Float = 0
                for n in 0..<hop {
                    let idx = k * hop + n
                    guard idx > 0 else { continue }
                    for c in 0..<channels {
                        outputStep = max(outputStep, abs(result.output[idx * channels + c] - result.output[(idx - 1) * channels + c]))
                    }
                }
                let ratio = outputStep / max(inputStep, 1e-6)
                worstClickRatio = max(worstClickRatio, ratio)
                if ratio > 1.5 { clickHops += 1 }
            }
        }
    }
    var monotonic = true
    for k in 1..<result.mapInput.count where result.mapInput[k] < result.mapInput[k - 1] || result.mapOutput[k] <= result.mapOutput[k - 1] {
        monotonic = false
    }
    let coverage = (result.mapInput.last ?? 0)
    lines.append(String(format: "F1 contiguous hops %d, max speech error %.2e", contiguous, maxSpeechError))
    if maxSpeechError > 1e-5 { passed = false; lines.append("F1 FAILED: speech samples changed") }
    lines.append("F2 moved hops \(moved), outside a pause core \(movedOutsideCore)")
    if movedOutsideCore > 0 { passed = false; lines.append("F2 FAILED: speech was compressed") }
    lines.append(String(format: "F3 moved hops with a step above 1.5x the pause's own maximum: %d (worst %.2fx)", clickHops, worstClickRatio))
    if clickHops > 0 { passed = false; lines.append("F3 FAILED: click at a join") }
    lines.append("F4 map monotonic \(monotonic), last mapped input sample \(coverage) of \(audio.frames)")
    if !monotonic || coverage < Int64(audio.frames) - Int64(hop) { passed = false; lines.append("F4 FAILED: time map broken") }
    return (passed, lines)
}

func writeWAV(samples: [Float], sampleRate: Double, channels: Int, to url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    let frames = samples.count / channels
    let chunk = 65536
    var offset = 0
    while offset < frames {
        let n = min(chunk, frames - offset)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
        buffer.frameLength = AVAudioFrameCount(n)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress! + offset * channels, count: n * channels)
        }
        try file.write(from: buffer)
        offset += n
    }
}

func histogram(_ lengths: [Double]) -> [(String, Int, Double)] {
    let edges: [(String, Double, Double)] = [
        ("<0.1s", 0, 0.1), ("0.1-0.2s", 0.1, 0.2), ("0.2-0.3s", 0.2, 0.3), ("0.3-0.5s", 0.3, 0.5),
        ("0.5-1s", 0.5, 1), ("1-2s", 1, 2), (">2s", 2, .infinity),
    ]
    return edges.map { label, lo, hi in
        let matching = lengths.filter { $0 >= lo && $0 < hi }
        return (label, matching.count, matching.reduce(0, +))
    }
}

@main
struct Analyze {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        guard !args.isEmpty else {
            print("usage: silence_trim_analyze <file> [--wav-dir dir] [--json file] [--seconds n]")
            exit(2)
        }
        let path = args.removeFirst()
        var wavDir: URL?
        var jsonURL: URL?
        var seconds: Double?
        var sweep = false
        var verifyOutput = false
        var start = 0.0
        while !args.isEmpty {
            let flag = args.removeFirst()
            switch flag {
            case "--wav-dir": wavDir = URL(fileURLWithPath: args.removeFirst())
            case "--json": jsonURL = URL(fileURLWithPath: args.removeFirst())
            case "--seconds": seconds = Double(args.removeFirst())
            case "--sweep": sweep = true
            case "--verify": verifyOutput = true
            case "--start": start = Double(args.removeFirst()) ?? 0
            default: print("unknown flag \(flag)"); exit(2)
            }
        }
        let url = URL(fileURLWithPath: path)
        let decodeStart = Date()
        let audio = try decode(url: url, maximumSeconds: seconds, startSeconds: start)
        if let wavDir {
            try FileManager.default.createDirectory(at: wavDir, withIntermediateDirectories: true)
            let original = wavDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-original.wav")
            try writeWAV(samples: audio.samples, sampleRate: audio.sampleRate, channels: audio.channels, to: original)
        }
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        let duration = Double(audio.frames) / audio.sampleRate
        print("file: \(url.lastPathComponent)")
        print(String(format: "duration %.1f s, %.0f Hz, %d ch, decode %.2f s (%.0fx realtime)",
                     duration, audio.sampleRate, audio.channels, decodeSeconds, duration / decodeSeconds))
        if sweep {
            // Parameter grid used to calibrate the levels.
            for relative: Float in [35, 40] {
                for (lead, trail) in [(0.08, 0.05), (0.05, 0.03), (0.035, 0.02)] {
                    for rate in [2.0, 3.0, 4.0, 6.0, 10.0] {
                        let p = ICSilenceCompressor.Parameters(silenceRate: rate, maximumPauseDuration: 0.6, leadingGuard: lead, trailingGuard: trail)
                        let r = run(level: "sweep", parameters: p, audio: audio, keepOutput: false, relativeDB: relative)
                        let saved = r.inputSeconds - r.outputSeconds
                        print(String(format: "sweep rel=%.0f lead=%.3f trail=%.3f rate=%4.1f -> %5.1f %%  [%@]", relative, lead, trail, rate, 100 * saved / r.inputSeconds, r.detector as NSString))
                    }
                }
            }
            return
        }
        var report: [String: Any] = [
            "file": url.lastPathComponent,
            "durationSeconds": duration,
            "sampleRate": audio.sampleRate,
            "channels": audio.channels,
        ]
        var levels: [[String: Any]] = []
        var runLengths: [Double] = []
        var detectorSummary = ""
        var allPassed = true
        for level in ICSilenceTrimLevel.allLevels where level != .off {
            let parameters = level.compressorParameters!
            let result = run(level: level.diagnosticName, parameters: parameters, audio: audio, keepOutput: wavDir != nil || verifyOutput)
            if runLengths.isEmpty { runLengths = result.runLengths; detectorSummary = result.detector }
            let saved = result.inputSeconds - result.outputSeconds
            print(String(format: "%-7@ saved %6.1f s = %5.1f %% (effective %.3fx), %5d pauses, processing %.2f s (%.0fx realtime)",
                         level.diagnosticName as NSString, saved, 100 * saved / result.inputSeconds,
                         result.inputSeconds / result.outputSeconds, result.compressedPauses,
                         result.processingSeconds, result.inputSeconds / max(result.processingSeconds, 0.001)))
            var verification: [String] = []
            if verifyOutput {
                let check = verify(result: result, audio: audio)
                verification = check.lines
                for line in check.lines { print("  " + line) }
                print("  verification \(check.passed ? "PASSED" : "FAILED")")
                if !check.passed { allPassed = false }
            }
            levels.append([
                "verification": verification,
                "level": level.diagnosticName,
                "parameters": [
                    "silenceRate": parameters.silenceRate,
                    "maximumPauseDuration": parameters.maximumPauseDuration,
                    "leadingGuard": parameters.leadingGuard,
                    "trailingGuard": parameters.trailingGuard,
                ],
                "inputSeconds": result.inputSeconds,
                "outputSeconds": result.outputSeconds,
                "savedSeconds": saved,
                "savedPercent": 100 * saved / result.inputSeconds,
                "compressedPauses": result.compressedPauses,
                "processingSeconds": result.processingSeconds,
                "pauses": result.records.prefix(400).map { [
                    "start": Double($0.start) / audio.sampleRate,
                    "end": Double($0.end) / audio.sampleRate,
                    "rate": $0.rate,
                ] },
            ])
            if let wavDir {
                try FileManager.default.createDirectory(at: wavDir, withIntermediateDirectories: true)
                let out = wavDir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(level.diagnosticName).wav")
                try writeWAV(samples: result.output, sampleRate: audio.sampleRate, channels: audio.channels, to: out)
                print("  wrote \(out.path)")
            }
        }
        print("detector: \(detectorSummary)")
        print("silent runs (detector):")
        for (label, count, total) in histogram(runLengths) {
            print(String(format: "  %-9@ %5d runs, %7.1f s total", label as NSString, count, total))
        }
        let pocketCasts: [(String, Int, Int, Float)] = [("PC-mild", 20, 14, 0.0055), ("PC-medium", 16, 12, 0.00511), ("PC-madmax", 4, 0, 0.005)]
        var pcReport: [[String: Any]] = []
        for (name, gap, reinsert, rms) in pocketCasts {
            let saved = pocketCastsSaving(audio: audio, minGap: gap, reinsert: reinsert, minRMS: rms)
            print(String(format: "%-9@ saved %6.1f s = %5.1f %%", name as NSString, saved, 100 * saved / duration))
            pcReport.append(["rules": name, "savedSeconds": saved, "savedPercent": 100 * saved / duration])
        }
        report["levels"] = levels
        report["pocketCastsRules"] = pcReport
        report["silentRunHistogram"] = histogram(runLengths).map { ["bucket": $0.0, "count": $0.1, "seconds": $0.2] }
        if let jsonURL {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: jsonURL)
            print("report: \(jsonURL.path)")
        }
        if !allPassed { exit(1) }
    }
}
