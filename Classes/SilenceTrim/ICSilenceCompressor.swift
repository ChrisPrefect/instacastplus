//
//  ICSilenceCompressor.swift
//  InstacastPlus
//
//  Shortens the pauses of spoken audio by playing them faster than the speech around them.
//
//  The approach follows what Overcast describes for its Smart Speed ("speed up the silence more
//  than the rest of it", Marco Arment, TechCrunch 2014): speech stays sample-exact, only the
//  inside of a pause is time-compressed. Instead of cutting pauses (Pocket Casts' AudioReadTask,
//  Media3's SilenceSkippingAudioProcessor) the whole stream runs through one WSOLA time-scale
//  modifier whose analysis hop is 1 in speech and > 1 inside pauses:
//
//  * Speech uses contiguous grains with a periodic Hann window at 50 % overlap, which sums to
//    exactly 1, so speech and the guard zones around it come out unchanged.
//  * Inside a pause the analysis position advances faster. Every grain is aligned to the
//    natural continuation of the previous one (normalised cross-correlation), so room tone,
//    hum and breath noise keep a continuous texture instead of a splice.
//  * A pause is detected with an adaptive threshold between the local noise floor and the
//    local speech level (percentiles over a 20 s window that also looks 5 s ahead), with
//    hysteresis. Regions without enough contrast (music beds, constant noise) are left alone.
//  * With speech detection (Silero VAD, see ICSileroVAD.swift) a sound between two silent
//    stretches that contains no speech (breath, lip smack, rustling) belongs to the pause.
//    Word edges still come from the level detection, so speech keeps its sample-exact borders.
//  * Every pause keeps a guard at natural speed after the speech (decay, final fricatives) and
//    before it resumes (onsets), so word edges are never touched. Pauses shorter than the two
//    guards plus one grain are not modified at all, which protects stop closures and the very
//    short gaps inside words.
//  * Inside the guards a pause plays `silenceRate` times faster, i.e. its length shrinks
//    proportionally; `maximumPauseDuration` caps what a long pause keeps.
//
//  The class is not thread safe; the player drives one instance from its serial queue.
//

import Foundation
import Accelerate

final class ICSilenceCompressor {

    struct Parameters: Equatable {
        /// Playback rate inside a pause relative to the speech around it.
        var silenceRate: Double
        /// Longest output a single pause keeps, guards included (seconds).
        var maximumPauseDuration: Double
        /// Natural-speed zone kept after speech ends (seconds).
        var leadingGuard: Double
        /// Natural-speed zone kept before speech resumes (seconds).
        var trailingGuard: Double
    }

    /// One emitted block of output.
    struct Chunk {
        /// Interleaved float samples, `frameCount * channelCount` values.
        var samples: [Float]
        var frameCount: Int
        /// Output sample index (session relative) of the first frame.
        var outputStart: Int64
        /// Mapping points: output sample index -> source sample index (absolute), one per hop,
        /// plus the end point of the chunk.
        var mapOutput: [Int64]
        var mapInput: [Int64]
    }

    /// Detected pause, in absolute source samples (for diagnostics and tests).
    struct PauseRecord {
        var start: Int64
        var end: Int64
        var coreStart: Int64
        var coreEnd: Int64
        var rate: Double
    }

    // MARK: Configuration

    let sampleRate: Double
    let channelCount: Int
    private(set) var parameters: Parameters

    /// Synthesis hop, about 5.8 ms. Short grains let even 0.1 s pauses be compressed.
    let hop: Int
    /// Grain length (2 * hop).
    let grainLength: Int
    /// Alignment search radius in samples, about 5.8 ms.
    let tolerance: Int
    /// Detection frame length, 10 ms.
    let detectionFrame: Int

    // Detection settings that do not depend on the selected level.
    private let pastStatisticsFrames = 1500      // 15 s
    private let futureStatisticsFrames = 500     // 5 s
    private let maximumResolvedRunFrames = 1500  // a pause longer than 15 s is planned in parts
    /// Position of the silence threshold between the noise floor and the speech level.
    var thresholdRatio: Float = 0.25
    private let minimumMarginDB: Float = 6
    private let hysteresisDB: Float = 3
    private let minimumContrastDB: Float = 15
    /// Anything this far below the local speech level counts as pause, even when the floor is
    /// digital silence from a noise gate (where the adaptive threshold alone sits far too low).
    var relativeSilenceDB: Float = 38
    /// Frames closer than this to the speech level are never treated as pause.
    private let minimumDistanceToSpeechDB: Float = 20
    private let digitalSilenceDB: Float = -70
    private let neverSilentDB: Float = -18
    private let islandFrames = 2                 // speech islands up to 20 ms inside a pause are clicks

    // Speech detection (optional). Pause = no speech, whatever else is audible in it.
    private let vad: ICSileroVAD?
    private let vadResampler: ICVADResampler?
    private var vadPending: [Float] = []
    private var vadSpeech: [Bool] = []           // per 32 ms chunk of the session, after hysteresis
    private var vadChunkBase = 0                 // session chunk index of vadSpeech[0]
    private var vadState = true
    /// Silero's defaults: speech starts at 0.5 and ends below 0.35, segments padded by 30 ms.
    static let vadStartThreshold: Float = 0.5
    static let vadEndThreshold: Float = 0.35
    static let vadPadSeconds = 0.03
    /// After a session start the LSTM state is new; measured decisions settle within 41 chunks.
    static let vadWarmUpChunks = 64
    /// Longest sound without speech absorbed into a pause (frames of 10 ms).
    var maximumNonSpeechIslandFrames = 300
    /// Sounds without speech that reach this close to the local speech level are content
    /// (music, jingles), not pause noise. Measured 21.11.2026: in four talk shows most such sounds
    /// peak 20-35 dB below speech (Lex 420 of 445), in The Daily 66 of 91 above -15 dB (music
    /// and sound design). nil disables the check (analysis).
    var nonSpeechIslandMaximumLevelDB: Float? = -15
    var usesSpeechDetection: Bool { vad != nil }

    // MARK: Input state

    /// Absolute source sample index the current session started at.
    private(set) var sessionStart: Int64 = 0
    private var input: [[Float]]
    private var inputBase: Int64 = 0
    private var inputEnd: Int64 { inputBase + Int64(input[0].count) }
    private(set) var endOfInput = false

    // High-pass biquad (100 Hz) for the detection signal.
    private var hpB0: Double = 1, hpB1: Double = 0, hpB2: Double = 0, hpA1: Double = 0, hpA2: Double = 0
    private var hpX1: Double = 0, hpX2: Double = 0, hpY1: Double = 0, hpY2: Double = 0
    private var frameAccumulator: Double = 0
    private var frameAccumulatorCount = 0

    // Detection frames (session relative index).
    private var frameDB: [Float] = []
    private var frameBase = 0
    private var frameEnd: Int { frameBase + frameDB.count }
    private var frameSilent: [Bool] = []          // aligned with frameDB, valid below classifiedEnd
    private var frameSpeechDB: [Float] = []       // local speech level per frame, valid below classifiedEnd
    private var classifiedEnd = 0
    private var histogram = [Int32](repeating: 0, count: ICSilenceCompressor.histogramBins)
    private var histogramLow = 0                  // first frame contained in the histogram
    private var histogramHigh = 0                 // one past the last frame contained
    private var silentState = false
    private static let histogramBins = 240        // 0.5 dB bins from -120 dB to 0 dB

    // Planning.
    private var plans: [PauseRecord] = []
    private var scanFrame = 0                     // first frame not yet resolved into runs
    private var openRunStart: Int?                // frame where an unresolved run started

    // MARK: Synthesis state

    private let window: [Float]
    private var overlap: [[Float]]                // tail of the previous grain, hop samples per channel
    private var analysisPosition: Int64 = 0       // absolute source sample of the next grain
    private var previousPosition: Int64?          // absolute source sample of the previous grain
    private var idealPosition: Int64 = 0          // where the analysis would be without alignment
    private var outputPosition: Int64 = 0         // session relative output sample of the next hop
    private var finished = false
    private var primingHops = 0                   // hops processed but not emitted (see reset)
    private var correlationScratch: [Float] = []
    private var grainScratch: [Float] = []
    private var energyScratch: [Float] = []

    // MARK: Statistics

    private(set) var consumedInputSamples: Int64 = 0
    private(set) var producedOutputSamples: Int64 = 0
    private(set) var compressedPauseCount = 0
    var savedSeconds: Double { Double(consumedInputSamples - producedOutputSamples) / sampleRate }
    /// Every planned pause, kept only when `recordsPauses` is set (offline analysis).
    var recordsPauses = false
    private(set) var pauseRecords: [PauseRecord] = []
    /// Sums for detector diagnostics (offline analysis).
    private(set) var diagnosticFloorSum: Double = 0
    private(set) var diagnosticSpeechSum: Double = 0
    private(set) var diagnosticThresholdSum: Double = 0
    private(set) var diagnosticFrames = 0
    private(set) var diagnosticSilentFrames = 0
    /// Lengths of every detected silent run in seconds (offline analysis).
    private(set) var silentRunLengths: [Double] = []
    /// Every detected pause (absolute samples), including absorbed sounds (offline analysis).
    private(set) var silentRuns: [(start: Int64, end: Int64)] = []
    /// A sound between two silent stretches that speech detection judged (offline analysis).
    struct IslandRecord {
        var start: Int64
        var end: Int64
        var peakAboveSpeechDB: Float
        var containsSpeech: Bool
        var absorbed: Bool
    }
    private(set) var islandRecords: [IslandRecord] = []

    // MARK: Init

    init(sampleRate: Double, channelCount: Int, parameters: Parameters, speechModel: ICSileroVADModel? = nil) {
        precondition(channelCount > 0)
        if let speechModel {
            vad = ICSileroVAD(model: speechModel)
            vadResampler = ICVADResampler(inputRate: sampleRate)
        } else {
            vad = nil
            vadResampler = nil
        }
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.parameters = parameters
        let hop = Self.hopLength(sampleRate: sampleRate)
        self.hop = hop
        self.grainLength = hop * 2
        self.tolerance = hop
        self.detectionFrame = max(16, Int((sampleRate / 100).rounded()))
        var window = [Float](repeating: 0, count: hop * 2)
        for n in 0..<(hop * 2) {
            window[n] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(hop * 2)))
        }
        self.window = window
        self.input = Array(repeating: [], count: channelCount)
        self.overlap = Array(repeating: [Float](repeating: 0, count: hop), count: channelCount)
        configureHighPass()
        reset(atSourceSample: 0)
    }

    /// Synthesis hop for a sample rate (about 5.8 ms).
    static func hopLength(sampleRate: Double) -> Int {
        max(32, Int((sampleRate * 0.0058).rounded()))
    }

    private func configureHighPass() {
        let f0 = 100.0
        let q = 0.7071
        let w0 = 2 * Double.pi * f0 / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha
        hpB0 = ((1 + cosw) / 2) / a0
        hpB1 = (-(1 + cosw)) / a0
        hpB2 = ((1 + cosw) / 2) / a0
        hpA1 = (-2 * cosw) / a0
        hpA2 = (1 - alpha) / a0
    }

    /// Starts a new session at `sample` (absolute source position).
    ///
    /// A seek starts unprimed: the first hop fades in over one hop so playback never starts with a
    /// step. A restart that continues already playing audio (level change, automatic renderer
    /// flush) is `primed`: the session begins one hop earlier and that hop is not emitted, so the
    /// first emitted hop is complete and continues the audio before it without a dip. The input
    /// must then start at `sessionStart`.
    func reset(atSourceSample requested: Int64, primed: Bool = false) {
        let sample = (primed && requested >= Int64(hop)) ? requested - Int64(hop) : requested
        primingHops = sample < requested ? 1 : 0
        sessionStart = sample
        for c in 0..<channelCount {
            input[c].removeAll(keepingCapacity: true)
            overlap[c] = [Float](repeating: 0, count: hop)
        }
        inputBase = sample
        endOfInput = false
        hpX1 = 0; hpX2 = 0; hpY1 = 0; hpY2 = 0
        frameAccumulator = 0
        frameAccumulatorCount = 0
        frameDB.removeAll(keepingCapacity: true)
        frameSilent.removeAll(keepingCapacity: true)
        frameSpeechDB.removeAll(keepingCapacity: true)
        frameBase = 0
        vad?.reset()
        vadResampler?.reset()
        vadPending.removeAll(keepingCapacity: true)
        vadSpeech.removeAll(keepingCapacity: true)
        vadChunkBase = 0
        vadState = true
        classifiedEnd = 0
        histogram = [Int32](repeating: 0, count: Self.histogramBins)
        histogramLow = 0
        histogramHigh = 0
        silentState = false
        plans.removeAll()
        scanFrame = 0
        openRunStart = nil
        analysisPosition = sample
        idealPosition = sample
        previousPosition = nil
        outputPosition = 0
        finished = false
    }

    /// Changes the level for audio that has not been produced yet.
    func updateParameters(_ newParameters: Parameters) {
        guard newParameters != parameters else { return }
        parameters = newParameters
        // Re-plan every pause from the current position on with the new values.
        plans.removeAll()
        openRunStart = nil
        let currentFrame = frameIndex(forSample: analysisPosition)
        scanFrame = max(frameBase, min(currentFrame, classifiedEnd))
        // A run that already started before the current position is picked up from its start
        // so the leading guard is not applied a second time in the middle of a pause.
        while scanFrame > frameBase, scanFrame - 1 < classifiedEnd, frameSilent[scanFrame - 1 - frameBase] {
            scanFrame -= 1
        }
    }

    // MARK: Input

    /// Appends interleaved float samples.
    func append(interleaved samples: UnsafeBufferPointer<Float>, frameCount: Int) {
        guard frameCount > 0, let base = samples.baseAddress else { return }
        let channels = channelCount
        var mono = [Float](repeating: 0, count: frameCount)
        var scale = 1 / Float(channels)
        for c in 0..<channels {
            let oldCount = input[c].count
            input[c].append(contentsOf: repeatElement(0, count: frameCount))
            input[c].withUnsafeMutableBufferPointer { dst in
                // Strided copy of one channel out of the interleaved block.
                var zero: Float = 0
                vDSP_vsadd(base + c, vDSP_Stride(channels), &zero, dst.baseAddress! + oldCount, 1, vDSP_Length(frameCount))
            }
            mono.withUnsafeMutableBufferPointer { dst in
                vDSP_vsma(base + c, vDSP_Stride(channels), &scale, dst.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(frameCount))
            }
        }
        analyse(mono: mono)
        classifyAvailableFrames()
        resolveRuns()
    }

    /// Marks the end of the source.
    func finishInput() {
        guard !endOfInput else { return }
        endOfInput = true
        if frameAccumulatorCount > 0 {
            pushFrame(meanSquare: frameAccumulator / Double(frameAccumulatorCount))
            frameAccumulator = 0
            frameAccumulatorCount = 0
        }
        classifyAvailableFrames()
        resolveRuns()
    }

    private func analyse(mono: [Float]) {
        if let vad, let vadResampler {
            mono.withUnsafeBufferPointer { vadResampler.process($0, into: &vadPending) }
            var offset = 0
            let chunk = ICSileroVAD.chunkLength
            while vadPending.count - offset >= chunk {
                let probability = vadPending.withUnsafeBufferPointer { vad.process($0.baseAddress! + offset) }
                if vadChunkBase + vadSpeech.count < Self.vadWarmUpChunks || probability >= Self.vadStartThreshold {
                    vadState = true
                } else if probability < Self.vadEndThreshold {
                    vadState = false
                }
                vadSpeech.append(vadState)
                offset += chunk
            }
            if offset > 0 { vadPending.removeFirst(offset) }
        }
        for x in mono {
            let xd = Double(x)
            let y = hpB0 * xd + hpB1 * hpX1 + hpB2 * hpX2 - hpA1 * hpY1 - hpA2 * hpY2
            hpX2 = hpX1; hpX1 = xd
            hpY2 = hpY1; hpY1 = y
            frameAccumulator += y * y
            frameAccumulatorCount += 1
            if frameAccumulatorCount == detectionFrame {
                pushFrame(meanSquare: frameAccumulator / Double(detectionFrame))
                frameAccumulator = 0
                frameAccumulatorCount = 0
            }
        }
    }

    private func pushFrame(meanSquare: Double) {
        let db = Float(10 * log10(max(meanSquare, 1e-14)))
        frameDB.append(db)
        frameSilent.append(false)
        frameSpeechDB.append(0)
    }

    private static func bin(for db: Float) -> Int {
        let value = Int(((db + 120) * 2).rounded(.down))
        return min(max(value, 0), histogramBins - 1)
    }

    private static func level(forBin bin: Int) -> Float {
        Float(bin) * 0.5 - 120 + 0.25
    }

    private func percentile(_ fraction: Double, count: Int) -> Float {
        let target = max(1, Int(Double(count) * fraction))
        var running = 0
        for b in 0..<Self.histogramBins {
            running += Int(histogram[b])
            if running >= target { return Self.level(forBin: b) }
        }
        return 0
    }

    private func classifyAvailableFrames() {
        while classifiedEnd < frameEnd {
            let center = classifiedEnd
            let wantedHigh = center + futureStatisticsFrames + 1
            if wantedHigh > frameEnd && !endOfInput { break }
            let high = min(wantedHigh, frameEnd)
            let low = max(frameBase, center - pastStatisticsFrames)
            while histogramHigh < high {
                if histogramHigh >= frameBase {
                    histogram[Self.bin(for: frameDB[histogramHigh - frameBase])] += 1
                }
                histogramHigh += 1
            }
            while histogramLow < low {
                if histogramLow >= frameBase && histogramLow < histogramHigh {
                    histogram[Self.bin(for: frameDB[histogramLow - frameBase])] -= 1
                }
                histogramLow += 1
            }
            let count = histogramHigh - max(histogramLow, frameBase)
            let floor = percentile(0.10, count: count)
            let speech = percentile(0.90, count: count)
            let contrast = speech - floor
            let db = frameDB[center - frameBase]
            var silent: Bool
            if db <= digitalSilenceDB {
                silent = true
            } else if db >= neverSilentDB || contrast < minimumContrastDB {
                silent = false
            } else {
                let threshold = silenceThreshold(floor: floor, speech: speech)
                if silentState {
                    silent = db < threshold + hysteresisDB
                } else {
                    silent = db < threshold
                }
            }
            silentState = silent
            frameSilent[center - frameBase] = silent
            frameSpeechDB[center - frameBase] = speech
            if recordsPauses {
                diagnosticFloorSum += Double(floor)
                diagnosticSpeechSum += Double(speech)
                diagnosticThresholdSum += Double(silenceThreshold(floor: floor, speech: speech))
                diagnosticFrames += 1
                if silent { diagnosticSilentFrames += 1 }
            }
            classifiedEnd += 1
        }
    }

    private func silenceThreshold(floor: Float, speech: Float) -> Float {
        let adaptive = floor + max(minimumMarginDB, thresholdRatio * (speech - floor))
        let relative = speech - relativeSilenceDB
        return min(max(adaptive, relative), speech - minimumDistanceToSpeechDB)
    }

    // MARK: Planning

    private func frameIndex(forSample sample: Int64) -> Int {
        Int((sample - sessionStart) / Int64(detectionFrame))
    }

    private func sample(forFrame frame: Int) -> Int64 {
        sessionStart + Int64(frame) * Int64(detectionFrame)
    }

    private func isSilentFrame(_ frame: Int) -> Bool {
        frameSilent[frame - frameBase]
    }

    /// Whether speech detection found speech within the frame or its padding. Chunks that are not
    /// analysed (yet or any more) count as speech, so missing data never shortens anything.
    private func frameHasSpeech(_ frame: Int) -> Bool {
        let perChunk = Double(ICSileroVAD.chunkLength) / ICSileroVAD.sampleRate
        let start = Double(sample(forFrame: frame) - sessionStart) / sampleRate - Self.vadPadSeconds
        let end = Double(sample(forFrame: frame + 1) - sessionStart) / sampleRate + Self.vadPadSeconds
        let first = max(0, Int((start / perChunk).rounded(.down)))
        let last = max(first, Int((end / perChunk).rounded(.down)))
        for chunk in first...last {
            let index = chunk - vadChunkBase
            guard index >= 0, index < vadSpeech.count else { return true }
            if vadSpeech[index] { return true }
        }
        return false
    }

    /// Resolves silent runs into plans as far as the classification allows.
    private func resolveRuns() {
        while scanFrame < classifiedEnd {
            if let runStart = openRunStart {
                // Look for the end of the open run: the first speech frame that is not a short
                // click inside the pause.
                var frame = scanFrame
                var runEnd: Int?
                while frame < classifiedEnd {
                    if !isSilentFrame(frame) {
                        // A sound inside the pause: a click, or with speech detection any sound
                        // without speech (breath, lip smack, rustling) up to a few seconds.
                        let limit = vad != nil ? maximumNonSpeechIslandFrames : islandFrames
                        var islandEnd = frame
                        var containsSpeech = false
                        var decided = false
                        var peak = -Float.infinity
                        while islandEnd < classifiedEnd && !isSilentFrame(islandEnd) && islandEnd - frame <= limit {
                            if vad != nil {
                                peak = max(peak, frameDB[islandEnd - frameBase] - frameSpeechDB[islandEnd - frameBase])
                                if frameHasSpeech(islandEnd) { containsSpeech = true }
                                // Speech longer than a click ends the pause.
                                if containsSpeech && islandEnd - frame >= islandFrames {
                                    decided = true
                                    break
                                }
                            }
                            islandEnd += 1
                        }
                        if !decided && islandEnd >= classifiedEnd && !endOfInput {
                            // Cannot decide yet what this sound is.
                            scanFrame = frame
                            return
                        }
                        let endsInSilence = islandEnd < classifiedEnd && isSilentFrame(islandEnd)
                        if islandEnd - frame <= islandFrames && endsInSilence {
                            frame = islandEnd
                            continue
                        }
                        if vad != nil && endsInSilence {
                            let quiet = nonSpeechIslandMaximumLevelDB.map { peak < $0 } ?? true
                            let absorbed = !containsSpeech && quiet
                            if recordsPauses {
                                islandRecords.append(IslandRecord(start: sample(forFrame: frame), end: sample(forFrame: islandEnd),
                                                                  peakAboveSpeechDB: peak, containsSpeech: containsSpeech, absorbed: absorbed))
                            }
                            if absorbed {
                                frame = islandEnd
                                continue
                            }
                        }
                        runEnd = frame
                        break
                    }
                    frame += 1
                    if frame - runStart >= maximumResolvedRunFrames {
                        runEnd = frame
                        break
                    }
                }
                if let end = runEnd {
                    addPlan(runStartFrame: runStart, runEndFrame: end, endsInSpeech: end < classifiedEnd && !isSilentFrame(end))
                    openRunStart = nil
                    scanFrame = end
                    continue
                }
                if endOfInput && frame >= classifiedEnd {
                    addPlan(runStartFrame: runStart, runEndFrame: classifiedEnd, endsInSpeech: false)
                    openRunStart = nil
                    scanFrame = classifiedEnd
                    return
                }
                scanFrame = frame
                return
            } else {
                if isSilentFrame(scanFrame) {
                    openRunStart = scanFrame
                }
                scanFrame += 1
            }
        }
    }

    private func addPlan(runStartFrame: Int, runEndFrame: Int, endsInSpeech: Bool) {
        let start = sample(forFrame: runStartFrame)
        let end = sample(forFrame: runEndFrame)
        if recordsPauses {
            silentRunLengths.append(Double(end - start) / sampleRate)
            silentRuns.append((start, end))
        }
        let leading = Int64((parameters.leadingGuard * sampleRate).rounded())
        let trailing = endsInSpeech ? Int64((parameters.trailingGuard * sampleRate).rounded()) : 0
        let coreStart = start + leading
        let coreEnd = end - trailing
        let coreLength = coreEnd - coreStart
        // A grain that is moved needs room for itself and its alignment search.
        let minimumCore = Int64(grainLength + tolerance + hop)
        guard coreLength >= minimumCore, parameters.silenceRate > 1.0001 else { return }
        var coreOutput = Double(coreLength) / parameters.silenceRate
        let guardOutput = Double(leading + trailing)
        let cap = parameters.maximumPauseDuration * sampleRate - guardOutput
        if cap > 0 {
            coreOutput = min(coreOutput, max(cap, Double(grainLength)))
        }
        let rate = max(parameters.silenceRate, Double(coreLength) / max(coreOutput, 1))
        let record = PauseRecord(start: start, end: end, coreStart: coreStart, coreEnd: coreEnd, rate: rate)
        plans.append(record)
        compressedPauseCount += 1
        if recordsPauses {
            pauseRecords.append(record)
        }
    }

    /// Whether planning reaches far enough past `position` to place the next grain.
    private func planningCovers(_ position: Int64) -> Bool {
        if endOfInput && classifiedEnd >= frameEnd && openRunStart == nil && scanFrame >= classifiedEnd {
            return true
        }
        let needed = frameIndex(forSample: position + Int64(grainLength * 2 + tolerance)) + 1
        let resolvedUpTo = openRunStart ?? scanFrame
        return resolvedUpTo > needed
    }

    // MARK: Output

    /// Produces up to `maximumFrames` output frames. Returns nil when more input is needed or the
    /// stream has ended; `isFinished` tells the two apart.
    func produce(maximumFrames: Int) -> Chunk? {
        guard !finished else { return nil }
        resolveRuns()
        let hops = max(1, maximumFrames / hop)
        var samples = [Float]()
        samples.reserveCapacity(hops * hop * channelCount)
        var mapOutput = [Int64]()
        var mapInput = [Int64]()
        let chunkStart = outputPosition
        var produced = 0
        while produced < hops {
            // The grain at analysisPosition needs its samples, and for alignment the next ones.
            let neededEnd = analysisPosition + Int64(grainLength + hop + tolerance)
            if !endOfInput && inputEnd < neededEnd { break }
            if !planningCovers(analysisPosition) { break }
            if primingHops > 0 && analysisPosition < inputEnd {
                // Fill the overlap with the grain before the requested start without emitting it.
                var discarded = [Float]()
                appendHop(from: analysisPosition, into: &discarded)
                let next = nextPosition(after: analysisPosition)
                previousPosition = analysisPosition
                analysisPosition = next
                primingHops -= 1
                continue
            }
            if endOfInput && analysisPosition >= inputEnd {
                // Flush the tail of the last grain.
                appendHop(from: nil, into: &samples)
                mapOutput.append(outputPosition)
                mapInput.append(inputEnd)
                outputPosition += Int64(hop)
                producedOutputSamples += Int64(hop)
                finished = true
                produced += 1
                break
            }
            mapOutput.append(outputPosition)
            mapInput.append(analysisPosition)
            appendHop(from: analysisPosition, into: &samples)
            let next = nextPosition(after: analysisPosition)
            consumedInputSamples += max(0, min(next, inputEnd) - analysisPosition)
            producedOutputSamples += Int64(hop)
            previousPosition = analysisPosition
            analysisPosition = next
            outputPosition += Int64(hop)
            produced += 1
        }
        discardConsumedInput()
        guard produced > 0 else { return nil }
        mapOutput.append(outputPosition)
        mapInput.append(finished ? inputEnd : analysisPosition)
        return Chunk(samples: samples,
                     frameCount: produced * hop,
                     outputStart: chunkStart,
                     mapOutput: mapOutput,
                     mapInput: mapInput)
    }

    var isFinished: Bool { finished }

    /// Source position (absolute samples) that the next produced output frame belongs to.
    var nextSourcePosition: Int64 { analysisPosition }

    /// Whether the next emitted hop lies inside a pause that is being shortened.
    var nextHopIsShortened: Bool { activePlan(at: analysisPosition) != nil }

    /// Whether the next hop is shortened and lies in true silence, one MP3 frame (1152 samples)
    /// of slack on both sides: there a decoder that sits one frame off can be swapped without an
    /// audible step. With speech detection a shortened pause may contain a sound (breath, music
    /// below the content check), where it could not (measured 21.11.2026, The Daily: step x14.8).
    var nextHopIsSilentPause: Bool {
        guard nextHopIsShortened else { return false }
        let slack: Int64 = 1152
        let first = max(frameBase, frameIndex(forSample: max(sessionStart, analysisPosition - slack)))
        let last = frameIndex(forSample: analysisPosition + Int64(grainLength) + slack)
        guard last < classifiedEnd else { return false }
        for frame in first...last where !isSilentFrame(frame) {
            return false
        }
        return true
    }

    /// First source sample at or after `start` whose surroundings (± `margin`) are silent for the
    /// level detection, within the audio analysed so far; nil when there is none yet. A player
    /// switch placed there is inaudible: whatever gap or overlap it makes falls into silence.
    func firstSilentSample(atOrAfter start: Int64, margin: Int64) -> Int64? {
        let reach = Int((margin + Int64(detectionFrame) - 1) / Int64(detectionFrame))
        let firstCenter = max(frameBase + reach, frameIndex(forSample: max(start, sessionStart)) + 1)
        var run = 0
        var frame = firstCenter - reach
        while frame < classifiedEnd {
            run = isSilentFrame(frame) ? run + 1 : 0
            let center = frame - reach
            if run >= 2 * reach + 1 && center >= firstCenter {
                return sample(forFrame: center)
            }
            frame += 1
        }
        return nil
    }

    /// Output position (session samples) of the next produced frame.
    var nextOutputPosition: Int64 { outputPosition }

    /// Adds the grain at `position` (or silence) and emits the completed hop.
    private func appendHop(from position: Int64?, into samples: inout [Float]) {
        let channels = channelCount
        let start = samples.count
        samples.append(contentsOf: repeatElement(0, count: hop * channels))
        if grainScratch.count != grainLength { grainScratch = [Float](repeating: 0, count: grainLength) }
        for c in 0..<channels {
            for n in 0..<grainLength { grainScratch[n] = 0 }
            if let position = position {
                let offset = Int(position - inputBase)
                let available = max(0, min(grainLength, input[c].count - offset))
                if available > 0 && offset >= 0 {
                    input[c].withUnsafeBufferPointer { src in
                        grainScratch.withUnsafeMutableBufferPointer { dst in
                            vDSP_vmul(src.baseAddress! + offset, 1, window, 1, dst.baseAddress!, 1, vDSP_Length(available))
                        }
                    }
                }
            }
            // Completed hop = tail of previous grain + head of this grain.
            for n in 0..<hop {
                samples[start + n * channels + c] = overlap[c][n] + grainScratch[n]
                overlap[c][n] = grainScratch[hop + n]
            }
        }
    }

    private func activePlan(at position: Int64) -> PauseRecord? {
        while let first = plans.first, first.coreEnd <= position {
            plans.removeFirst()
        }
        guard let first = plans.first, first.coreStart <= position else { return nil }
        return first
    }

    private func nextPosition(after position: Int64) -> Int64 {
        let natural = position + Int64(hop)
        guard let plan = activePlan(at: position) else {
            idealPosition = natural
            return natural
        }
        // The ideal timeline advances by rate * hop; alignment only chooses a nearby start, so
        // the achieved rate equals the planned one on average (no drift towards short jumps).
        if idealPosition < position - Int64(tolerance) || idealPosition > position + Int64(tolerance) {
            idealPosition = position
        }
        // The next grain must end inside the compressible core.
        let latest = plan.coreEnd - Int64(grainLength)
        let ideal = min(idealPosition + Int64((Double(hop) * plan.rate).rounded()), latest)
        guard ideal > natural else {
            idealPosition = natural
            return natural
        }
        // The search window stays clear of the natural continuation, which would always win.
        let radius = min(Int64(tolerance), (ideal - natural) / 2)
        let lower = max(ideal - radius, natural + 1)
        let upper = min(ideal + radius, latest)
        idealPosition = ideal
        guard upper > lower else { return ideal }
        return align(previous: position, nominal: ideal, searchStart: lower, searchEnd: upper)
    }

    /// Finds the position in [searchStart, searchEnd] whose start best continues the previous
    /// grain (normalised cross-correlation over one hop), preferring `nominal` on ties.
    private func align(previous: Int64, nominal: Int64, searchStart: Int64, searchEnd: Int64) -> Int64 {
        let lags = Int(searchEnd - searchStart) + 1
        let referenceStart = Int(previous + Int64(hop) - inputBase)
        let candidateStart = Int(searchStart - inputBase)
        let length = hop
        guard lags > 1,
              referenceStart >= 0,
              candidateStart >= 0,
              candidateStart + lags - 1 + length <= input[0].count,
              referenceStart + length <= input[0].count else {
            return nominal
        }
        // Mono mix for alignment so every channel moves together.
        let span = lags - 1 + length
        var signal = [Float](repeating: 0, count: span)
        var reference = [Float](repeating: 0, count: length)
        var scale = 1 / Float(channelCount)
        for c in 0..<channelCount {
            input[c].withUnsafeBufferPointer { src in
                signal.withUnsafeMutableBufferPointer { dst in
                    vDSP_vsma(src.baseAddress! + candidateStart, 1, &scale, dst.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(span))
                }
                reference.withUnsafeMutableBufferPointer { dst in
                    vDSP_vsma(src.baseAddress! + referenceStart, 1, &scale, dst.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(length))
                }
            }
        }
        if correlationScratch.count < lags { correlationScratch = [Float](repeating: 0, count: lags) }
        if energyScratch.count < span + 1 { energyScratch = [Float](repeating: 0, count: span + 1) }
        signal.withUnsafeBufferPointer { sig in
            reference.withUnsafeBufferPointer { ref in
                correlationScratch.withUnsafeMutableBufferPointer { out in
                    vDSP_conv(sig.baseAddress!, 1, ref.baseAddress!, 1, out.baseAddress!, 1, vDSP_Length(lags), vDSP_Length(length))
                }
            }
        }
        // Running energy of each candidate window.
        energyScratch[0] = 0
        for i in 0..<span {
            energyScratch[i + 1] = energyScratch[i] + signal[i] * signal[i]
        }
        var bestLag = Int(min(max(nominal, searchStart), searchEnd) - searchStart)
        var bestScore = -Float.greatestFiniteMagnitude
        for lag in 0..<lags {
            let energy = energyScratch[lag + length] - energyScratch[lag]
            let score = correlationScratch[lag] / sqrt(max(energy, 1e-12))
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        return searchStart + Int64(bestLag)
    }

    private func discardConsumedInput() {
        // Keep everything from the current grain on (the alignment never looks back).
        let keepFrom = analysisPosition - Int64(hop)
        let removable = Int(keepFrom - inputBase)
        if removable > Int(sampleRate) {
            for c in 0..<channelCount {
                input[c].removeFirst(removable)
            }
            inputBase += Int64(removable)
        }
        // Detection frames are kept for the statistics window behind the current position.
        let frameKeepFrom = min(histogramLow, scanFrame, openRunStart ?? Int.max, frameIndex(forSample: analysisPosition)) - 2
        let removableFrames = frameKeepFrom - frameBase
        if removableFrames > 1000 {
            frameDB.removeFirst(removableFrames)
            frameSilent.removeFirst(removableFrames)
            frameSpeechDB.removeFirst(removableFrames)
            frameBase += removableFrames
            if vad != nil {
                let keepChunk = Int(Double(sample(forFrame: frameBase) - sessionStart) / sampleRate * ICSileroVAD.sampleRate) / ICSileroVAD.chunkLength - 2
                let removableChunks = min(keepChunk - vadChunkBase, vadSpeech.count)
                if removableChunks > 0 {
                    vadSpeech.removeFirst(removableChunks)
                    vadChunkBase += removableChunks
                }
            }
        }
    }

    /// Whether the compressor needs more input before it can produce output again.
    var wantsInput: Bool {
        guard !endOfInput else { return false }
        let neededForGrains = inputEnd < analysisPosition + Int64(grainLength * 3 + tolerance)
        return neededForGrains || !planningCovers(analysisPosition)
    }

    /// Seconds of decoded audio buffered ahead of the current position.
    var bufferedSeconds: Double {
        Double(inputEnd - analysisPosition) / sampleRate
    }
}
