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

        // Check cached result first
        if let cached = loadCachedTimeline(for: episodeHash) {
            completion(cached, nil)
            return
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(nil, NSError(domain: "AudioAnalyzer", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Audio file not found"]))
            return
        }

        Task {
            do {
                let segments = try await self.performAnalysis(audioURL: audioURL)

                // Merge adjacent segments of the same type
                let merged = self.mergeAdjacentSegments(segments)

                // Filter: only keep music segments >= 3 seconds
                let filtered = merged.filter { segment in
                    if segment.type == "music" {
                        return (segment.end - segment.start) >= 3.0
                    }
                    return true
                }

                // Cache to disk
                self.saveCachedTimeline(segments: filtered, for: episodeHash)

                await MainActor.run {
                    completion(filtered, nil)
                }
            } catch {
                await MainActor.run {
                    completion(nil, error)
                }
            }
        }
    }

    /// Check if a cached music timeline exists
    @objc func hasCachedTimeline(for episodeHash: String) -> Bool {
        let url = TranscriptionEngine.shared.musicTimelineURL(for: episodeHash)
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - SoundAnalysis

    private func performAnalysis(audioURL: URL) async throws -> [ICAudioSegment] {
        let analyzer = try SNAudioFileAnalyzer(url: audioURL)

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTimeMakeWithSeconds(2.0, preferredTimescale: 48000)
        request.overlapFactor = 0.5

        let observer = SoundClassificationObserver()
        try analyzer.add(request, withObserver: observer)

        // analyze() is synchronous and blocks, so use DispatchQueue
        nonisolated(unsafe) let unsafeAnalyzer = analyzer
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                unsafeAnalyzer.analyze()
                cont.resume()
            }
        }
        await observer.waitForCompletion()

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
        let url = TranscriptionEngine.shared.musicTimelineURL(for: episodeHash)
        guard let data = try? Data(contentsOf: url),
              let timeline = try? JSONDecoder().decode(MusicTimeline.self, from: data) else {
            return nil
        }
        return timeline.segments.map {
            ICAudioSegment(type: $0.type, start: $0.start, end: $0.end, confidence: $0.confidence)
        }
    }

    private func saveCachedTimeline(segments: [ICAudioSegment], for episodeHash: String) {
        let timeline = MusicTimeline(
            segments: segments.map {
                .init(type: $0.type, start: $0.start, end: $0.end, confidence: $0.confidence)
            }
        )
        let url = TranscriptionEngine.shared.musicTimelineURL(for: episodeHash)
        if let data = try? JSONEncoder().encode(timeline) {
            try? data.write(to: url, options: .atomic)
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
