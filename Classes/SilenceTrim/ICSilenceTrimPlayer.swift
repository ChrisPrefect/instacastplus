//
//  ICSilenceTrimPlayer.swift
//  InstacastPlus
//
//  Plays an episode with shortened pauses: a local file, or a stream that the app's stream cache
//  is still downloading. It only runs while pause shortening is active for the playing episode;
//  every other case keeps using PlaybackManager's AVPlayer.
//
//  Pipeline:
//    AVAssetReader (LPCM float, own queue per session, see DecodeFeed) -> ICSilenceCompressor
//      -> CMSampleBuffer -> AVSampleBufferAudioRenderer attached to an
//      AVSampleBufferRenderSynchronizer (serial `queue`).
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

/// The app's stream cache (ICStreamingCacheLoader): it serves the stream asset's loading requests
/// from the partly downloaded file and downloads what is missing, the newest request first.
@objc(ICSilenceTrimStreamSource)
protocol ICSilenceTrimStreamSource: AVAssetResourceLoaderDelegate {
    var resourceLoaderQueue: DispatchQueue { get }
    /// Ends these requests with NSURLErrorCancelled and stops downloading for them.
    func abandonLoadingRequests(_ requests: [AVAssetResourceLoadingRequest])
}

@objc protocol ICSilenceTrimPlayerDelegate: AnyObject {
    func silenceTrimPlayerDidBecomeReady(_ player: ICSilenceTrimPlayer)
    func silenceTrimPlayer(_ player: ICSilenceTrimPlayer, didFailWithError error: Error)
    func silenceTrimPlayerRateDidChange(_ player: ICSilenceTrimPlayer)
    func silenceTrimPlayerDidPlayToEnd(_ player: ICSilenceTrimPlayer)
    /// The renderer dropped enqueued audio by itself (route change, AirPlay rate change) and the
    /// player continued from the flush time.
    @objc optional func silenceTrimPlayerDidFlushAutomatically(_ player: ICSilenceTrimPlayer, atTime time: TimeInterval)
    /// A stream ran out of downloaded audio and the clock stopped, or it continues.
    @objc optional func silenceTrimPlayerWaitingForDataDidChange(_ player: ICSilenceTrimPlayer)
}

@objc(ICSilenceTrimPlayer)
final class ICSilenceTrimPlayer: NSObject, @unchecked Sendable {

    @objc static let errorDomain = "ICSilenceTrimPlayerErrorDomain"
    /// The file is a video or has no usable audio track; the caller should use AVPlayer.
    @objc static let unsupportedMediaErrorCode = 1
    /// Decoding or rendering failed while playing.
    @objc static let playbackErrorCode = 2
    /// Decoding the stream failed before its file was complete (connection lost, stream cache
    /// failed); the complete file may still play.
    @objc static let streamErrorCode = 3

    // MARK: Main-thread state

    @objc weak var delegate: ICSilenceTrimPlayerDelegate?
    @objc private(set) var isReady = false
    /// Duration of the file as AVPlayer reports it (AVURLAsset default options).
    @objc private(set) var duration: TimeInterval = 0
    @objc private(set) var url: URL
    /// Number of automatic renderer flushes handled (diagnostics).
    @objc private(set) var automaticFlushCount = 0
    /// Decodes a stream through the app's stream cache (`init(streamURL:...)`).
    @objc let isStream: Bool
    /// The stream ran out of downloaded audio and the clock stands still.
    @objc private(set) var isWaitingForData = false
    /// Number of times the clock stopped for missing stream data (diagnostics).
    @objc private(set) var dataWaitCount = 0
    /// Decoder restarts after a stream read timed out (diagnostics, pipeline queue).
    var streamTimeoutRestarts = 0
    /// Pause-detection switches: output sample and source sample where the new compressor took over
    /// (test diagnostics, pipeline queue).
    var detectionSwitches: [(output: Int64, source: Int64)] = []
    /// Every session start: output origin, source sample, precise, end of the enqueued audio
    /// before the restart (test diagnostics, pipeline queue).
    var sessionLog: [(output: Int64, source: Int64, precise: Bool, enqueuedBefore: Int64, reset: Bool)] = []

    /// Test seam, Swift-internal (invisible to the app's Objective-C code and unset in the app):
    /// reports every buffer handed to the renderer and every flush, in pipeline order, so a test
    /// can rebuild the audio that actually plays.
    enum RenderEvent {
        case enqueue(CMSampleBuffer)
        case flushAll
        case flushFrom(CMTime)
    }
    var renderEventObserver: ((RenderEvent) -> Void)?
    /// Level changes whose partial flush the renderer refused (test diagnostics).
    var partialFlushRefusals = 0
    /// Switches from the instant-start decoder to the precise one (test diagnostics).
    var realignCount = 0
    var lastRealign: (output: Int64, source: Int64)?
    /// Restarts after automatic flushes: first flushed output sample and the source sample the
    /// audio continued from (test diagnostics).
    var automaticFlushRestarts: [(output: Int64, source: Int64)] = []
    /// Whether the current session decodes with exact sample positions.
    var decodesPrecisely: Bool { sessionIsPrecise }
    /// Whether the precise decoder finished warming up.
    var hasPreciseDecoder: Bool { preciseAsset != nil }
    private var requestedRateValue: Float = 1
    private var levelOnMain: ICSilenceTrimLevel
    private var playing = false
    private var invalidated = false
    private var pendingSeekCompletion: ((Bool) -> Void)?

    // MARK: Pipeline state (queue)

    private let queue = DispatchQueue(label: "com.iteconomy.instacast.silencetrim", qos: .userInitiated)
    let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var asset: AVURLAsset
    private var audioTrack: AVAssetTrack?
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
    /// Source sample where the compressor input starts; decoded audio before it is pre-roll.
    private var compressorInputStart: Int64 = 0
    // Exact positions: without AVURLAssetPreferPreciseDurationAndTimingKey, AVAssetReader places
    // a mid-file MP3 start one frame (1152 samples, 26 ms) off depending on the asset's state
    // (measured 20.11.2026). The precise asset needs a scan of the whole file first (0.5-2.8 s
    // on an M2), so playback starts with the normal asset, the precise one warms up in the
    // background, and the session switches over inside the next shortened pause, where a
    // one-frame step is silence. From then on every restart continues sample-exactly.
    private var preciseAsset: AVURLAsset?
    private var preciseTrack: AVAssetTrack?
    private var sessionIsPrecise = false
    private var pendingRealign = false
    /// The pause detection changed; a new compressor takes over at the next silent pause.
    private var pendingDetectionSwitch = false
    private var reportedFailure = false
    /// The stream's file, once complete on the device; it becomes the precise decoder.
    private var completeFileURL: URL?
    private let streamTracker: StreamRequestTracker?
    private var ownedHTTPSource: ICSilenceTrimHTTPSource?
    // Decoding runs ahead on the feed's own queue (see DecodeFeed). When the feed is empty the
    // pipeline stops asking for data until the feed reports input.
    private var feed: DecodeFeed?
    private var waitingForInput = false
    private var dataWaitObserver: Any?
    /// The renderer holds all it wants (or the file ended): the analysis reaches as far as it will
    /// for now. Silent-point queries are answered then.
    private var pipelineIdle = false
    private var silentPointQueries: [(TimeInterval, @Sendable (TimeInterval) -> Void)] = []
    /// Stream reads that timed out in a row without new input (see readNextInput).
    private var streamTimeouts = 0
    private static let maximumStreamTimeouts = 3
    /// Seconds of enqueued audio left when the clock stops for missing data, and seconds that
    /// have to be enqueued before it runs again.
    private static let dataWaitMargin = 0.1
    private static let dataResumeAhead = 1.0
    /// Decoded ahead per session (frames = seconds x sample rate).
    private static let decodeAheadSeconds = 4.0

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
        /// Output sample of every enqueued buffer that may still be flushed (ascending).
        var bufferStarts: [Int64] = []
    }
    private let mapLock = OSAllocatedUnfairLock(initialState: MapState())

    /// Rate the clock should run at (0 while paused). Play, pause and speed changes set the
    /// synchronizer on the calling thread, so the position stands still the moment `pause()`
    /// returns, as with AVPlayer (set asynchronously it ran on for up to 3 ms, measured
    /// 20.11.2026). A seek or prepare queued earlier reads this value under the same lock when
    /// it resets the timeline, so it can neither restart a paused clock nor stop a playing one.
    private let clockLock = NSLock()
    private var clockRate: Float = 0
    /// The clock is held at 0 until enough audio is enqueued: after every seek and while a stream
    /// waits for data. The synchronizer runs on without audio otherwise, also with
    /// delaysRateChangeUntilHasSufficientMediaData (measured 21.11.2026: 0.84 s after
    /// setRate(1) without any data; audio enqueued later lay in the past).
    private var clockHeld = true
    /// End (source seconds) of the decoded audio, for the playable range of a stream.
    private let decodedEnd = OSAllocatedUnfairLock(initialState: 0.0)

    private var observers: [NSObjectProtocol] = []

    // MARK: Init

    /// Whether speech detection was asked for; `speechDetectionActive` tells whether it runs
    /// (the model is part of the app bundle, so it only fails to load in a broken build).
    @objc private(set) var requestedSpeechDetection: Bool
    @objc var speechDetectionActive: Bool { speechDetectionOnMain }
    private var speechDetectionOnMain: Bool
    /// Pipeline queue.
    private var speechModel: ICSileroVADModel?

    @objc convenience init(url: URL, level: ICSilenceTrimLevel) {
        self.init(url: url, level: level, speechDetection: false)
    }

    @objc convenience init(url: URL, level: ICSilenceTrimLevel, speechDetection: Bool) {
        self.init(url: url, asset: AVURLAsset(url: url), tracker: nil, level: level, speechDetection: speechDetection)
    }

    /// Plays the stream cache's asset URL. AVAssetReader refuses http URLs (AVError -11838) but
    /// reads through a resource loader; the stream cache serves the downloaded bytes and fetches
    /// the missing ones first.
    @objc convenience init(streamURL: URL, source: ICSilenceTrimStreamSource, level: ICSilenceTrimLevel, speechDetection: Bool) {
        let asset = AVURLAsset(url: streamURL)
        let tracker = StreamRequestTracker(source: source)
        asset.resourceLoader.setDelegate(tracker, queue: source.resourceLoaderQueue)
        self.init(url: streamURL, asset: asset, tracker: tracker, level: level, speechDetection: speechDetection)
    }

    /// Plays a stream the app does not keep (stream caching off): ICSilenceTrimHTTPSource fetches
    /// the requested ranges into a temporary file that is deleted when the player is invalidated.
    @objc convenience init(remoteURL: URL, username: String?, password: String?, mimeType: String?,
                           level: ICSilenceTrimLevel, speechDetection: Bool) {
        let source = ICSilenceTrimHTTPSource(remoteURL: remoteURL, username: username, password: password, mimeType: mimeType)
        self.init(streamURL: URL(string: "instacast-silencetrim-stream://\(UUID().uuidString)")!, source: source,
                  level: level, speechDetection: speechDetection)
        ownedHTTPSource = source
    }

    /// Reads the stream with its own HTTP source instead of the app's stream cache.
    @objc var readsStreamItself: Bool { ownedHTTPSource != nil }

    /// For the app's chapter and artwork reading: an asset answered from this player's own
    /// download, so the stream crosses the network once. Nil unless the player reads the stream
    /// itself.
    @objc func makeMetadataAsset() -> AVURLAsset? {
        ownedHTTPSource?.makeMetadataAsset()
    }

    private init(url: URL, asset: AVURLAsset, tracker: StreamRequestTracker?, level: ICSilenceTrimLevel, speechDetection: Bool) {
        self.requestedSpeechDetection = speechDetection
        self.speechModel = speechDetection ? ICSileroVADModel.bundled : nil
        self.speechDetectionOnMain = speechModel != nil
        self.url = url
        self.asset = asset
        self.streamTracker = tracker
        self.isStream = tracker != nil
        self.levelValue = level
        self.levelOnMain = level
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
        ownedHTTPSource?.stop()
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
                        // A stream has no precise decoder until its file is complete: the
                        // precise asset reads the whole file first (measured: all 140 MB of a
                        // 2.5 h episode before the first sample).
                        if let preciseURL = self.isStream ? self.completeFileURL : self.url {
                            self.warmUpPreciseTiming(from: preciseURL)
                        }
                        DispatchQueue.main.async {
                            guard !self.invalidated else { return }
                            self.isReady = true
                            self.delegate?.silenceTrimPlayerDidBecomeReady(self)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    // A stream that cannot be opened is a lost connection, not an unusable file.
                    guard let self else { return }
                    self.fail(code: self.isStream ? Self.streamErrorCode : Self.unsupportedMediaErrorCode,
                              reason: "asset load failed: \(error.localizedDescription)")
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

    /// End of the decoded audio (source seconds); the whole file once it is local.
    @objc var bufferedTime: TimeInterval {
        decodedEnd.withLock { $0 }
    }

    /// The stream's file is complete on the device. Decoding moves to it at the next silent
    /// pause (with exact sample positions from then on); the stream is not read any more.
    @objc func adoptCompleteFile(at fileURL: URL) {
        guard isStream else { return }
        queue.async {
            guard self.completeFileURL == nil, !self.reportedFailure else { return }
            self.completeFileURL = fileURL
            if self.audioTrack != nil {
                self.warmUpPreciseTiming(from: fileURL)
            }
        }
    }

    /// Whether decoding reads the stream's complete file (diagnostics).
    @objc var decodesCompleteFile: Bool { isStream && sessionIsPrecise }

    /// Waiting stream requests of replaced decoders that were withdrawn (diagnostics).
    @objc var withdrawnStreamRequests: Int { streamTracker?.withdrawnCount ?? 0 }

    /// Speed used while playing; applied immediately when playing.
    @objc var requestedRate: Float {
        get { requestedRateValue }
        set {
            let clamped = max(0.5, min(3.0, newValue))
            guard clamped != requestedRateValue else { return }
            requestedRateValue = clamped
            if playing {
                setClockRate(clamped)
            }
        }
    }

    @objc var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// `.off` keeps playing without shortening (passthrough); see ICSilenceTrimLevel.
    @objc var level: ICSilenceTrimLevel {
        get { levelOnMain }
        set {
            guard newValue != levelOnMain else { return }
            levelOnMain = newValue
            queue.async { self.applyLevel(newValue) }
        }
    }

    /// Switches between speech detection (Silero) and the level detection while playing. A new
    /// compressor takes over at the next shortened pause that is truly silent, primed, like the
    /// switch to the precise decoder: a restart without that decoder may sit one MP3 frame off,
    /// which mid-speech clicked (measured 21.11.2026, ATP 717: step x5.1 at -13 dB).
    @objc func setSpeechDetection(_ enabled: Bool) {
        guard enabled != requestedSpeechDetection else { return }
        requestedSpeechDetection = enabled
        let model = enabled ? ICSileroVADModel.bundled : nil
        speechDetectionOnMain = model != nil
        queue.async {
            self.speechModel = model
            self.pendingDetectionSwitch = self.compressor != nil
        }
    }

    /// Finds the first silent point (level detection, ± 60 ms silent) at or after `time` (source
    /// seconds) in the audio analysed so far. The completion runs on the main thread with the
    /// source time, or -1 when there is none yet.
    /// The answer waits until the pipeline has filled the renderer, i.e. analysed as far ahead as
    /// it goes (about 2 s plus the planning look-ahead).
    @objc func findSilentPoint(after time: TimeInterval, completion: @escaping @Sendable (TimeInterval) -> Void) {
        queue.async {
            self.silentPointQueries.append((time, completion))
            if self.pipelineIdle || self.reportedFailure {
                self.answerSilentPointQueries()
            }
        }
    }

    /// Pipeline queue.
    private func answerSilentPointQueries() {
        let queries = silentPointQueries
        silentPointQueries.removeAll()
        for (time, completion) in queries {
            var found: TimeInterval = -1
            if !reportedFailure, let compressor,
               let sample = compressor.firstSilentSample(atOrAfter: Int64((time * sampleRate).rounded()),
                                                         margin: Int64(0.06 * sampleRate)) {
                found = Double(sample) / sampleRate
            }
            let answer = found
            DispatchQueue.main.async { completion(answer) }
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
        setClockRate(requestedRateValue)
        notifyRateChange()
    }

    @objc func pause() {
        guard playing else { return }
        playing = false
        setClockRate(0)
        notifyRateChange()
    }

    /// Sets the clock now (any thread); see `clockLock`.
    private func setClockRate(_ rate: Float) {
        clockLock.lock()
        clockRate = rate
        synchronizer.rate = clockHeld ? 0 : rate
        clockLock.unlock()
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
        queue.async {
            self.restartPipeline(atSource: target, outputOrigin: 0, resetTimeline: true)
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
        setClockRate(0)
        queue.async {
            self.generation += 1
            self.renderer.stopRequestingMediaData()
            self.renderer.flush()
            self.feed?.cancel()
            self.feed = nil
            self.streamTracker?.beginDecoderSession()
            self.ownedHTTPSource?.stop()
            self.compressor = nil
            self.removeDataWaitObserver()
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

    /// Source sample a restart at `output` has to continue from: the last hop start at or before
    /// it plus the offset into that hop. That is the grain fading in there, so a primed restart
    /// goes on sample-exactly wherever the audio is unshortened, including the last hop before a
    /// shortened pause. Interpolating towards the next map point (as `source` does for the
    /// display) would skip up to several milliseconds of the speech's decay there.
    private static func sourceSample(in state: MapState, output: Int64) -> Int64 {
        guard let first = state.output.first, output >= first else {
            return Int64((source(in: state, outputSeconds: Double(output) / state.sampleRate) * state.sampleRate).rounded())
        }
        var low = 0
        var high = state.output.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if state.output[mid] <= output { low = mid } else { high = mid - 1 }
        }
        return state.input[low] + (output - state.output[low])
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
    private func restartPipeline(atSource source: TimeInterval, outputOrigin: Int64, resetTimeline: Bool,
                                 sourceSample exactSample: Int64? = nil, primed: Bool = false) {
        generation += 1
        let currentGeneration = generation
        renderer.stopRequestingMediaData()
        if resetTimeline {
            renderer.flush()
            renderEventObserver?(.flushAll)
        }
        if let observer = endObserver {
            synchronizer.removeTimeObserver(observer)
            endObserver = nil
        }
        // The replaced feed stops on its own queue; its waiting stream requests are withdrawn.
        feed?.cancel()
        feed = nil
        streamTracker?.beginDecoderSession()
        waitingForInput = false
        pipelineIdle = false
        removeDataWaitObserver()
        readerFinished = false

        guard let defaultTrack = audioTrack else { return }
        if renderEventObserver != nil {
            sessionLog.append((outputOrigin, exactSample ?? Int64((source * sampleRate).rounded()), preciseAsset != nil, enqueuedEnd, resetTimeline))
        }
        let decodeAsset = preciseAsset ?? asset
        let track = preciseTrack ?? defaultTrack
        sessionIsPrecise = preciseAsset != nil
        if sessionIsPrecise { pendingRealign = false }
        let sourceSample = exactSample ?? Int64((source * sampleRate).rounded())

        // The compressor decides where its input has to start (one hop earlier when primed).
        let parameters = levelValue.playbackParameters
        if compressor == nil || compressor?.sampleRate != sampleRate || compressor?.channelCount != channelCount {
            compressor = ICSilenceCompressor(sampleRate: sampleRate, channelCount: channelCount, parameters: parameters, speechModel: speechModel)
        }
        guard let compressor else { return }
        compressor.updateParameters(parameters)
        compressor.reset(atSourceSample: sourceSample, primed: primed)
        // MP3/AAC decoders need pre-roll: AVAssetReader starts at the exact sample, but the first
        // up to ~60 ms it decodes after a mid-file start are wrong (measured 20.11.2026, up to
        // 2445 samples on real episodes). Decode 0.2 s earlier and drop that part.
        compressorInputStart = compressor.sessionStart
        let preroll = Int64(0.2 * sampleRate)
        let readerStart = max(0, compressorInputStart - preroll)

        do {
            let newReader = try AVAssetReader(asset: decodeAsset)
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
            if readerStart > 0 {
                newReader.timeRange = CMTimeRange(start: CMTime(value: readerStart, timescale: CMTimeScale(sampleRate)),
                                                  duration: .positiveInfinity)
            }
            guard newReader.startReading() else {
                throw newReader.error ?? NSError(domain: Self.errorDomain, code: Self.playbackErrorCode)
            }
            let newFeed = DecodeFeed(reader: newReader, output: output,
                                     maximumFrames: Int(Self.decodeAheadSeconds * sampleRate))
            let rate = sampleRate
            newFeed.onDecoded = { [weak self] end in
                self?.decodedEnd.withLock { $0 = max($0, Double(end) / rate) }
            }
            newFeed.onInput = { [weak self] in
                guard let self else { return }
                self.queue.async { self.feedHasInput(generation: currentGeneration) }
            }
            feed = newFeed
            newFeed.start()
        } catch {
            reportFailure(reason: "reader start failed: \(error.localizedDescription)")
            return
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
                state.bufferStarts.removeAll { $0 >= outputOrigin }
            } else {
                let previousOutput = CMTimeGetSeconds(synchronizer.currentTime())
                let previousSource = Self.source(in: state, outputSeconds: previousOutput)
                if !state.output.isEmpty {
                    state.accumulatedSaved += max(0, (previousSource - state.sessionSourceStart) - (previousOutput - state.sessionOutputStart))
                }
                state.output.removeAll(keepingCapacity: true)
                state.input.removeAll(keepingCapacity: true)
                state.bufferStarts.removeAll(keepingCapacity: true)
            }
            state.pendingSource = source
            state.sessionSourceStart = source
            state.sessionOutputStart = outputSeconds
            state.endOfStreamOutput = nil
        }

        if resetTimeline {
            // Held at 0 until the new position has audio (see `clockHeld`).
            clockLock.lock()
            clockHeld = true
            synchronizer.setRate(0, time: .zero)
            clockLock.unlock()
            decodedEnd.withLock { $0 = source }
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
            if pendingRealign || pendingDetectionSwitch, let compressor, compressor.nextHopIsSilentPause {
                realignAtEnqueuedHead(compressor)
                return
            }
            switch nextSampleBuffer() {
            case .buffer(let buffer):
                renderer.enqueue(buffer)
                renderEventObserver?(.enqueue(buffer))
                releaseClockIfBuffered(force: false)
            case .waitForInput:
                // The feed reports new input (feedHasInput); until then the renderer plays
                // what it has and the clock stops shortly before that runs out.
                waitingForInput = true
                renderer.stopRequestingMediaData()
                armDataWait()
                return
            case .none:
                if compressor?.isFinished == true {
                    renderer.stopRequestingMediaData()
                    scheduleEndOfStream()
                    releaseClockIfBuffered(force: true)
                    pipelineIdle = true
                    answerSilentPointQueries()
                }
                return
            case .restarted:
                return
            }
        }
        // The renderer holds all it wants.
        releaseClockIfBuffered(force: true)
        pipelineIdle = true
        answerSilentPointQueries()
    }

    private enum NextBuffer {
        case buffer(CMSampleBuffer)
        case waitForInput
        case none
        /// A new session took over; it requests its own data.
        case restarted
    }

    private func nextSampleBuffer() -> NextBuffer {
        guard let compressor else { return .none }
        while true {
            if let chunk = compressor.produce(maximumFrames: 4096) {
                guard let buffer = makeSampleBuffer(chunk) else { return .none }
                return .buffer(buffer)
            }
            if compressor.isFinished { return .none }
            if !compressor.wantsInput && readerFinished {
                compressor.finishInput()
                continue
            }
            switch readNextInput() {
            case .fed: continue
            case .waitForInput: return .waitForInput
            case .failed: return .none
            case .restarted: return .restarted
            }
        }
    }

    private enum InputResult { case fed, waitForInput, failed, restarted }

    /// Feeds one decoded buffer into the compressor.
    private func readNextInput() -> InputResult {
        guard let feed, let compressor else { return .failed }
        if readerFinished {
            compressor.finishInput()
            return .fed
        }
        let sampleBuffer: CMSampleBuffer
        switch feed.next() {
        case .buffer(let buffer):
            sampleBuffer = buffer
            streamTimeouts = 0
        case .waitForInput:
            return .waitForInput
        case .finished:
            readerFinished = true
            compressor.finishInput()
            return .fed
        case .failed(let error):
            // Before its file is complete a stream fails for the connection or the stream cache.
            let streamFailure = isStream && !sessionIsPrecise
            // AVFoundation ends a loading request after about 9 s without data (NSURLError
            // -1001, measured 21.11.2026), while the stream cache keeps downloading for up to
            // 30 s. A new decoder continues at the end of the enqueued audio, primed; without the
            // precise decoder that may be one MP3 frame off, after at least 9 s of silence.
            if streamFailure, (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorTimedOut,
               streamTimeouts < Self.maximumStreamTimeouts {
                streamTimeouts += 1
                streamTimeoutRestarts += 1
                restartAtEnqueuedEnd()
                return .restarted
            }
            reportFailure(reason: "decoding failed: \(error.localizedDescription)", code: streamFailure ? Self.streamErrorCode : Self.playbackErrorCode)
            return .failed
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return .fed }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return .fed }
        // Skip the decoder pre-roll in front of the compressor's start.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let firstSample = pts.isNumeric ? pts.convertScale(CMTimeScale(sampleRate), method: .roundHalfAwayFromZero).value : compressorInputStart
        let skip = Int(max(0, min(Int64(frames), compressorInputStart - firstSample)))
        guard skip < frames else { return .fed }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &pointer)
        let expected = frames * channelCount * MemoryLayout<Float>.size
        if status == kCMBlockBufferNoErr, let pointer, lengthAtOffset >= expected {
            pointer.withMemoryRebound(to: Float.self, capacity: frames * channelCount) { floats in
                compressor.append(interleaved: UnsafeBufferPointer(start: floats + skip * channelCount, count: (frames - skip) * channelCount),
                                  frameCount: frames - skip)
            }
        } else {
            // Non-contiguous block buffer: copy it out.
            var copy = [Float](repeating: 0, count: totalLength / MemoryLayout<Float>.size)
            copy.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength, destination: raw.baseAddress!)
            }
            let copiedFrames = min(frames, copy.count / channelCount)
            guard skip < copiedFrames else { return .fed }
            copy.withUnsafeBufferPointer { floats in
                compressor.append(interleaved: UnsafeBufferPointer(rebasing: floats[(skip * channelCount)..<(copiedFrames * channelCount)]),
                                  frameCount: copiedFrames - skip)
            }
        }
        return .fed
    }

    /// Continues with a new session where the enqueued audio ends: the same continuation point as
    /// after an automatic flush there, primed, so nothing is lost or repeated.
    private func restartAtEnqueuedEnd(newCompressor: Bool = false) {
        let output = enqueuedEnd
        let sample = mapLock.withLock { state in
            state.output.isEmpty ? Int64((state.pendingSource * sampleRate).rounded()) : Self.sourceSample(in: state, output: output)
        }
        if newCompressor {
            // restartPipeline builds it with the current speech model.
            compressor = nil
        }
        restartPipeline(atSource: Double(sample) / sampleRate, outputOrigin: output, resetTimeline: false,
                        sourceSample: sample, primed: true)
    }

    // MARK: Waiting for stream data (queue)

    /// Output sample where the enqueued audio ends.
    private var enqueuedEnd: Int64 {
        sessionOutputOrigin + (compressor?.nextOutputPosition ?? 0)
    }

    private func feedHasInput(generation requestGeneration: Int) {
        guard requestGeneration == generation, waitingForInput, !reportedFailure else { return }
        waitingForInput = false
        removeDataWaitObserver()
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.provideMediaData(generation: requestGeneration)
        }
    }

    /// Stops the clock shortly before the enqueued audio runs out, unless input arrives first.
    private func armDataWait() {
        removeDataWaitObserver()
        let margin = Int64(Self.dataWaitMargin * sampleRate)
        let boundary = enqueuedEnd - margin
        let now = synchronizer.currentTime().convertScale(CMTimeScale(sampleRate), method: .roundTowardNegativeInfinity).value
        guard boundary > now else {
            holdClockForData()
            return
        }
        let currentGeneration = generation
        dataWaitObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(value: boundary, timescale: CMTimeScale(sampleRate)))],
                                                                queue: queue) { [weak self] in
            guard let self, self.generation == currentGeneration, self.waitingForInput else { return }
            self.holdClockForData()
        }
    }

    private func removeDataWaitObserver() {
        if let observer = dataWaitObserver {
            synchronizer.removeTimeObserver(observer)
            dataWaitObserver = nil
        }
    }

    private func holdClockForData() {
        clockLock.lock()
        let wasHeld = clockHeld
        clockHeld = true
        synchronizer.rate = 0
        clockLock.unlock()
        guard !wasHeld else { return }
        DispatchQueue.main.async {
            guard !self.invalidated else { return }
            self.dataWaitCount += 1
            self.isWaitingForData = true
            self.delegate?.silenceTrimPlayerWaitingForDataDidChange?(self)
        }
    }

    /// Lets the clock run once enough audio is enqueued (`force`: the renderer is full or the
    /// file ends).
    private func releaseClockIfBuffered(force: Bool) {
        clockLock.lock()
        guard clockHeld else {
            clockLock.unlock()
            return
        }
        if !force {
            let ahead = Double(enqueuedEnd) / sampleRate - CMTimeGetSeconds(synchronizer.currentTime())
            guard ahead >= Self.dataResumeAhead else {
                clockLock.unlock()
                return
            }
        }
        clockHeld = false
        synchronizer.rate = clockRate
        clockLock.unlock()
        DispatchQueue.main.async {
            guard !self.invalidated, self.isWaitingForData else { return }
            self.isWaitingForData = false
            self.delegate?.silenceTrimPlayerWaitingForDataDidChange?(self)
        }
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
            state.bufferStarts.append(outputStart)
            // Keep what can still be played back plus the history the speed-up factor looks at.
            let played = Int64((CMTimeGetSeconds(synchronizer.currentTime()) - Self.speedupWindow - 5) * state.sampleRate)
            if let first = state.output.first, first < played, state.output.count > 4096 {
                let index = state.output.firstIndex(where: { $0 >= played }) ?? 0
                if index > 1 {
                    state.output.removeFirst(index - 1)
                    state.input.removeFirst(index - 1)
                }
            }
            if let first = state.bufferStarts.first, first < played {
                state.bufferStarts.removeAll { $0 < played }
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

    /// Loads the precise asset off the pipeline queue, including its file scan.
    private func warmUpPreciseTiming(from url: URL) {
        Task.detached(priority: .utility) { [weak self] in
            let precise = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try? await precise.loadTracks(withMediaType: .audio).first,
                  let duration = try? await precise.load(.duration), duration.isNumeric,
                  let reader = try? AVAssetReader(asset: precise) else { return }
            // Reading near the end performs the scan here instead of in the first seek.
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: CMTimeMultiplyByFloat64(duration, multiplier: 0.95), duration: .positiveInfinity)
            guard reader.startReading() else { return }
            _ = output.copyNextSampleBuffer()
            reader.cancelReading()
            guard let self else { return }
            self.queue.async {
                guard !self.reportedFailure, self.compressor != nil else { return }
                self.preciseAsset = precise
                self.preciseTrack = track
                if !self.sessionIsPrecise { self.pendingRealign = true }
            }
        }
    }

    /// Continues the current session with the precise decoder at the head of the enqueued
    /// audio, which lies inside a shortened pause. Nothing is flushed.
    private func realignAtEnqueuedHead(_ compressor: ICSilenceCompressor) {
        let output = sessionOutputOrigin + compressor.nextOutputPosition
        let source = compressor.nextSourcePosition
        if pendingRealign && preciseAsset != nil {
            realignCount += 1
            lastRealign = (output, source)
        }
        pendingRealign = false
        if pendingDetectionSwitch {
            pendingDetectionSwitch = false
            // restartPipeline builds the new one with the current speech model.
            self.compressor = nil
            detectionSwitches.append((output, source))
        }
        restartPipeline(atSource: Double(source) / sampleRate, outputOrigin: output, resetTimeline: false,
                        sourceSample: source, primed: true)
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
            self.setClockRate(0)
            DispatchQueue.main.async {
                guard !self.invalidated else { return }
                self.playing = false
                self.delegate?.silenceTrimPlayerDidPlayToEnd(self)
            }
        }
    }

    private func applyLevel(_ newLevel: ICSilenceTrimLevel) {
        guard newLevel != levelValue else { return }
        let parameters = newLevel.playbackParameters
        levelValue = newLevel
        guard let compressor else { return }
        // Audio not produced yet uses the new values at once.
        compressor.updateParameters(parameters)
        // Audio already enqueued (seconds locally, minutes with AirPlay buffering) is replaced.
        // The cut lies on a buffer start, where flush(fromSourceTime:) removes whole buffers, and
        // on a hop that plays unshortened, so the primed restart continues the kept audio sample
        // for sample; the new level takes over at the next pause.
        let now = CMTimeGetSeconds(synchronizer.currentTime())
        let earliest = Int64((now + 0.3) * sampleRate)
        let candidate: (output: Int64, input: Int64)? = mapLock.withLock { state in
            for start in state.bufferStarts where start >= earliest {
                guard let index = state.output.firstIndex(of: start), index > 0 else { continue }
                if state.input[index] - state.input[index - 1] == state.output[index] - state.output[index - 1] {
                    return (start, state.input[index])
                }
            }
            return nil
        }
        guard let point = candidate else { return }
        let flushTime = CMTime(value: point.output, timescale: CMTimeScale(sampleRate))
        let currentGeneration = generation
        renderer.stopRequestingMediaData()
        renderer.flush(fromSourceTime: flushTime) { [weak self] succeeded in
            guard let self else { return }
            self.queue.async {
                guard currentGeneration == self.generation else { return }
                if succeeded {
                    self.renderEventObserver?(.flushFrom(flushTime))
                    self.restartPipeline(atSource: Double(point.input) / self.sampleRate, outputOrigin: point.output,
                                         resetTimeline: false, sourceSample: point.input, primed: true)
                } else {
                    // The renderer already took that audio (locally it holds all ~1.5 s it asked
                    // for); keep it, the new level follows right after it.
                    self.partialFlushRefusals += 1
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
            guard let self else { return }
            self.queue.async { self.reportFailure(reason: "media services were reset", code: Self.playbackErrorCode) }
        })
#endif
    }

    private func handleAutomaticFlush(at flushTime: CMTime?) {
        guard !reportedFailure, compressor != nil else { return }
        let time = (flushTime?.isNumeric == true) ? flushTime! : synchronizer.currentTime()
        renderEventObserver?(.flushFrom(time))
        // Every sample from `time` on is gone (the notification names the first flushed sample).
        // Continue exactly there, primed, so the audio goes on without gap, overlap or fade dip.
        // Nothing exists after the enqueued audio. A flush time beyond its end (measured in the
        // glitch probe: 417 samples) continues there; starting at the flush time left a gap.
        let output = min(time.convertScale(CMTimeScale(sampleRate), method: .roundHalfAwayFromZero).value, enqueuedEnd)
        let sample = mapLock.withLock { state in
            state.output.isEmpty ? Int64((state.pendingSource * sampleRate).rounded()) : Self.sourceSample(in: state, output: output)
        }
        mapLock.withLock { state in state.bufferStarts.removeAll { $0 >= output } }
        automaticFlushRestarts.append((output, sample))
        restartPipeline(atSource: Double(sample) / sampleRate, outputOrigin: output, resetTimeline: false,
                        sourceSample: sample, primed: true)
        let source = Double(sample) / sampleRate
        DispatchQueue.main.async {
            guard !self.invalidated else { return }
            self.automaticFlushCount += 1
            self.delegate?.silenceTrimPlayerDidFlushAutomatically?(self, atTime: source)
        }
    }

    // MARK: Failure

    private func reportFailure(reason: String, code: Int = ICSilenceTrimPlayer.playbackErrorCode) {
        guard !reportedFailure else { return }
        reportedFailure = true
        renderer.stopRequestingMediaData()
        answerSilentPointQueries()
        DispatchQueue.main.async {
            self.fail(code: code, reason: reason)
        }
    }

    private func fail(code: Int, reason: String) {
        guard !invalidated else { return }
        let error = NSError(domain: Self.errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: reason])
        delegate?.silenceTrimPlayer(self, didFailWithError: error)
    }
}

// MARK: - Decoding ahead

/// Decodes one session ahead of the pipeline on its own queue. On a stream,
/// `copyNextSampleBuffer` waits for the network; the pipeline queue must not wait with it,
/// because seeks, level changes and the renderer run there.
///
/// AVAssetReader must not be cancelled while a copy waits: `cancelReading` from another thread
/// crashed inside the waiting copy (SIGSEGV in FigSemaphoreWaitRelative, measured 21.11.2026).
/// The reader is therefore only touched on `decodeQueue`; a replaced feed cancels it there as
/// soon as the copy returns, and StreamRequestTracker ends the request the copy waits for.
private final class DecodeFeed: @unchecked Sendable {
    enum Item {
        case buffer(CMSampleBuffer)
        case waitForInput
        case finished
        case failed(Error)
    }

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let decodeQueue = DispatchQueue(label: "com.iteconomy.instacast.silencetrim.decode", qos: .userInitiated)
    private let maximumFrames: Int
    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []
    private var head = 0
    private var bufferedFrames = 0
    private var decoding = false
    private var finished = false
    private var failure: Error?
    private var cancelled = false
    private var consumerWaiting = false
    /// Runs on `decodeQueue` when input arrives after `next()` found the feed empty.
    var onInput: (() -> Void)?
    /// Runs on `decodeQueue` with the end of every decoded buffer (source sample).
    var onDecoded: ((Int64) -> Void)?

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, maximumFrames: Int) {
        self.reader = reader
        self.output = output
        self.maximumFrames = maximumFrames
    }

    func start() {
        lock.lock()
        let go = claimDecodingLocked()
        lock.unlock()
        if go { decodeQueue.async { self.decode() } }
    }

    private func claimDecodingLocked() -> Bool {
        guard !decoding, !finished, !cancelled, bufferedFrames < maximumFrames else { return false }
        decoding = true
        return true
    }

    private func decode() {
        while true {
            lock.lock()
            if cancelled || bufferedFrames >= maximumFrames {
                decoding = false
                lock.unlock()
                break
            }
            lock.unlock()
            let sampleBuffer = output.copyNextSampleBuffer()
            lock.lock()
            if cancelled {
                decoding = false
                lock.unlock()
                break
            }
            if let sampleBuffer {
                buffers.append(sampleBuffer)
                bufferedFrames += CMSampleBufferGetNumSamples(sampleBuffer)
            } else {
                if reader.status == .failed {
                    failure = reader.error ?? NSError(domain: ICSilenceTrimPlayer.errorDomain, code: ICSilenceTrimPlayer.playbackErrorCode)
                }
                finished = true
                decoding = false
            }
            let notify = consumerWaiting
            consumerWaiting = false
            lock.unlock()
            if let sampleBuffer {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if pts.isNumeric, let onDecoded {
                    let rate = CMSampleBufferGetFormatDescription(sampleBuffer)
                        .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 44100
                    let start = pts.convertScale(CMTimeScale(rate), method: .roundHalfAwayFromZero).value
                    onDecoded(start + Int64(CMSampleBufferGetNumSamples(sampleBuffer)))
                }
            }
            if notify { onInput?() }
            if sampleBuffer == nil { break }
        }
        lock.lock()
        let stop = cancelled
        lock.unlock()
        if stop { reader.cancelReading() }
    }

    /// Next decoded buffer, or why there is none (pipeline queue).
    func next() -> Item {
        lock.lock()
        if head < buffers.count {
            let buffer = buffers[head]
            head += 1
            if head >= 64 {
                buffers.removeFirst(head)
                head = 0
            }
            bufferedFrames -= CMSampleBufferGetNumSamples(buffer)
            let go = bufferedFrames <= maximumFrames / 2 && claimDecodingLocked()
            lock.unlock()
            if go { decodeQueue.async { self.decode() } }
            return .buffer(buffer)
        }
        defer { lock.unlock() }
        if let failure { return .failed(failure) }
        if finished { return .finished }
        consumerWaiting = true
        return .waitForInput
    }

    func cancel() {
        lock.lock()
        cancelled = true
        buffers.removeAll()
        head = 0
        bufferedFrames = 0
        lock.unlock()
        decodeQueue.async { self.reader.cancelReading() }
    }
}

// MARK: - Stream requests

/// Hands the stream asset's loading requests to the stream cache and withdraws those of replaced
/// decoders. A replaced reader cannot be cancelled while it waits (see DecodeFeed), and a request
/// it leaves behind competes with the new position: the stream cache serves every waiting
/// request's range first and cancels the running download for a range elsewhere, so two waiting
/// requests at different offsets restart the download on every received chunk.
private final class StreamRequestTracker: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let source: ICSilenceTrimStreamSource
    private let lock = NSLock()
    /// 0 for the asset's own requests (duration, tracks), then one per decoder session.
    private var session = 0
    private var requests: [(request: AVAssetResourceLoadingRequest, session: Int)] = []
    private var withdrawn = 0
    var withdrawnCount: Int {
        lock.lock(); defer { lock.unlock() }
        return withdrawn
    }

    init(source: ICSilenceTrimStreamSource) {
        self.source = source
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        lock.lock()
        requests.removeAll { $0.request.isFinished || $0.request.isCancelled }
        requests.append((loadingRequest, session))
        lock.unlock()
        return source.resourceLoader?(resourceLoader, shouldWaitForLoadingOfRequestedResource: loadingRequest) ?? false
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        requests.removeAll { $0.request === loadingRequest }
        lock.unlock()
        source.resourceLoader?(resourceLoader, didCancel: loadingRequest)
    }

    /// Called before a new decoder starts. Requests of earlier decoders that still wait end now;
    /// the asset's own requests stay.
    func beginDecoderSession() {
        lock.lock()
        let previous = session
        session += 1
        var ended: [AVAssetResourceLoadingRequest] = []
        requests.removeAll { entry in
            guard entry.session >= 1, entry.session <= previous else { return false }
            if !entry.request.isFinished && !entry.request.isCancelled {
                ended.append(entry.request)
            }
            return true
        }
        withdrawn += ended.count
        lock.unlock()
        if !ended.isEmpty {
            source.abandonLoadingRequests(ended)
        }
    }
}
