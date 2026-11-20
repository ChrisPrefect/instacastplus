//
//  ICSilenceTrimPlayer.swift
//  InstacastPlus
//
//  Plays a local audio file with shortened pauses. It only runs while pause shortening is
//  active for the playing episode; every other case keeps using PlaybackManager's AVPlayer.
//
//  Pipeline (serial `queue`):
//    AVAssetReader (LPCM float) -> ICSilenceCompressor -> CMSampleBuffer
//      -> AVSampleBufferAudioRenderer attached to an AVSampleBufferRenderSynchronizer.
//
//  AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer is the custom-player path for
//  which Apple documents AirPlay 2 enhanced buffering and long-form routing ("Implementing
//  flexible enhanced buffering for your content"); AVAudioEngine does not get it, which is why
//  Pocket Casts falls back to AVPlayer over AirPlay. The user's playback speed is applied by the
//  synchronizer rate with the renderer's time-pitch algorithm (the same one AVPlayerItem uses),
//  so only the pauses are handled by the compressor.
//
//  Times: the synchronizer runs on an output timeline (shortened audio). Everything this class
//  reports to the app is source time of the episode file; the map from enqueued output samples
//  to source samples converts between the two.
//

import AVFoundation
import Foundation
import os

@objc protocol ICSilenceTrimPlayerDelegate: AnyObject {
    func silenceTrimPlayerDidBecomeReady(_ player: ICSilenceTrimPlayer)
    func silenceTrimPlayer(_ player: ICSilenceTrimPlayer, didFailWithError error: Error)
    func silenceTrimPlayerRateDidChange(_ player: ICSilenceTrimPlayer)
    func silenceTrimPlayerDidPlayToEnd(_ player: ICSilenceTrimPlayer)
    /// The renderer dropped enqueued audio by itself (route change, AirPlay rate change) and the
    /// player continued from the flush time.
    @objc optional func silenceTrimPlayerDidFlushAutomatically(_ player: ICSilenceTrimPlayer, atTime time: TimeInterval)
}

@objc(ICSilenceTrimPlayer)
final class ICSilenceTrimPlayer: NSObject, @unchecked Sendable {

    @objc static let errorDomain = "ICSilenceTrimPlayerErrorDomain"
    /// The file is a video or has no usable audio track; the caller should use AVPlayer.
    @objc static let unsupportedMediaErrorCode = 1
    /// Decoding or rendering failed while playing.
    @objc static let playbackErrorCode = 2

    // MARK: Main-thread state

    @objc weak var delegate: ICSilenceTrimPlayerDelegate?
    @objc private(set) var isReady = false
    /// Duration of the file as AVPlayer reports it (AVURLAsset default options).
    @objc private(set) var duration: TimeInterval = 0
    @objc private(set) var url: URL
    /// Number of automatic renderer flushes handled (diagnostics).
    @objc private(set) var automaticFlushCount = 0
    private var requestedRateValue: Float = 1
    private var levelOnMain: ICSilenceTrimLevel
    private var playing = false
    private var invalidated = false
    private var pendingSeekCompletion: ((Bool) -> Void)?

    // MARK: Pipeline state (queue)

    private let queue = DispatchQueue(label: "com.iteconomy.instacast.silencetrim", qos: .userInitiated)
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var asset: AVURLAsset
    private var audioTrack: AVAssetTrack?
    private var reader: AVAssetReader?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var compressor: ICSilenceCompressor?
    private var formatDescription: CMAudioFormatDescription?
    private var sampleRate: Double = 44100
    private var channelCount = 2
    private var levelValue: ICSilenceTrimLevel
    /// Output sample (synchronizer timeline) at which the current compressor session starts.
    private var sessionOutputOrigin: Int64 = 0
    private var generation = 0
    private var endObserver: Any?
    private var readerFinished = false
    private var reportedFailure = false

    // MARK: Shared state (lock)

    private struct MapState {
        var output: [Int64] = []     // absolute output samples, ascending
        var input: [Int64] = []      // matching source samples
        var sampleRate: Double = 44100
        /// Source position used while nothing is mapped yet (after a seek).
        var pendingSource: Double = 0
        /// Savings of finished sessions (seconds of source skipped while played).
        var accumulatedSaved: Double = 0
        var sessionSourceStart: Double = 0
        var sessionOutputStart: Double = 0
        var endOfStreamOutput: Int64?
        var endOfStreamSource: Double = 0
    }
    private let mapLock = OSAllocatedUnfairLock(initialState: MapState())

    private var observers: [NSObjectProtocol] = []

    // MARK: Init

    @objc init(url: URL, level: ICSilenceTrimLevel) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.levelValue = level == .off ? .medium : level
        self.levelOnMain = level == .off ? .medium : level
        super.init()
        synchronizer.addRenderer(renderer)
        // Same time-pitch algorithm as an AVPlayerItem for this file, so a speed setting sounds
        // identical with and without pause shortening.
        renderer.audioTimePitchAlgorithm = AVPlayerItem(asset: asset).audioTimePitchAlgorithm
        renderer.volume = 1
        observeNotifications()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Public API (main thread)

    /// Loads the file and prepares playback at `time` (source seconds).
    @objc func prepare(at time: TimeInterval) {
        let asset = self.asset
        Task { [weak self] in
            do {
                let (loadedDuration, tracks) = try await asset.load(.duration, .tracks)
                var audio: AVAssetTrack?
                var hasMovingVideo = false
                for track in tracks {
                    if track.mediaType == .audio, audio == nil {
                        audio = track
                    } else if track.mediaType == .video {
                        let descriptions = try await track.load(.formatDescriptions)
                        if let description = descriptions.first,
                           CMFormatDescriptionGetMediaSubType(description) != kCMVideoCodecType_JPEG {
                            hasMovingVideo = true
                        }
                    }
                }
                var asbd: AudioStreamBasicDescription?
                if let audio {
                    let descriptions = try await audio.load(.formatDescriptions)
                    if let description = descriptions.first {
                        asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
                    }
                }
                let seconds = loadedDuration.isNumeric ? CMTimeGetSeconds(loadedDuration) : 0
                let sourceChannels = Int(asbd?.mChannelsPerFrame ?? 0)
                let rate = asbd?.mSampleRate ?? 0
                DispatchQueue.main.async {
                    guard let self, !self.invalidated else { return }
                    guard let audio, !hasMovingVideo, sourceChannels >= 1, sourceChannels <= 2, rate >= 8000, seconds > 0 else {
                        self.fail(code: Self.unsupportedMediaErrorCode,
                                  reason: hasMovingVideo ? "video" : (audio == nil ? "no audio track" : "unsupported format \(sourceChannels) ch \(rate) Hz"))
                        return
                    }
                    self.duration = seconds
                    self.queue.async {
                        self.audioTrack = audio
                        self.sampleRate = rate
                        self.channelCount = sourceChannels
                        self.makeFormatDescription()
                        self.mapLock.withLock { $0.sampleRate = rate }
                        self.restartPipeline(atSource: max(0, min(time, seconds)), outputOrigin: 0, resetTimeline: true)
                        DispatchQueue.main.async {
                            guard !self.invalidated else { return }
                            self.isReady = true
                            self.delegate?.silenceTrimPlayerDidBecomeReady(self)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.fail(code: Self.unsupportedMediaErrorCode, reason: "asset load failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Current position in the episode file (seconds).
    @objc var currentTime: TimeInterval {
        let outputSeconds = CMTimeGetSeconds(synchronizer.currentTime())
        return sourceTime(forOutputSeconds: outputSeconds)
    }

    /// Rate of the synchronizer (0 while paused).
    @objc var rate: Float {
        playing ? requestedRateValue : 0
    }

    /// Speed used while playing; applied immediately when playing.
    @objc var requestedRate: Float {
        get { requestedRateValue }
        set {
            let clamped = max(0.5, min(3.0, newValue))
            guard clamped != requestedRateValue else { return }
            requestedRateValue = clamped
            if playing {
                queue.async { self.synchronizer.rate = clamped }
            }
        }
    }

    @objc var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    @objc var level: ICSilenceTrimLevel {
        get { levelOnMain }
        set {
            guard newValue != .off, newValue != levelOnMain else { return }
            levelOnMain = newValue
            queue.async { self.applyLevel(newValue) }
        }
    }

    /// Seconds of the episode skipped so far by shortening pauses (played audio only).
    @objc var savedSeconds: TimeInterval {
        let outputSeconds = CMTimeGetSeconds(synchronizer.currentTime())
        return mapLock.withLock { state -> Double in
            let source = Self.source(in: state, outputSeconds: outputSeconds)
            let sessionSaved = max(0, (source - state.sessionSourceStart) - (outputSeconds - state.sessionOutputStart))
            return state.accumulatedSaved + sessionSaved
        }
    }

    private static let speedupWindow: Double = 30

    /// Source seconds per output second over the last 30 s of played audio (>= 1).
    @objc var pauseSpeedupFactor: Double {
        let now = CMTimeGetSeconds(synchronizer.currentTime())
        return mapLock.withLock { state -> Double in
            // The window must not reach before the oldest retained map point, where the map can
            // no longer tell the source position.
            let oldest = Double(state.output.first ?? 0) / state.sampleRate
            let start = max(state.sessionOutputStart, now - Self.speedupWindow, oldest)
            guard now - start > 2 else { return 1 }
            let sourceNow = Self.source(in: state, outputSeconds: now)
            let sourceStart = Self.source(in: state, outputSeconds: start)
            return max(1, (sourceNow - sourceStart) / (now - start))
        }
    }

    @objc func play() {
        guard !invalidated, !playing else { return }
        playing = true
        let rate = requestedRateValue
        queue.async { self.synchronizer.rate = rate }
        notifyRateChange()
    }

    @objc func pause() {
        guard playing else { return }
        playing = false
        queue.async { self.synchronizer.rate = 0 }
        notifyRateChange()
    }

    /// Like AVPlayer's rate observation, the change is reported after the call returns.
    private func notifyRateChange() {
        DispatchQueue.main.async {
            guard !self.invalidated else { return }
            self.delegate?.silenceTrimPlayerRateDidChange(self)
        }
    }

    /// Seeks to `time` (source seconds). The completion runs on the main thread.
    @objc func seek(to time: TimeInterval, completion: ((Bool) -> Void)?) {
        guard !invalidated else {
            completion?(false)
            return
        }
        let target = max(0, duration > 0 ? min(time, duration) : time)
        pendingSeekCompletion?(false)
        pendingSeekCompletion = completion
        let rate = playing ? requestedRateValue : 0
        queue.async {
            self.restartPipeline(atSource: target, outputOrigin: 0, resetTimeline: true, rate: rate)
            DispatchQueue.main.async {
                let pending = self.pendingSeekCompletion
                self.pendingSeekCompletion = nil
                pending?(true)
            }
        }
    }

    /// Stops everything; the player cannot be used afterwards.
    @objc func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        playing = false
        pendingSeekCompletion?(false)
        pendingSeekCompletion = nil
        queue.async {
            self.synchronizer.rate = 0
            self.generation += 1
            self.renderer.stopRequestingMediaData()
            self.renderer.flush()
            self.reader?.cancelReading()
            self.reader = nil
            self.readerOutput = nil
            self.compressor = nil
            if let observer = self.endObserver {
                self.synchronizer.removeTimeObserver(observer)
                self.endObserver = nil
            }
        }
    }

    // MARK: Time map

    private static func source(in state: MapState, outputSeconds: Double) -> Double {
        let count = state.output.count
        guard count > 0 else { return state.pendingSource }
        let rate = state.sampleRate
        let output = Int64((outputSeconds * rate).rounded(.down))
        if let end = state.endOfStreamOutput, output >= end {
            return state.endOfStreamSource
        }
        if output <= state.output[0] {
            return Double(state.input[0]) / rate
        }
        // Binary search for the last point at or before `output`.
        var low = 0
        var high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if state.output[mid] <= output { low = mid } else { high = mid - 1 }
        }
        if low == count - 1 {
            // Beyond what is enqueued: continue at natural speed.
            return Double(state.input[low] + (output - state.output[low])) / rate
        }
        let o0 = state.output[low], o1 = state.output[low + 1]
        let i0 = state.input[low], i1 = state.input[low + 1]
        let fraction = Double(output - o0) / Double(max(o1 - o0, 1))
        return (Double(i0) + fraction * Double(i1 - i0)) / rate
    }

    private func sourceTime(forOutputSeconds seconds: Double) -> Double {
        mapLock.withLock { Self.source(in: $0, outputSeconds: seconds) }
    }

    // MARK: Pipeline (queue)

    private func makeFormatDescription() {
        var asbd = AudioStreamBasicDescription(mSampleRate: sampleRate,
                                               mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: UInt32(4 * channelCount),
                                               mFramesPerPacket: 1,
                                               mBytesPerFrame: UInt32(4 * channelCount),
                                               mChannelsPerFrame: UInt32(channelCount),
                                               mBitsPerChannel: 32,
                                               mReserved: 0)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       asbd: &asbd,
                                       layoutSize: MemoryLayout<AudioChannelLayout>.size,
                                       layout: &layout,
                                       magicCookieSize: 0,
                                       magicCookie: nil,
                                       extensions: nil,
                                       formatDescriptionOut: &description)
        formatDescription = description
    }

    /// Starts decoding at `source` seconds. With `resetTimeline` the synchronizer jumps to
    /// output time 0 (seek); otherwise output continues at `outputOrigin` (automatic flush,
    /// level change) and the synchronizer keeps running.
    private func restartPipeline(atSource source: TimeInterval, outputOrigin: Int64, resetTimeline: Bool, rate: Float? = nil) {
        generation += 1
        let currentGeneration = generation
        renderer.stopRequestingMediaData()
        if resetTimeline {
            renderer.flush()
        }
        if let observer = endObserver {
            synchronizer.removeTimeObserver(observer)
            endObserver = nil
        }
        reader?.cancelReading()
        reader = nil
        readerOutput = nil
        readerFinished = false

        guard let track = audioTrack else { return }
        let sourceSample = Int64((source * sampleRate).rounded())
        do {
            let newReader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: channelCount,
                AVSampleRateKey: sampleRate,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            newReader.add(output)
            if source > 0 {
                newReader.timeRange = CMTimeRange(start: CMTime(value: sourceSample, timescale: CMTimeScale(sampleRate)),
                                                  duration: .positiveInfinity)
            }
            guard newReader.startReading() else {
                throw newReader.error ?? NSError(domain: Self.errorDomain, code: Self.playbackErrorCode)
            }
            reader = newReader
            readerOutput = output
        } catch {
            reportFailure(reason: "reader start failed: \(error.localizedDescription)")
            return
        }

        let parameters = levelValue.compressorParameters ?? ICSilenceTrimLevel.medium.compressorParameters!
        if let compressor, compressor.sampleRate == sampleRate, compressor.channelCount == channelCount {
            compressor.updateParameters(parameters)
            compressor.reset(atSourceSample: sourceSample)
        } else {
            compressor = ICSilenceCompressor(sampleRate: sampleRate, channelCount: channelCount, parameters: parameters)
            compressor?.reset(atSourceSample: sourceSample)
        }
        sessionOutputOrigin = outputOrigin

        let outputSeconds = Double(outputOrigin) / sampleRate
        mapLock.withLock { state in
            // Close the previous session's savings at the point where it was replaced.
            if !resetTimeline {
                let previousSource = Self.source(in: state, outputSeconds: outputSeconds)
                state.accumulatedSaved += max(0, (previousSource - state.sessionSourceStart) - (outputSeconds - state.sessionOutputStart))
                // Drop map points from the flush point on; they belong to discarded audio.
                if let index = state.output.firstIndex(where: { $0 >= outputOrigin }) {
                    state.output.removeSubrange(index...)
                    state.input.removeSubrange(index...)
                }
            } else {
                let previousOutput = CMTimeGetSeconds(synchronizer.currentTime())
                let previousSource = Self.source(in: state, outputSeconds: previousOutput)
                if !state.output.isEmpty {
                    state.accumulatedSaved += max(0, (previousSource - state.sessionSourceStart) - (previousOutput - state.sessionOutputStart))
                }
                state.output.removeAll(keepingCapacity: true)
                state.input.removeAll(keepingCapacity: true)
            }
            state.pendingSource = source
            state.sessionSourceStart = source
            state.sessionOutputStart = outputSeconds
            state.endOfStreamOutput = nil
        }

        if resetTimeline {
            synchronizer.setRate(rate ?? 0, time: .zero)
        }

        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.provideMediaData(generation: currentGeneration)
        }
    }

    private func provideMediaData(generation requestGeneration: Int) {
        guard requestGeneration == generation else { return }
        if renderer.status == .failed {
            reportFailure(reason: "renderer failed: \(renderer.error?.localizedDescription ?? "unknown")")
            return
        }
        while renderer.isReadyForMoreMediaData {
            guard let buffer = nextSampleBuffer() else {
                if compressor?.isFinished == true {
                    renderer.stopRequestingMediaData()
                    scheduleEndOfStream()
                }
                return
            }
            renderer.enqueue(buffer)
        }
    }

    private func nextSampleBuffer() -> CMSampleBuffer? {
        guard let compressor else { return nil }
        while true {
            if let chunk = compressor.produce(maximumFrames: 4096) {
                return makeSampleBuffer(chunk)
            }
            if compressor.isFinished { return nil }
            if !compressor.wantsInput && readerFinished {
                compressor.finishInput()
                continue
            }
            guard readNextInput() else { return nil }
        }
    }

    /// Feeds one decoded buffer into the compressor. Returns false on a hard failure.
    private func readNextInput() -> Bool {
        guard let reader, let readerOutput, let compressor else { return false }
        if readerFinished {
            compressor.finishInput()
            return true
        }
        guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
            if reader.status == .failed {
                reportFailure(reason: "decoding failed: \(reader.error?.localizedDescription ?? "unknown")")
                return false
            }
            readerFinished = true
            compressor.finishInput()
            return true
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return true }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return true }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &pointer)
        let expected = frames * channelCount * MemoryLayout<Float>.size
        if status == kCMBlockBufferNoErr, let pointer, lengthAtOffset >= expected {
            pointer.withMemoryRebound(to: Float.self, capacity: frames * channelCount) { floats in
                compressor.append(interleaved: UnsafeBufferPointer(start: floats, count: frames * channelCount), frameCount: frames)
            }
        } else {
            // Non-contiguous block buffer: copy it out.
            var copy = [Float](repeating: 0, count: totalLength / MemoryLayout<Float>.size)
            copy.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength, destination: raw.baseAddress!)
            }
            let copiedFrames = min(frames, copy.count / channelCount)
            copy.withUnsafeBufferPointer { floats in
                compressor.append(interleaved: floats, frameCount: copiedFrames)
            }
        }
        return true
    }

    private func makeSampleBuffer(_ chunk: ICSilenceCompressor.Chunk) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }
        let outputStart = sessionOutputOrigin + chunk.outputStart
        // Record the map before the audio can play.
        mapLock.withLock { state in
            for index in 0..<chunk.mapOutput.count {
                let output = sessionOutputOrigin + chunk.mapOutput[index]
                if let last = state.output.last, output <= last { continue }
                state.output.append(output)
                state.input.append(chunk.mapInput[index])
            }
            // Keep what can still be played back plus the history the speed-up factor looks at.
            let played = Int64((CMTimeGetSeconds(synchronizer.currentTime()) - Self.speedupWindow - 5) * state.sampleRate)
            if let first = state.output.first, first < played, state.output.count > 4096 {
                let index = state.output.firstIndex(where: { $0 >= played }) ?? 0
                if index > 1 {
                    state.output.removeFirst(index - 1)
                    state.input.removeFirst(index - 1)
                }
            }
        }
        let byteCount = chunk.samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: byteCount,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil,
                                                        offsetToData: 0,
                                                        dataLength: byteCount,
                                                        flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = chunk.samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: outputStart, timescale: CMTimeScale(sampleRate))
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
                                                                      dataBuffer: block,
                                                                      formatDescription: formatDescription,
                                                                      sampleCount: chunk.frameCount,
                                                                      presentationTimeStamp: pts,
                                                                      packetDescriptions: nil,
                                                                      sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    private func scheduleEndOfStream() {
        guard let compressor, endObserver == nil else { return }
        let endOutput = sessionOutputOrigin + compressor.nextOutputPosition
        let endSource = Double(compressor.nextSourcePosition) / sampleRate
        mapLock.withLock { state in
            state.endOfStreamOutput = endOutput
            state.endOfStreamSource = max(endSource, Double(state.input.max() ?? 0) / state.sampleRate)
        }
        let endTime = CMTime(value: endOutput, timescale: CMTimeScale(sampleRate))
        let currentGeneration = generation
        endObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: queue) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.synchronizer.rate = 0
            DispatchQueue.main.async {
                guard !self.invalidated else { return }
                self.playing = false
                self.delegate?.silenceTrimPlayerDidPlayToEnd(self)
            }
        }
    }

    private func applyLevel(_ newLevel: ICSilenceTrimLevel) {
        guard newLevel != levelValue, let parameters = newLevel.compressorParameters else { return }
        levelValue = newLevel
        guard let compressor else { return }
        // Audio not produced yet uses the new values at once.
        compressor.updateParameters(parameters)
        // Audio already enqueued (seconds locally, minutes with AirPlay buffering) is replaced
        // from the next pause on, so the change is heard soon and never cuts into speech.
        let now = Int64(CMTimeGetSeconds(synchronizer.currentTime()) * sampleRate)
        let earliest = now + Int64(0.3 * sampleRate)
        let candidate: (output: Int64, input: Int64)? = mapLock.withLock { state in
            guard state.output.count > 1 else { return nil }
            for index in 1..<state.output.count where state.output[index] >= earliest {
                let deltaInput = state.input[index] - state.input[index - 1]
                let deltaOutput = state.output[index] - state.output[index - 1]
                if deltaInput != deltaOutput {
                    // First hop of a shortened pause: restart one hop earlier, still inside it.
                    return (state.output[index - 1], state.input[index - 1])
                }
            }
            return nil
        }
        guard let point = candidate else { return }
        let enqueuedEnd = sessionOutputOrigin + compressor.nextOutputPosition
        guard point.output < enqueuedEnd - Int64(0.5 * sampleRate) else { return }
        let flushTime = CMTime(value: point.output, timescale: CMTimeScale(sampleRate))
        let currentGeneration = generation
        renderer.stopRequestingMediaData()
        renderer.flush(fromSourceTime: flushTime) { [weak self] succeeded in
            guard let self else { return }
            self.queue.async {
                guard currentGeneration == self.generation else { return }
                if succeeded {
                    self.restartPipeline(atSource: Double(point.input) / self.sampleRate, outputOrigin: point.output, resetTimeline: false)
                } else {
                    // The point was already rendered; keep the old audio and continue.
                    self.renderer.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                        self?.provideMediaData(generation: currentGeneration)
                    }
                }
            }
        }
    }

    // MARK: Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default
        // AirPlay and other route changes flush the renderer; continue from the flush time.
        observers.append(center.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
                                            object: renderer, queue: nil) { [weak self] notification in
            guard let self else { return }
            let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self.queue.async { self.handleAutomaticFlush(at: flushTime) }
        })
#if canImport(UIKit)
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.reportFailure(reason: "media services were reset") }
        })
#endif
    }

    private func handleAutomaticFlush(at flushTime: CMTime?) {
        guard !reportedFailure, compressor != nil else { return }
        let time = (flushTime?.isNumeric == true) ? flushTime! : synchronizer.currentTime()
        let output = max(0, Int64(CMTimeGetSeconds(time) * sampleRate))
        let source = sourceTime(forOutputSeconds: Double(output) / sampleRate)
        restartPipeline(atSource: source, outputOrigin: output, resetTimeline: false)
        DispatchQueue.main.async {
            guard !self.invalidated else { return }
            self.automaticFlushCount += 1
            self.delegate?.silenceTrimPlayerDidFlushAutomatically?(self, atTime: source)
        }
    }

    // MARK: Failure

    private func reportFailure(reason: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        renderer.stopRequestingMediaData()
        DispatchQueue.main.async {
            self.fail(code: Self.playbackErrorCode, reason: reason)
        }
    }

    private func fail(code: Int, reason: String) {
        guard !invalidated else { return }
        let error = NSError(domain: Self.errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: reason])
        delegate?.silenceTrimPlayer(self, didFailWithError: error)
    }
}
