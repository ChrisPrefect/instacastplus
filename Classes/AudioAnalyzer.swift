//
//  AudioAnalyzer.swift
//  Instacast
//
//  On-device music/speech/silence detection via Apple SoundAnalysis.
//  Produces a timeline of audio segments for chapter boundary detection.
//

import Foundation
@preconcurrency import SoundAnalysis
import AVFoundation

// MARK: - Audio Segment

@objc class ICAudioSegment: NSObject, @unchecked Sendable {
    @objc let type: String      // "music", "speech", "silence"
    @objc let start: Double     // seconds
    @objc let end: Double       // seconds
    @objc let confidence: Float

    init(type: String, start: Double, end: Double, confidence: Float) {
        self.type = type
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    var dictionary: [String: Any] {
        return ["type": type, "start": start, "end": end, "confidence": confidence]
    }
}

// MARK: - Music Timeline (persistable)

private struct MusicTimeline: Codable {
    let segments: [Segment]

    struct Segment: Codable {
        let type: String
        let start: Double
        let end: Double
        let confidence: Float
    }
}

// MARK: - AudioAnalyzer

@MainActor
@objc class AudioAnalyzer: NSObject {

    private static let _shared = AudioAnalyzer()
    @objc static var shared: AudioAnalyzer { _shared }

    // MARK: - Public API

    /// Analyze an audio file for music/speech/silence segments.
    /// Returns an array of ICAudioSegment. Result is cached to disk.
    @objc func analyze(audioURL: URL, episodeHash: String,
                       completion: @escaping ([ICAudioSegment]?, Error?) -> Void) {
        Task {
            do {
                let segments = try await analyzeAsync(audioURL: audioURL, episodeHash: episodeHash)
                await MainActor.run {
                    completion(segments, nil)
                }
            } catch {
                await MainActor.run {
                    completion(nil, error)
                }
            }
        }
    }

    func analyzeAsync(audioURL: URL, episodeHash: String) async throws -> [ICAudioSegment] {
        // Check cached result first
        if let cached = loadCachedTimeline(for: episodeHash) {
            return cached
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw NSError(domain: "AudioAnalyzer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio file not found"])
        }

        let segments = try await performAnalysis(audioURL: audioURL)
        try Task.checkCancellation()

        // Merge adjacent segments of the same type
        let merged = mergeAdjacentSegments(segments)

        // Filter: only keep music segments >= 3 seconds
        let filtered = merged.filter { segment in
            if segment.type == "music" {
                return (segment.end - segment.start) >= 3.0
            }
            return true
        }

        // Cache to disk
        saveCachedTimeline(segments: filtered, for: episodeHash)
        return filtered
    }

    /// Check if a cached music timeline exists
    @objc func hasCachedTimeline(for episodeHash: String) -> Bool {
        let url = ICTranscriptionPaths.musicTimelineURL(for: episodeHash)
        return FileManager.default.fileExists(atPath: url.path)
    }

    @objc func cancelAnalysis() {
        currentAnalyzer?.cancelAnalysis()
        currentAnalyzer = nil
    }

    // MARK: - SoundAnalysis

    private var currentAnalyzer: SNAudioFileAnalyzer?

    private func performAnalysis(audioURL: URL) async throws -> [ICAudioSegment] {
        let analyzer = try SNAudioFileAnalyzer(url: audioURL)
        currentAnalyzer = analyzer
        defer {
            if currentAnalyzer === analyzer {
                currentAnalyzer = nil
            }
        }

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTimeMakeWithSeconds(2.0, preferredTimescale: 48000)
        request.overlapFactor = 0.5

        let observer = SoundClassificationObserver()
        try analyzer.add(request, withObserver: observer)

        try Task.checkCancellation()
        nonisolated(unsafe) let unsafeAnalyzer = analyzer
        let reachedEnd = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                unsafeAnalyzer.analyze { didReachEndOfFile in
                    cont.resume(returning: didReachEndOfFile)
                }
            }
        } onCancel: {
            unsafeAnalyzer.cancelAnalysis()
        }
        guard reachedEnd else {
            throw CancellationError()
        }
        await observer.waitForCompletion()
        try Task.checkCancellation()

        return observer.segments
    }

    // MARK: - Segment Merging

    private func mergeAdjacentSegments(_ segments: [ICAudioSegment]) -> [ICAudioSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [ICAudioSegment] = []
        var current = segments[0]

        for i in 1..<segments.count {
            let next = segments[i]
            if next.type == current.type && (next.start - current.end) < 1.0 {
                // Merge adjacent same-type segments
                current = ICAudioSegment(
                    type: current.type,
                    start: current.start,
                    end: next.end,
                    confidence: max(current.confidence, next.confidence)
                )
            } else {
                merged.append(current)
                current = next
            }
        }
        merged.append(current)

        return merged
    }

    // MARK: - Persistence

    private func loadCachedTimeline(for episodeHash: String) -> [ICAudioSegment]? {
        let url = ICTranscriptionPaths.musicTimelineURL(for: episodeHash)
        guard FileManager.default.fileExists(atPath: url.path) else {
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Musik-Timeline fehlt",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                   ] as NSDictionary)
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let timeline = try JSONDecoder().decode(MusicTimeline.self, from: data)
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Musik-Timeline geladen",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "segmentCount": timeline.segments.count,
                                                   ] as NSDictionary)
            return timeline.segments.map {
                ICAudioSegment(type: $0.type, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
        } catch {
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Musik-Timeline konnte nicht geladen werden",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "error": error.localizedDescription,
                                                   ] as NSDictionary)
            return nil
        }
    }

    private func saveCachedTimeline(segments: [ICAudioSegment], for episodeHash: String) {
        let timeline = MusicTimeline(
            segments: segments.map {
                .init(type: $0.type, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
        )
        let url = ICTranscriptionPaths.musicTimelineURL(for: episodeHash)
        do {
            let data = try JSONEncoder().encode(timeline)
            try data.write(to: url, options: .atomic)
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: "Musik-Timeline geschrieben",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "segmentCount": segments.count,
                                                   ] as NSDictionary)
        } catch {
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: "Musik-Timeline konnte nicht geschrieben werden",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "segmentCount": segments.count,
                                                    "error": error.localizedDescription,
                                                   ] as NSDictionary)
        }
    }
}

// MARK: - SoundClassificationObserver

private class SoundClassificationObserver: NSObject, SNResultsObserving {
    var segments: [ICAudioSegment] = []

    // Serial queue to synchronize markCompleted() (SoundAnalysis thread)
    // and waitForCompletion() (async caller thread). Without this,
    // a race between completed/continuation access can hang forever.
    private let lock = DispatchQueue(label: "SoundClassificationObserver.lock")
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed = false

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classification = result as? SNClassificationResult else { return }

        let timeRange = classification.timeRange
        let startTime = CMTimeGetSeconds(timeRange.start)
        let endTime = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))

        // Find dominant classification among music, speech, silence
        var bestType = "speech"
        var bestConfidence: Float = 0

        for candidate in classification.classifications {
            let id = candidate.identifier
            let conf = Float(candidate.confidence)

            if id == "music" && conf > bestConfidence {
                bestType = "music"
                bestConfidence = conf
            } else if id == "speech" && conf > bestConfidence {
                bestType = "speech"
                bestConfidence = conf
            } else if id == "silence" && conf > bestConfidence {
                bestType = "silence"
                bestConfidence = conf
            }
        }

        // Only record if we have reasonable confidence
        if bestConfidence > 0.3 {
            segments.append(ICAudioSegment(
                type: bestType,
                start: startTime,
                end: endTime,
                confidence: bestConfidence
            ))
        }
    }

    func request(_ request: SNRequest, didFailWithError error: Error) {
        NSLog("[AudioAnalyzer] Classification error: %@", error.localizedDescription)
        markCompleted()
    }

    func requestDidComplete(_ request: SNRequest) {
        markCompleted()
    }

    private func markCompleted() {
        lock.sync {
            guard !completed else { return }
            completed = true
            continuation?.resume()
        }
    }

    func waitForCompletion() async {
        // Check under lock whether already completed before suspending
        let alreadyDone: Bool = lock.sync {
            if completed { return true }
            return false
        }
        if alreadyDone { return }

        await withCheckedContinuation { cont in
            lock.sync {
                if completed {
                    // Completed between the check above and now — resume immediately
                    cont.resume()
                } else {
                    continuation = cont
                }
            }
        }
    }
}
