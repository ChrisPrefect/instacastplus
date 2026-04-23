//
//  TranscriptionEngine.swift
//  Instacast
//
//  On-device speech-to-text via WhisperKit or Apple SpeechAnalyzer.
//  Produces SRT, chapter, music, checkpoint, and per-episode log files in
//  Documents/Transcripts/ so they are inspectable in the Files app next to the app's other
//  persistent data. Legacy Application Support/TranscriptCache files are migrated.
//

import Foundation
import AVFoundation
import UIKit
import Darwin.Mach
#if canImport(Speech)
import Speech
#endif

private func ICSetExcludedFromBackup(_ url: URL) {
    var mutableURL = url
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    try? mutableURL.setResourceValues(resourceValues)
}

private func ICDocumentsRootDirectoryURL() -> URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func ICDocumentsDataDirectoryURL() -> URL {
    let dir = ICDocumentsRootDirectoryURL().appendingPathComponent("Data", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func ICTranscriptsDirectoryURL() -> URL {
    let dir = ICDocumentsRootDirectoryURL().appendingPathComponent("Transcripts", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    ICSetExcludedFromBackup(dir)
    return dir
}

private func ICLegacyTranscriptCacheDirectoryURL() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return appSupport.appendingPathComponent("TranscriptCache", isDirectory: true)
}

private func ICMigrateLegacyTranscriptCacheIfNeeded(to dir: URL) {
    let legacyDir = ICLegacyTranscriptCacheDirectoryURL()
    let fm = FileManager.default
    guard fm.fileExists(atPath: legacyDir.path) else { return }

    var movedCount = 0
    var removedDuplicateCount = 0
    if let fileURLs = try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil) {
        for fileURL in fileURLs {
            let destinationURL = dir.appendingPathComponent(fileURL.lastPathComponent)
            if fm.fileExists(atPath: destinationURL.path) {
                try? fm.removeItem(at: fileURL)
                removedDuplicateCount += 1
            } else if (try? fm.moveItem(at: fileURL, to: destinationURL)) != nil {
                movedCount += 1
            }
        }
    }

    try? fm.removeItem(at: legacyDir)
    ICDiagnosticLogger.shared.logEvent("storage",
                                       message: "Legacy TranscriptCache migriert",
                                       metadata: [
                                        "legacyPath": legacyDir.path,
                                        "newPath": dir.path,
                                        "movedFiles": movedCount,
                                        "removedDuplicates": removedDuplicateCount,
                                       ] as NSDictionary)
}

@objc class ICTranscriptionPaths: NSObject {
    @objc static func transcriptCacheDirectory() -> URL {
        let dir = ICTranscriptsDirectoryURL()
        ICMigrateLegacyTranscriptCacheIfNeeded(to: dir)
        return dir
    }

    @objc static func srtURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash).srt")
    }

    @objc static func checkpointURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_checkpoint.json")
    }

    @objc static func chaptersJSONURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_chapters.json")
    }

    @objc static func musicTimelineURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_music.json")
    }
}

private struct ICDiagnosticSessionState: Codable {
    let sessionID: String
    let lastState: String
    let timestamp: TimeInterval
}

private struct ICDiagnosticMemorySnapshot: Encodable {
    let residentBytes: UInt64?
    let footprintBytes: UInt64?
    let physicalMemoryBytes: UInt64
    let lowPowerModeEnabled: Bool
    let thermalState: String
}

private struct ICDiagnosticDiskSnapshot: Encodable {
    let freeBytes: Int64?
}

private struct ICDiagnosticLogLine: Encodable {
    let timestamp: String
    let sessionID: String
    let category: String
    let message: String
    let metadata: [String: String]
    let memory: ICDiagnosticMemorySnapshot
    let disk: ICDiagnosticDiskSnapshot
}

@objc class ICDiagnosticLogger: NSObject, @unchecked Sendable {
    private static let _shared = ICDiagnosticLogger()
    @objc static var shared: ICDiagnosticLogger { _shared }

    private let queue = DispatchQueue(label: "ICDiagnosticLogger.queue")
    private let encoder = JSONEncoder()
    private var didStart = false
    private var observerTokens: [NSObjectProtocol] = []
    private let sessionID = UUID().uuidString

    private override init() {
        super.init()
        encoder.outputFormatting = [.sortedKeys]
    }

    @objc func start() {
        queue.async {
            self.ensureStartedLocked()
        }
    }

    @objc func logEvent(_ category: String, message: String) {
        logEvent(category, message: message, metadata: nil)
    }

    @objc func logEvent(_ category: String, message: String, metadata: NSDictionary?) {
        let convertedMetadata = self.stringifiedMetadata(from: metadata)
        queue.async {
            self.ensureStartedLocked()
            self.appendLocked(category: category, message: message, metadata: convertedMetadata)
        }
    }

    @objc func recordLifecycle(_ state: String, metadata: NSDictionary?) {
        let convertedMetadata = self.stringifiedMetadata(from: metadata)
        queue.async {
            self.ensureStartedLocked()
            self.writeSessionStateLocked(state: state)
            self.appendLocked(category: "lifecycle", message: state, metadata: convertedMetadata)
        }
    }

    @objc func logStorageLayout(_ reason: String) {
        queue.async {
            self.ensureStartedLocked()
            var metadata: [String: String] = ["reason": reason]
            metadata.merge(self.directorySnapshot(named: "data", at: ICDocumentsDataDirectoryURL())) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "transcripts", at: ICTranscriptsDirectoryURL())) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "logs", at: self.logsDirectoryURL())) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "episodes", at: self.documentsDirectory().appendingPathComponent("Episodes", isDirectory: true))) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "images", at: self.documentsDirectory().appendingPathComponent("Images", isDirectory: true))) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "legacyTranscriptCache", at: ICLegacyTranscriptCacheDirectoryURL())) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "whisperModels", at: self.applicationSupportDirectory().appendingPathComponent("huggingface", isDirectory: true))) { _, new in new }
            self.appendLocked(category: "storage", message: "Storage-Snapshot", metadata: metadata)
        }
    }

    func logEpisodeArtifacts(episodeHash: String, reason: String, audioURL: URL? = nil) {
        queue.async {
            self.ensureStartedLocked()
            var metadata: [String: String] = [
                "reason": reason,
                "episodeHash": episodeHash,
                "transcriptsDirectory": ICTranscriptsDirectoryURL().path,
            ]
            if let audioURL {
                metadata.merge(self.fileSnapshot(named: "audio", at: audioURL)) { _, new in new }
            }
            metadata.merge(self.fileSnapshot(named: "srt", at: ICTranscriptsDirectoryURL().appendingPathComponent("\(episodeHash).srt"))) { _, new in new }
            metadata.merge(self.fileSnapshot(named: "chapters", at: ICTranscriptsDirectoryURL().appendingPathComponent("\(episodeHash)_chapters.json"))) { _, new in new }
            metadata.merge(self.fileSnapshot(named: "music", at: ICTranscriptsDirectoryURL().appendingPathComponent("\(episodeHash)_music.json"))) { _, new in new }
            metadata.merge(self.fileSnapshot(named: "checkpoint", at: ICTranscriptsDirectoryURL().appendingPathComponent("\(episodeHash)_checkpoint.json"))) { _, new in new }
            metadata.merge(self.fileSnapshot(named: "episodeLog", at: ICTranscriptsDirectoryURL().appendingPathComponent("\(episodeHash)_log.json"))) { _, new in new }
            self.appendLocked(category: "artifacts", message: "Episode-Artefakte", metadata: metadata)
        }
    }

    @objc func logFileEvent(_ category: String, message: String, path: String, metadata: NSDictionary?) {
        let convertedMetadata = self.stringifiedMetadata(from: metadata)
        queue.async {
            self.ensureStartedLocked()
            var mergedMetadata = convertedMetadata
            if !path.isEmpty {
                mergedMetadata.merge(self.fileSnapshot(named: "file", at: URL(fileURLWithPath: path))) { _, new in new }
            }
            self.appendLocked(category: category, message: message, metadata: mergedMetadata)
        }
    }

    @objc func logDirectoryEvent(_ category: String, message: String, path: String, metadata: NSDictionary?) {
        let convertedMetadata = self.stringifiedMetadata(from: metadata)
        queue.async {
            self.ensureStartedLocked()
            var mergedMetadata = convertedMetadata
            if !path.isEmpty {
                mergedMetadata.merge(self.directorySnapshot(named: "directory", at: URL(fileURLWithPath: path, isDirectory: true))) { _, new in new }
            }
            self.appendLocked(category: category, message: message, metadata: mergedMetadata)
        }
    }

    private func ensureStartedLocked() {
        guard !didStart else { return }
        didStart = true

        if let previousState = loadPreviousSessionStateLocked() {
            appendLocked(
                category: "session",
                message: "Vorherige Session gefunden",
                metadata: [
                    "previousSessionID": previousState.sessionID,
                    "previousState": previousState.lastState,
                    "previousTimestamp": Self.timestampString(from: Date(timeIntervalSince1970: previousState.timestamp)),
                    "previousEndedUnexpectedly": Self.didPreviousSessionEndUnexpectedly(previousState.lastState) ? "true" : "false",
                ]
            )
        }

        writeSessionStateLocked(state: "launching")
        appendLocked(category: "session", message: "Diagnose-Logger gestartet", metadata: appMetadataLocked())
        appendLocked(category: "session", message: "Log-Dateien bereit", metadata: [
            "diagnosticsLogPath": diagnosticsLogURL().path,
            "applicationLogPath": (Bundle.pathToLogsDirectory() as NSString).appendingPathComponent("Application.Log"),
        ])
        logStorageLayout("startup")

        DispatchQueue.main.async {
            self.registerObserversIfNeeded()
        }
    }

    private func registerObserversIfNeeded() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default

        observerTokens.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logEvent("system", message: "Memory Warning", metadata: nil)
        })
        observerTokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.logEvent("system", message: "Thermal State Changed", metadata: [
                "thermalState": Self.thermalStateString(ProcessInfo.processInfo.thermalState),
            ] as NSDictionary)
        })
    }

    private static func didPreviousSessionEndUnexpectedly(_ state: String) -> Bool {
        let expectedStates: Set<String> = [
            "applicationDidEnterBackground",
            "sceneDidEnterBackground",
            "applicationWillTerminate",
            "sceneDidDisconnect",
        ]
        return !expectedStates.contains(state)
    }

    private func diagnosticsLogURL() -> URL {
        logsDirectoryURL().appendingPathComponent("Diagnostics.jsonl")
    }

    private func sessionStateURL() -> URL {
        logsDirectoryURL().appendingPathComponent("DiagnosticsSessionState.json")
    }

    private func logsDirectoryURL() -> URL {
        let dir = URL(fileURLWithPath: Bundle.pathToLogsDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ICSetExcludedFromBackup(dir)
        return dir
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    private func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    private func loadPreviousSessionStateLocked() -> ICDiagnosticSessionState? {
        guard let data = try? Data(contentsOf: sessionStateURL()) else { return nil }
        return try? JSONDecoder().decode(ICDiagnosticSessionState.self, from: data)
    }

    private func writeSessionStateLocked(state: String) {
        let sessionState = ICDiagnosticSessionState(sessionID: sessionID, lastState: state, timestamp: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(sessionState) else { return }
        try? data.write(to: sessionStateURL(), options: .atomic)
    }

    private func appendLocked(category: String, message: String, metadata: [String: String]) {
        let line = ICDiagnosticLogLine(
            timestamp: Self.timestampString(from: Date()),
            sessionID: sessionID,
            category: category,
            message: message,
            metadata: metadata,
            memory: currentMemorySnapshot(),
            disk: currentDiskSnapshot()
        )
        guard let data = try? encoder.encode(line) else { return }
        var payload = data
        payload.append(0x0A)

        let url = diagnosticsLogURL()
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }

    private func stringifiedMetadata(from metadata: NSDictionary?) -> [String: String] {
        guard let metadata else { return [:] }
        var converted: [String: String] = [:]
        for (rawKey, rawValue) in metadata {
            let key = String(describing: rawKey)
            let value = rawValue
            if let url = value as? URL {
                converted[key] = url.path
            } else if let date = value as? Date {
                converted[key] = Self.timestampString(from: date)
            } else {
                converted[key] = String(describing: value)
            }
        }
        return converted
    }

    private func currentMemorySnapshot() -> ICDiagnosticMemorySnapshot {
        ICDiagnosticMemorySnapshot(
            residentBytes: residentMemoryBytes(),
            footprintBytes: footprintMemoryBytes(),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: Self.thermalStateString(ProcessInfo.processInfo.thermalState)
        )
    }

    private func currentDiskSnapshot() -> ICDiagnosticDiskSnapshot {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let freeBytes = (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
        return ICDiagnosticDiskSnapshot(freeBytes: freeBytes)
    }

    private func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    private func footprintMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private func directorySnapshot(named name: String, at url: URL) -> [String: String] {
        var snapshot: [String: String] = [
            "\(name)Path": url.path,
            "\(name)Exists": FileManager.default.fileExists(atPath: url.path).description,
        ]
        guard FileManager.default.fileExists(atPath: url.path),
              let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return snapshot
        }

        var fileCount = 0
        var totalBytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                fileCount += 1
                totalBytes += Int64(values?.fileSize ?? 0)
            }
        }
        snapshot["\(name)FileCount"] = "\(fileCount)"
        snapshot["\(name)Bytes"] = "\(totalBytes)"
        snapshot["\(name)HumanSize"] = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return snapshot
    }

    private func fileSnapshot(named name: String, at url: URL) -> [String: String] {
        var snapshot: [String: String] = [
            "\(name)Path": url.path,
            "\(name)Exists": FileManager.default.fileExists(atPath: url.path).description,
        ]
        guard FileManager.default.fileExists(atPath: url.path) else { return snapshot }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        snapshot["\(name)Bytes"] = "\(size)"
        snapshot["\(name)HumanSize"] = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        if let modified = attributes?[.modificationDate] as? Date {
            snapshot["\(name)ModifiedAt"] = Self.timestampString(from: modified)
        }
        return snapshot
    }

    private func appMetadataLocked() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "appVersion": (info["CFBundleShortVersionString"] as? String) ?? "unknown",
            "build": (info["CFBundleVersion"] as? String) ?? "unknown",
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "locale": Locale.current.identifier,
            "documentsPath": documentsDirectory().path,
            "dataPath": ICDocumentsDataDirectoryURL().path,
            "transcriptsPath": ICTranscriptsDirectoryURL().path,
            "logsPath": logsDirectoryURL().path,
        ]
    }

    private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Engine Type

@objc enum ICTranscriptionEngineType: Int {
    case whisperKit = 0
    case apple = 1
}

// MARK: - Transcript Cue

@objc class ICTranscriptCue: NSObject, @unchecked Sendable {
    @objc let start: Double
    @objc let end: Double
    @objc let text: String

    @objc init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    @objc var dictionary: NSDictionary {
        return ["start": start, "end": end, "text": text]
    }
}

// MARK: - Checkpoint

private struct TranscriptionCheckpoint: Codable {
    var lastTimestamp: Double
    var cues: [CuePersist]
    var engineType: Int
    var consecutiveFailures: Int

    struct CuePersist: Codable {
        let start: Double
        let end: Double
        let text: String
    }
}

// MARK: - TranscriptionEngine

@MainActor
@objc class TranscriptionEngine: NSObject {

    private static let _shared = TranscriptionEngine()
    @objc static var shared: TranscriptionEngine { _shared }

    @objc var engineType: ICTranscriptionEngineType {
        get {
            // ObjC settings store engine as string ("WhisperKit" / "Apple")
            let str = UserDefaults.standard.string(forKey: "TranscriptionEngine") ?? ""
            if str == "Apple" { return .apple }
            return .whisperKit
        }
        set {
            UserDefaults.standard.set(newValue == .apple ? "Apple" : "WhisperKit",
                                      forKey: "TranscriptionEngine")
        }
    }

    @objc private(set) var isTranscribing = false
    @objc private(set) var currentProgress: Float = 0
    @objc private(set) var currentStatus: ICTranscriptionStatus = .none

    private var currentTask: Task<Void, Never>?
    private var currentCompletion: (([ICTranscriptCue]?, Error?) -> Void)?

    nonisolated static func isBackgroundGPUExecutionError(_ error: Error) -> Bool {
        var errors: [NSError] = []

        func collect(_ error: NSError) {
            errors.append(error)
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                collect(underlying)
            }
        }

        collect(error as NSError)

        let haystack = errors.flatMap { error -> [String] in
            [
                error.domain,
                error.localizedDescription,
                error.localizedFailureReason ?? "",
                error.localizedRecoverySuggestion ?? "",
                String(describing: error.userInfo),
            ]
        }.joined(separator: " ").lowercased()

        if haystack.contains("kiogpucommandbuffercallbackerrorbackgroundexecutionnotpermitted") ||
            haystack.contains("backgroundexecutionnotpermitted") ||
            haystack.contains("submit gpu work from background") ||
            (haystack.contains("insufficient permission") && haystack.contains("gpu") && haystack.contains("background")) {
            return true
        }

        let hasBackgroundMarker = haystack.contains("background") || haystack.contains("hintergrund")
        let hasCoreMLMarker = haystack.contains("core ml") ||
            haystack.contains("coreml") ||
            haystack.contains("com.apple.coreml")
        let hasGPUMarker = haystack.contains("gpu") ||
            haystack.contains("metal") ||
            haystack.contains("mtl") ||
            haystack.contains("command buffer")

        return hasBackgroundMarker && hasCoreMLMarker && hasGPUMarker
    }

    // MARK: - Public API

    @objc func transcribe(audioURL: URL, episodeHash: String, language: String?,
                          progress: @escaping @Sendable (Float, ICTranscriptionStatus) -> Void,
                          completion: @escaping @Sendable ([ICTranscriptCue]?, Error?) -> Void) {
        transcribe(audioURL: audioURL,
                   episodeHash: episodeHash,
                   language: language,
                   statusDetail: { _ in },
                   progress: progress,
                   completion: completion)
    }

    func transcribe(audioURL: URL, episodeHash: String, language: String?,
                    statusDetail: @escaping @Sendable (String) -> Void,
                    progress: @escaping @Sendable (Float, ICTranscriptionStatus) -> Void,
                    completion: @escaping @Sendable ([ICTranscriptCue]?, Error?) -> Void) {
        guard !isTranscribing else {
            completion(nil, NSError(domain: "TranscriptionEngine", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: "Already transcribing"]))
            return
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            completion(nil, NSError(domain: "TranscriptionEngine", code: 2,
                                   userInfo: [NSLocalizedDescriptionKey: "Audio file not found"]))
            return
        }

        // Check available disk space
        guard hasSufficientDiskSpace() else {
            completion(nil, NSError(domain: "TranscriptionEngine", code: 3,
                                   userInfo: [NSLocalizedDescriptionKey: "Not enough disk space"]))
            return
        }

        isTranscribing = true
        currentProgress = 0
        currentCompletion = completion

        // Load checkpoint if exists
        let checkpoint = loadCheckpoint(for: episodeHash)
        let startOffset = checkpoint?.lastTimestamp ?? 0
        let existingCues = checkpoint?.cues.map { ICTranscriptCue(start: $0.start, end: $0.end, text: $0.text) } ?? []

        // Get audio duration for progress calculation
        let asset = AVURLAsset(url: audioURL)

        currentTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let duration = try await asset.load(.duration)
                let totalDuration = CMTimeGetSeconds(duration)
                guard totalDuration > 0 else {
                    throw NSError(domain: "TranscriptionEngine", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid audio duration"])
                }

                // Determine effective engine based on failure counter
                let effectiveEngine = self.effectiveEngine(for: episodeHash, checkpoint: checkpoint)
                statusDetail(self.initialStatusDetail(for: effectiveEngine, language: language, startOffset: startOffset))

                await MainActor.run {
                    self.currentStatus = .transcribing
                    progress(Float(startOffset / totalDuration), .transcribing)
                }

                var newCues: [ICTranscriptCue] = []

                // Both backends now report absolute progress (0..1 fraction of totalDuration),
                // so no transformation is needed. Whatever the backend computes is the value
                // displayed to the user.
                let sendableProgress: @Sendable (Float) -> Void = { [weak self] p in
                    NSLog("[TranscriptionEngine] Progress callback: %.1f%%", p * 100)
                    DispatchQueue.main.async {
                        self?.currentProgress = p
                        progress(p, .transcribing)
                    }
                }

                // Segment callback: fine-grained progress + periodic checkpoint saves.
                // Accumulate cues so checkpoints contain all transcribed text for crash recovery.
                nonisolated(unsafe) var lastCheckpointProg: Float = 0
                nonisolated(unsafe) var accumulatedCues: [ICTranscriptCue] = existingCues
                let segmentCb: @Sendable (ICTranscriptCue) -> Void = { [weak self] cue in
                    accumulatedCues.append(cue)
                    let cueEnd = cue.end
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Update progress per segment (much more frequent than per-window callback)
                        let segProgress = Float(cueEnd / totalDuration)
                        self.currentProgress = segProgress
                        progress(segProgress, .transcribing)

                        // Checkpoint every ~10%
                        if segProgress - lastCheckpointProg >= 0.1 {
                            lastCheckpointProg = segProgress
                            self.saveCheckpointWithCues(episodeHash: episodeHash, cues: accumulatedCues, engineType: effectiveEngine.rawValue)
                        }
                    }
                }

                switch effectiveEngine {
                case .whisperKit:
                    newCues = try await self.transcribeWithWhisperKit(
                        audioURL: audioURL,
                        startOffset: startOffset,
                        totalDuration: totalDuration,
                        language: language,
                        statusDetail: statusDetail,
                        progress: sendableProgress,
                        segmentCallback: segmentCb
                    )

                case .apple:
                    newCues = try await self.transcribeWithApple(
                        audioURL: audioURL,
                        startOffset: startOffset,
                        totalDuration: totalDuration,
                        language: language,
                        statusDetail: statusDetail,
                        progress: sendableProgress,
                        segmentCallback: segmentCb
                    )
                }

                // Merge: dedup based on timestamp overlap
                let rawCues: [ICTranscriptCue]
                if startOffset > 0 && !newCues.isEmpty {
                    let deduped = newCues.filter { $0.start >= startOffset }
                    rawCues = existingCues + deduped
                } else if startOffset > 0 {
                    rawCues = existingCues
                } else {
                    rawCues = newCues
                }

                // Post-process: merge short fragments, split long segments
                let allCues = self.postProcessCues(rawCues)

                // Save SRT file
                let srtURL = self.srtURL(for: episodeHash)
                try self.writeSRT(cues: allCues, to: srtURL)
                self.invalidateSRTCache(for: episodeHash)

                // Remove checkpoint
                self.removeCheckpoint(for: episodeHash)

                // Reset failure counter
                self.resetFailureCounter(for: episodeHash)

                await MainActor.run {
                    self.isTranscribing = false
                    self.currentStatus = .completed
                    self.currentProgress = 1.0
                    self.currentCompletion = nil
                    progress(1.0, .completed)
                    completion(allCues, nil)
                }

            } catch {
                await MainActor.run {
                    let wasCancelled = (self.currentCompletion == nil) || error is CancellationError || Task.isCancelled
                    // Increment failure counter only for real errors, not cancellation
                    if !wasCancelled && !Self.isBackgroundGPUExecutionError(error) {
                        self.incrementFailureCounter(for: episodeHash)
                    }

                    self.isTranscribing = false
                    self.currentStatus = wasCancelled ? .none : .failed
                    // Only call completion if not already called by cancelTranscription()
                    if self.currentCompletion != nil {
                        self.currentCompletion = nil
                        completion(nil, error)
                    }
                }
            }
        }
    }

    @objc func cancelTranscription() {
        let cb = currentCompletion
        currentCompletion = nil
        currentTask?.cancel()
        currentTask = nil
        isTranscribing = false
        currentStatus = .none
        // Call completion so withCheckedContinuation in the queue doesn't hang
        cb?(nil, NSError(domain: "TranscriptionEngine", code: -1,
                         userInfo: [NSLocalizedDescriptionKey: "Cancelled"]))
    }

    // MARK: - Model Management

    @objc func isModelDownloaded() -> Bool {
        return WhisperKitBackend.shared.isModelDownloadedSync()
    }

    /// Pre-load WhisperKit model in background. Called at app launch so the model
    /// is ready in memory when the user starts transcribing.
    @objc func preloadModel() {
        guard engineType == .whisperKit && isModelDownloaded() else { return }
        Task.detached {
            let start = CFAbsoluteTimeGetCurrent()
            do {
                try await WhisperKitBackend.shared.prepareModel()
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                NSLog("[TranscriptionEngine] Model pre-loaded in %.1fs", elapsed)
            } catch {
                NSLog("[TranscriptionEngine] Model pre-load failed: %@", error.localizedDescription)
            }
        }
    }

    @objc var modelSizeOnDisk: Int64 {
        return WhisperKitBackend.shared.modelSizeOnDiskSync()
    }

    @objc func downloadModel(progress: @escaping (Float) -> Void,
                             completion: @escaping (Error?) -> Void) {
        nonisolated(unsafe) let cb = completion
        ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Download angefordert", metadata: [
            "engine": engineType.rawValue,
            "modelName": TranscriptionEngine.resolvedModelName(),
        ] as NSDictionary)
        Task.detached {
            do {
                try await WhisperKitBackend.shared.downloadModel()
                await MainActor.run { cb(nil) }
            } catch {
                await MainActor.run { cb(error) }
            }
        }
    }

    @objc func deleteModel() {
        ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Löschung angefordert", metadata: [
            "modelName": TranscriptionEngine.resolvedModelName(),
        ] as NSDictionary)
        Task.detached {
            await WhisperKitBackend.shared.deleteModel()
        }
    }

    @objc static func recommendedEngine() -> ICTranscriptionEngineType {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        // 8GB+ → WhisperKit (better accuracy), < 8GB → Apple (no download needed)
        return physicalMemory >= 8 * 1024 * 1024 * 1024 ? .whisperKit : .apple
    }

    @objc static func resolvedModelName() -> String {
        return WhisperKitBackend.resolvedModelName()
    }

    @objc nonisolated static func recommendedWhisperModel() -> String {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        return physicalMemory >= 8 * 1024 * 1024 * 1024
            ? "openai_whisper-large-v3-v20240930_turbo_632MB"
            : "openai_whisper-small_216MB"
    }

    @objc func transcriptCacheDirectory() -> URL {
        return ICTranscriptionPaths.transcriptCacheDirectory()
    }

    @objc func srtURL(for episodeHash: String) -> URL {
        return ICTranscriptionPaths.srtURL(for: episodeHash)
    }

    // Cache for hasSRT results. Invalidated when SRT files are added/removed.
    private var _srtCache: [String: Bool] = [:]

    @objc func hasSRT(for episodeHash: String) -> Bool {
        if let cached = _srtCache[episodeHash] { return cached }
        let exists = FileManager.default.fileExists(atPath: srtURL(for: episodeHash).path)
        _srtCache[episodeHash] = exists
        return exists
    }

    /// Invalidate cached hasSRT result (call after SRT creation/deletion).
    private func invalidateSRTCache(for episodeHash: String) {
        _srtCache.removeValue(forKey: episodeHash)
    }

    @objc func hasCheckpoint(for episodeHash: String) -> Bool {
        return FileManager.default.fileExists(atPath: checkpointURL(for: episodeHash).path)
    }

    @objc func removeSRT(for episodeHash: String) {
        let url = srtURL(for: episodeHash)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "SRT entfernt",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                       ] as NSDictionary)
            } catch {
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "SRT konnte nicht entfernt werden",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "error": error.localizedDescription,
                                                       ] as NSDictionary)
            }
        } else {
            ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                   message: "SRT fehlte beim Entfernen",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                   ] as NSDictionary)
        }
        invalidateSRTCache(for: episodeHash)
        TranscriptionLogger.shared.clearLog(episodeHash: episodeHash)
        ChapterGenerator.shared.invalidateChaptersCache(for: episodeHash)
        removeCheckpoint(for: episodeHash)
        ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "transcript-removed")
    }

    // MARK: - WhisperKit Backend

    private func transcribeWithWhisperKit(audioURL: URL, startOffset: Double, totalDuration: Double,
                                          language: String?,
                                          statusDetail: @escaping @Sendable (String) -> Void,
                                          progress: @escaping @Sendable (Float) -> Void,
                                          segmentCallback: @escaping @Sendable (ICTranscriptCue) -> Void) async throws -> [ICTranscriptCue] {
        return try await WhisperKitBackend.shared.transcribe(
            audioURL: audioURL,
            startOffset: startOffset,
            totalDuration: totalDuration,
            language: language,
            statusUpdate: statusDetail,
            progress: progress,
            segmentCallback: segmentCallback
        )
    }

    // MARK: - Apple SpeechAnalyzer Backend

    private func transcribeWithApple(audioURL: URL, startOffset: Double, totalDuration: Double,
                                     language: String?,
                                     statusDetail: @escaping @Sendable (String) -> Void,
                                     progress: @escaping (Float) -> Void,
                                     segmentCallback: @escaping (ICTranscriptCue) -> Void) async throws -> [ICTranscriptCue] {
        guard #available(iOS 26, *) else {
            throw NSError(domain: "TranscriptionEngine", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "Apple-Spracherkennung benötigt iOS 26."])
        }

        #if canImport(Speech)
        return try await transcribeWithSpeechAnalyzer(
            audioURL: audioURL, startOffset: startOffset, totalDuration: totalDuration,
            language: language, statusDetail: statusDetail, progress: progress, segmentCallback: segmentCallback)
        #else
        throw NSError(domain: "TranscriptionEngine", code: 103,
                      userInfo: [NSLocalizedDescriptionKey: "Speech-Framework nicht verfügbar."])
        #endif
    }

    #if canImport(Speech)
    @available(iOS 26, *)
    private func transcribeWithSpeechAnalyzer(
        audioURL: URL, startOffset: Double, totalDuration: Double,
        language: String?,
        statusDetail: @escaping @Sendable (String) -> Void,
        progress: @escaping (Float) -> Void,
        segmentCallback: @escaping (ICTranscriptCue) -> Void
    ) async throws -> [ICTranscriptCue] {
        statusDetail(NSLocalizedString("Apple-Spracherkennung wird vorbereitet.", comment: ""))

        // 1. Resolve locale from language code (BCP-47: "de", "en-US", etc.)
        let locale: Locale
        if let lang = language, !lang.isEmpty {
            locale = Locale(identifier: lang)
        } else {
            locale = Locale.current
        }

        // 2. Check locale support (compare at language-code level: "de" matches "de_DE")
        let supported = await SpeechTranscriber.supportedLocales
        let langCode = locale.language.languageCode
        guard supported.contains(where: { $0.language.languageCode == langCode }) else {
            let name = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            throw NSError(domain: "TranscriptionEngine", code: 104,
                          userInfo: [NSLocalizedDescriptionKey:
                              String(format: NSLocalizedString("Sprache '%@' wird von Apple-Spracherkennung nicht unterstützt.", comment: ""), name)])
        }

        // 2b. Find the exact supported locale variant (e.g. "de_DE" for "de")
        let matchedLocale = supported.first(where: { $0.language.languageCode == langCode }) ?? locale

        // 3. Create transcriber with timestamps (no volatile results — we only need finals)
        // Use the matched locale from supportedLocales to avoid "unallocated locale" errors.
        let transcriber = SpeechTranscriber(
            locale: matchedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // 3b. Ensure the locale asset is installed. SpeechTranscriber does NOT auto-download;
        // a fresh device with the language supported but not installed would otherwise error.
        let installed = await SpeechTranscriber.installedLocales
        let isInstalled = installed.contains { $0.language.languageCode == matchedLocale.language.languageCode }
        if !isInstalled {
            NSLog("[TranscriptionEngine] Apple locale %@ not installed — requesting download", matchedLocale.identifier)
            statusDetail(NSLocalizedString("Apple-Sprachpaket wird geladen.", comment: ""))
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
                NSLog("[TranscriptionEngine] Apple locale %@ installed", matchedLocale.identifier)
            } else {
                throw NSError(domain: "TranscriptionEngine", code: 106,
                              userInfo: [NSLocalizedDescriptionKey:
                                  String(format: NSLocalizedString("Sprachmodell für '%@' konnte nicht heruntergeladen werden.", comment: ""), matchedLocale.identifier)])
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        statusDetail(NSLocalizedString("Apple analysiert die Audiodatei.", comment: ""))

        NSLog("[TranscriptionEngine] Apple SpeechAnalyzer: locale=%@, file=%@", locale.identifier, audioURL.lastPathComponent)

        // 4. Collect results concurrently while analyzer processes the file
        let unsafeTranscriber = transcriber
        let unsafeTotalDuration = totalDuration
        let unsafeStartOffset = startOffset
        nonisolated(unsafe) let unsafeProgress = progress
        nonisolated(unsafe) let unsafeSegmentCallback = segmentCallback

        async let resultsFuture: [ICTranscriptCue] = {
            var cues: [ICTranscriptCue] = []
            for try await result in unsafeTranscriber.results {
                if Task.isCancelled { throw CancellationError() }
                guard result.isFinal else { continue }

                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }

                // Extract time range from AttributedString runs
                var segStart: Double = 0
                var segEnd: Double = 0
                for run in result.text.runs {
                    if let timeRange = run.audioTimeRange {
                        let runStart = CMTimeGetSeconds(timeRange.start)
                        let runEnd = CMTimeGetSeconds(CMTimeAdd(timeRange.start, timeRange.duration))
                        if segStart == 0 || runStart < segStart { segStart = runStart }
                        if runEnd > segEnd { segEnd = runEnd }
                    }
                }

                // Skip if no time range was found (would produce a broken 0,0 cue)
                if segEnd == 0 { continue }

                // Skip segments before the resume offset
                if unsafeStartOffset > 0 && segEnd < unsafeStartOffset { continue }

                let cue = ICTranscriptCue(start: segStart, end: segEnd, text: text)
                cues.append(cue)
                unsafeSegmentCallback(cue)

                // Report progress
                if unsafeTotalDuration > 0 {
                    let p = min(Float(segEnd / unsafeTotalDuration), 0.99)
                    unsafeProgress(p)
                }
            }
            return cues
        }()

        // 5. Feed the audio file to the analyzer
        let audioFile = try AVAudioFile(forReading: audioURL)
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
            throw NSError(domain: "TranscriptionEngine", code: 105,
                          userInfo: [NSLocalizedDescriptionKey: "SpeechAnalyzer konnte die Audiodatei nicht verarbeiten."])
        }

        // 6. Await collected results
        let cues = try await resultsFuture
        progress(1.0)
        NSLog("[TranscriptionEngine] Apple transcription done: %d cues", cues.count)
        return cues
    }
    #endif

    private func initialStatusDetail(for engine: ICTranscriptionEngineType,
                                     language: String?,
                                     startOffset: Double) -> String {
        let resumeSuffix: String
        if startOffset > 0 {
            resumeSuffix = " " + NSLocalizedString("Unterbrochene Transkription wird fortgesetzt.", comment: "")
        } else {
            resumeSuffix = ""
        }

        switch engine {
        case .whisperKit:
            return NSLocalizedString("Whisper bereitet die Audiodatei für die Dekodierung vor.", comment: "") + resumeSuffix
        case .apple:
            if let languageName = languageDisplayName(for: language) {
                return String(format: NSLocalizedString("Apple-Spracherkennung wird mit Sprache %@ vorbereitet.", comment: ""), languageName) + resumeSuffix
            }
            return NSLocalizedString("Apple-Spracherkennung wird vorbereitet.", comment: "") + resumeSuffix
        }
    }

    private func languageDisplayName(for identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let locale = Locale(identifier: identifier)
        return locale.localizedString(forIdentifier: locale.identifier) ?? identifier
    }

    // MARK: - Post-Processing

    /// Clean up WhisperKit segments: merge short fragments, split overly long segments at sentence boundaries.
    private func postProcessCues(_ cues: [ICTranscriptCue]) -> [ICTranscriptCue] {
        guard !cues.isEmpty else { return cues }

        var result: [ICTranscriptCue] = []

        // Step 1: Merge very short fragments (< 2 seconds or < 10 chars) into adjacent cues
        var merged: [ICTranscriptCue] = []
        var pendingText = ""
        var pendingStart: Double = 0
        var pendingEnd: Double = 0

        for cue in cues {
            let text = cue.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            if pendingText.isEmpty {
                pendingText = text
                pendingStart = cue.start
                pendingEnd = cue.end
            } else {
                let duration = pendingEnd - pendingStart
                // Merge if current pending segment is very short
                if duration < 2.0 || pendingText.count < 10 {
                    pendingText += " " + text
                    pendingEnd = cue.end
                } else {
                    merged.append(ICTranscriptCue(start: pendingStart, end: pendingEnd, text: pendingText))
                    pendingText = text
                    pendingStart = cue.start
                    pendingEnd = cue.end
                }
            }
        }
        if !pendingText.isEmpty {
            merged.append(ICTranscriptCue(start: pendingStart, end: pendingEnd, text: pendingText))
        }

        // Step 2: Split overly long segments (> 60 seconds) at sentence boundaries
        let sentenceEnders: CharacterSet = CharacterSet(charactersIn: ".!?")

        for cue in merged {
            let duration = cue.end - cue.start
            if duration <= 60.0 || cue.text.count < 200 {
                result.append(cue)
                continue
            }

            // Find sentence boundaries and split
            let text = cue.text
            var sentences: [String] = []
            var currentSentence = ""

            for char in text {
                currentSentence.append(char)
                if let scalar = char.unicodeScalars.first, sentenceEnders.contains(scalar), currentSentence.count > 20 {
                    sentences.append(currentSentence.trimmingCharacters(in: .whitespaces))
                    currentSentence = ""
                }
            }
            let remaining = currentSentence.trimmingCharacters(in: .whitespaces)
            if !remaining.isEmpty {
                sentences.append(remaining)
            }

            if sentences.count <= 1 {
                result.append(cue)
                continue
            }

            // Distribute time proportionally by character count
            let totalChars = sentences.reduce(0) { $0 + $1.count }
            var currentTime = cue.start
            for sentence in sentences {
                let fraction = Double(sentence.count) / Double(max(totalChars, 1))
                let segDuration = duration * fraction
                result.append(ICTranscriptCue(start: currentTime, end: currentTime + segDuration, text: sentence))
                currentTime += segDuration
            }
        }

        return result
    }

    // MARK: - SRT Writing

    private func writeSRT(cues: [ICTranscriptCue], to url: URL) throws {
        var srt = ""
        for (index, cue) in cues.enumerated() {
            srt += "\(index + 1)\n"
            srt += "\(formatSRTTime(cue.start)) --> \(formatSRTTime(cue.end))\n"
            srt += "\(cue.text)\n\n"
        }
        let episodeHash = url.deletingPathExtension().lastPathComponent
        do {
            try srt.write(to: url, atomically: true, encoding: .utf8)
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: "SRT geschrieben",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "cueCount": cues.count,
                                                    "characterCount": srt.count,
                                                   ] as NSDictionary)
        } catch {
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: "SRT konnte nicht geschrieben werden",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "cueCount": cues.count,
                                                    "characterCount": srt.count,
                                                    "error": error.localizedDescription,
                                                   ] as NSDictionary)
            throw error
        }
        ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "srt-written")
    }

    private func formatSRTTime(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
    }

    // MARK: - Checkpoint Persistence

    private func checkpointURL(for episodeHash: String) -> URL {
        return ICTranscriptionPaths.checkpointURL(for: episodeHash)
    }

    private func writeCheckpoint(_ checkpoint: TranscriptionCheckpoint, episodeHash: String, message: String) {
        let url = checkpointURL(for: episodeHash)
        do {
            let data = try JSONEncoder().encode(checkpoint)
            try data.write(to: url, options: .atomic)
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: message,
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "cueCount": checkpoint.cues.count,
                                                    "lastTimestamp": checkpoint.lastTimestamp,
                                                    "engineType": checkpoint.engineType,
                                                    "consecutiveFailures": checkpoint.consecutiveFailures,
                                                   ] as NSDictionary)
        } catch {
            ICDiagnosticLogger.shared.logFileEvent("file-write",
                                                   message: "\(message) fehlgeschlagen",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "cueCount": checkpoint.cues.count,
                                                    "lastTimestamp": checkpoint.lastTimestamp,
                                                    "engineType": checkpoint.engineType,
                                                    "consecutiveFailures": checkpoint.consecutiveFailures,
                                                    "error": error.localizedDescription,
                                                   ] as NSDictionary)
        }
    }

    private func saveCheckpoint(episodeHash: String, cues: [ICTranscriptCue], engineType: Int) {
        let checkpoint = TranscriptionCheckpoint(
            lastTimestamp: cues.last?.end ?? 0,
            cues: cues.map { .init(start: $0.start, end: $0.end, text: $0.text) },
            engineType: engineType,
            consecutiveFailures: loadCheckpoint(for: episodeHash)?.consecutiveFailures ?? 0
        )
        writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint geschrieben")
    }

    private func loadCheckpoint(for episodeHash: String) -> TranscriptionCheckpoint? {
        let url = checkpointURL(for: episodeHash)
        guard FileManager.default.fileExists(atPath: url.path) else {
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Checkpoint fehlt",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                   ] as NSDictionary)
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let checkpoint = try JSONDecoder().decode(TranscriptionCheckpoint.self, from: data)
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Checkpoint geladen",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "cueCount": checkpoint.cues.count,
                                                    "lastTimestamp": checkpoint.lastTimestamp,
                                                    "engineType": checkpoint.engineType,
                                                    "consecutiveFailures": checkpoint.consecutiveFailures,
                                                   ] as NSDictionary)
            return checkpoint
        } catch {
            ICDiagnosticLogger.shared.logFileEvent("file-read",
                                                   message: "Checkpoint konnte nicht geladen werden",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "error": error.localizedDescription,
                                                   ] as NSDictionary)
            return nil
        }
    }

    /// Save checkpoint with accumulated cues for crash recovery.
    /// Called periodically (~every 10%) during transcription.
    func saveCheckpointWithCues(episodeHash: String, cues: [ICTranscriptCue], engineType: Int) {
        let existing = loadCheckpoint(for: episodeHash)
        let checkpoint = TranscriptionCheckpoint(
            lastTimestamp: cues.last?.end ?? 0,
            cues: cues.map { .init(start: $0.start, end: $0.end, text: $0.text) },
            engineType: engineType,
            consecutiveFailures: existing?.consecutiveFailures ?? 0
        )
        writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint aktualisiert")
    }

    private func removeCheckpoint(for episodeHash: String) {
        let url = checkpointURL(for: episodeHash)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "Checkpoint entfernt",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                       ] as NSDictionary)
            } catch {
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "Checkpoint konnte nicht entfernt werden",
                                                       path: url.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "error": error.localizedDescription,
                                                       ] as NSDictionary)
            }
        } else {
            ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                   message: "Checkpoint fehlte beim Entfernen",
                                                   path: url.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                   ] as NSDictionary)
        }
    }

    // MARK: - Failure Counter (OOM-Loop Protection)

    private func incrementFailureCounter(for episodeHash: String) {
        var checkpoint = loadCheckpoint(for: episodeHash) ?? TranscriptionCheckpoint(
            lastTimestamp: 0, cues: [], engineType: engineType.rawValue, consecutiveFailures: 0
        )
        checkpoint.consecutiveFailures += 1
        writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint-Failure-Counter aktualisiert")
    }

    private func resetFailureCounter(for episodeHash: String) {
        resetCheckpointFailureCounter(for: episodeHash)
    }

    @objc func resetCheckpointFailureCounter(for episodeHash: String) {
        guard var checkpoint = loadCheckpoint(for: episodeHash),
              checkpoint.consecutiveFailures != 0 else { return }
        checkpoint.consecutiveFailures = 0
        writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint-Failure-Counter zurückgesetzt")
    }

    private func effectiveEngine(for episodeHash: String, checkpoint: TranscriptionCheckpoint?) -> ICTranscriptionEngineType {
        if let failures = checkpoint?.consecutiveFailures, failures >= 6 {
            NSLog("[TranscriptionEngine] Checkpoint has %d failures for %@; keeping configured engine", failures, episodeHash)
        }

        return engineType
    }

    // MARK: - Disk Space

    private func hasSufficientDiskSpace() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeSpace = attrs[.systemFreeSize] as? Int64 else { return true }
        return freeSpace > 50 * 1024 * 1024 // 50 MB minimum
    }

    // MARK: - Chapter/Music file helpers

    @objc func chaptersJSONURL(for episodeHash: String) -> URL {
        return ICTranscriptionPaths.chaptersJSONURL(for: episodeHash)
    }

    @objc func musicTimelineURL(for episodeHash: String) -> URL {
        return ICTranscriptionPaths.musicTimelineURL(for: episodeHash)
    }

}
