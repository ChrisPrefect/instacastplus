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
import NaturalLanguage
import UIKit
import Darwin
import Darwin.Mach
import Security
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

    @objc static func analysisJSONURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_analysis.json")
    }

    @objc static func remoteAnalysisJobURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_remote_analysis_job.json")
    }

    /// Exact generated-analysis artifacts. Callers must use this list instead of
    /// deleting every file sharing an episode-hash prefix because checkpoints,
    /// transcript logs, and audio-analysis artifacts have independent lifetimes.
    @objc static func generatedAnalysisArtifactURLs(for episodeHash: String) -> [URL] {
        return [
            chaptersJSONURL(for: episodeHash),
            analysisJSONURL(for: episodeHash),
            remoteAnalysisJobURL(for: episodeHash),
        ]
    }

    @objc static func musicTimelineURL(for episodeHash: String) -> URL {
        return transcriptCacheDirectory().appendingPathComponent("\(episodeHash)_music.json")
    }
}

private struct ICDiagnosticSessionState: Codable {
    let sessionID: String
    let lastState: String
    let timestamp: TimeInterval
    let metadata: [String: String]?
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

@objc class ICDiagnosticMailAttachment: NSObject {
    @objc let fileName: String
    @objc let mimeType: String
    @objc let data: NSData

    @objc init(fileName: String, mimeType: String, data: NSData) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
        super.init()
    }
}

@objc class ICDiagnosticLogger: NSObject, @unchecked Sendable {
    private static let _shared = ICDiagnosticLogger()
    @objc static var shared: ICDiagnosticLogger { _shared }
    private static let previousSessionEndedUnexpectedlyKey = "ICDiagnosticPreviousSessionEndedUnexpectedly"
    private static let previousSessionStateKey = "ICDiagnosticPreviousSessionState"
    private static let previousSessionEndedInBackgroundKey = "ICDiagnosticPreviousSessionEndedInBackground"

    private let queue = DispatchQueue(label: "ICDiagnosticLogger.queue")
    private let encoder = JSONEncoder()
    private var didStart = false
    private var observerTokens: [NSObjectProtocol] = []
    private let sessionID = UUID().uuidString

    private override init() {
        super.init()
        encoder.outputFormatting = [.sortedKeys]
    }

    @objc static var isTestFlightBuild: Bool {
#if DEBUG
        return false
#else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
#endif
    }

    @objc func start() {
        queue.sync {
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
            self.writeSessionStateLocked(state: state, metadata: convertedMetadata)
            self.appendLocked(category: "lifecycle", message: state, metadata: convertedMetadata)
        }
    }

    @objc var previousSessionEndedUnexpectedly: Bool {
        UserDefaults.standard.bool(forKey: Self.previousSessionEndedUnexpectedlyKey)
    }

    @objc var previousSessionState: String? {
        UserDefaults.standard.string(forKey: Self.previousSessionStateKey)
    }

    @objc var previousSessionEndedInBackground: Bool {
        UserDefaults.standard.bool(forKey: Self.previousSessionEndedInBackgroundKey)
    }

    @objc func crashLogMailAttachments() -> [ICDiagnosticMailAttachment] {
        queue.sync {
            self.ensureStartedLocked()
            self.appendLocked(category: "diagnostics", message: "Crash-Log-Mail vorbereitet", metadata: [
                "previousSessionEndedUnexpectedly": self.previousSessionEndedUnexpectedly ? "true" : "false",
                "previousSessionEndedInBackground": self.previousSessionEndedInBackground ? "true" : "false",
                "previousSessionState": self.previousSessionState ?? "",
            ])
        }

        let files: [(String, URL)] = [
            ("Diagnostics.jsonl", diagnosticsLogURL()),
            ("DiagnosticsSessionState.json", sessionStateURL()),
            ("Application.Log", URL(fileURLWithPath: (Bundle.pathToLogsDirectory() as NSString).appendingPathComponent("Application.Log"))),
        ]
        let data = combinedCrashLogMailAttachmentData(from: files)

        return [ICDiagnosticMailAttachment(fileName: "InstacastPlus-CrashLogs.txt", mimeType: "text/plain", data: data)]
    }

    @objc func crashLogMailBody() -> String {
        let metadata = appMetadataLocked()
        return [
            "InstacastPlus Crash Logs",
            "",
            "appVersion: \(metadata["appVersion"] ?? "")",
            "build: \(metadata["build"] ?? "")",
            "systemVersion: \(metadata["systemVersion"] ?? "")",
            "previousSessionEndedUnexpectedly: \(previousSessionEndedUnexpectedly)",
            "previousSessionEndedInBackground: \(previousSessionEndedInBackground)",
            "previousSessionState: \(previousSessionState ?? "")",
        ].joined(separator: "\n")
    }

    @objc func clearCrashLogMailArtifacts() {
        queue.sync {
            let fileManager = FileManager.default
            let diagnosticsLog = self.logsDirectoryURL().appendingPathComponent("Diagnostics.jsonl")
            let applicationLog = URL(fileURLWithPath: (Bundle.pathToLogsDirectory() as NSString).appendingPathComponent("Application.Log"))
            try? fileManager.removeItem(at: diagnosticsLog)
            try? fileManager.removeItem(at: applicationLog)
        }
        // UIApplication.shared must be touched on the main actor — hop there explicitly so this
        // can't trip the main-thread assertion if called off the main thread.
        Task { @MainActor in
            (UIApplication.shared as? Application)?.initializeLoggers()
        }
    }

    @objc func logStorageLayout(_ reason: String) {
        queue.async {
            self.ensureStartedLocked()
            var metadata: [String: String] = ["reason": reason]
            metadata.merge(self.directorySnapshot(named: "data", at: ICDocumentsDataDirectoryURL())) { _, new in new }
            // Per-file breakdown of the Core Data / Data folder, so we can see what makes it large
            // (the .sqlite store, an un-checkpointed -wal, an FMDB file, …).
            metadata["dataFiles"] = self.fileBreakdown(at: ICDocumentsDataDirectoryURL())
            metadata.merge(self.directorySnapshot(named: "transcripts", at: ICTranscriptsDirectoryURL())) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "logs", at: self.logsDirectoryURL())) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "episodes", at: self.documentsDirectory().appendingPathComponent("Episodes", isDirectory: true))) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "images", at: self.documentsDirectory().appendingPathComponent("Images", isDirectory: true))) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "legacyTranscriptCache", at: ICLegacyTranscriptCacheDirectoryURL())) { _, new in new }
            metadata.merge(self.directorySnapshot(named: "whisperModels", at: self.applicationSupportDirectory().appendingPathComponent("huggingface", isDirectory: true))) { _, new in new }
            self.appendLocked(category: "storage", message: "Storage-Snapshot", metadata: metadata)
        }
    }

    /// "name:bytes | name:bytes | …" for the immediate files in a directory (largest first).
    private func fileBreakdown(at url: URL) -> String {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return ""
        }
        let sized = items.map { item -> (String, Int) in
            let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return (item.lastPathComponent, size)
        }.sorted { $0.1 > $1.1 }
        return sized.map { "\($0.0):\($0.1)" }.joined(separator: " | ")
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
            metadata.merge(self.fileSnapshot(named: "analysis", at: ICTranscriptsDirectoryURL().appendingPathComponent("\(episodeHash)_analysis.json"))) { _, new in new }
            metadata.merge(self.fileSnapshot(named: "remoteAnalysisJob", at: ICTranscriptsDirectoryURL().appendingPathComponent("\(episodeHash)_remote_analysis_job.json"))) { _, new in new }
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
            let endedUnexpectedly = Self.didPreviousSessionEndUnexpectedly(previousState.lastState)
            let endedInBackground = Self.didPreviousSessionEndInBackground(previousState.lastState)
            let previousStateAge = max(0, Date().timeIntervalSince1970 - previousState.timestamp)
            var previousMetadata = previousState.metadata ?? [:]
            previousMetadata["previousSessionID"] = previousState.sessionID
            previousMetadata["previousState"] = previousState.lastState
            previousMetadata["previousTimestamp"] = Self.timestampString(from: Date(timeIntervalSince1970: previousState.timestamp))
            previousMetadata["secondsSincePreviousState"] = String(format: "%.3f", previousStateAge)
            previousMetadata["previousEndedUnexpectedly"] = endedUnexpectedly ? "true" : "false"
            previousMetadata["previousSessionEndedInBackground"] = endedInBackground ? "true" : "false"
            UserDefaults.standard.set(endedUnexpectedly, forKey: Self.previousSessionEndedUnexpectedlyKey)
            UserDefaults.standard.set(endedInBackground, forKey: Self.previousSessionEndedInBackgroundKey)
            UserDefaults.standard.set(previousState.lastState, forKey: Self.previousSessionStateKey)
            appendLocked(
                category: "session",
                message: "Vorherige Session gefunden",
                metadata: previousMetadata
            )
            if endedUnexpectedly {
                appendLocked(
                    category: "crash",
                    message: "Vorherige Session unerwartet beendet",
                    metadata: previousMetadata
                )
            }
            if endedInBackground {
                appendLocked(
                    category: "background-termination",
                    message: "Vorherige Hintergrund-Session beendet",
                    metadata: previousMetadata
                )
            }
        } else {
            UserDefaults.standard.set(false, forKey: Self.previousSessionEndedUnexpectedlyKey)
            UserDefaults.standard.set(false, forKey: Self.previousSessionEndedInBackgroundKey)
            UserDefaults.standard.removeObject(forKey: Self.previousSessionStateKey)
        }

        // Fold any backtrace captured by the crash handler during the previous session into
        // the diagnostics log, then (re)arm the handler for this session.
        loadAndClearPreviousCrashBacktraceLocked()
        installCrashBacktraceHandler()

        writeSessionStateLocked(state: "launching", metadata: nil)
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
            "applicationWillTerminate",
            "sceneDidDisconnect",
        ]
        return !didPreviousSessionEndInBackground(state) && !expectedStates.contains(state)
    }

    private static func didPreviousSessionEndInBackground(_ state: String) -> Bool {
        state == "applicationDidEnterBackground" || state == "sceneDidEnterBackground"
    }

    private func combinedCrashLogMailAttachmentData(from files: [(String, URL)]) -> NSData {
        var combinedData = Data()
        for (index, file) in files.enumerated() {
            let (fileName, url) = file
            if index > 0 {
                combinedData.append(contentsOf: [0x0A, 0x0A])
            }
            combinedData.append(Data("===== \(fileName) =====\n".utf8))
            if let fileData = try? Data(contentsOf: url) {
                combinedData.append(fileData)
                if fileData.last != 0x0A {
                    combinedData.append(0x0A)
                }
            }
        }
        return combinedData as NSData
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

    private func writeSessionStateLocked(state: String, metadata: [String: String]?) {
        let sessionState = ICDiagnosticSessionState(sessionID: sessionID,
                                                    lastState: state,
                                                    timestamp: Date().timeIntervalSince1970,
                                                    metadata: metadata)
        guard let data = try? JSONEncoder().encode(sessionState) else { return }
        try? data.write(to: sessionStateURL(), options: .atomic)
    }

    private func crashBacktraceURL() -> URL {
        logsDirectoryURL().appendingPathComponent("ICLastCrash.log")
    }

    private func loadAndClearPreviousCrashBacktraceLocked() {
        let url = crashBacktraceURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else { return }
        appendLocked(category: "crash-backtrace",
                     message: "Stacktrace des vorherigen Absturzes",
                     metadata: ["backtrace": text])
        try? FileManager.default.removeItem(at: url)
    }

    private func installCrashBacktraceHandler() {
        ICInstallCrashBacktraceHandler(crashBacktraceURL().path)
    }

    private func appendLocked(category: String, message: String, metadata: [String: String]) {
        #if DEBUG
        // Mirror every diagnostic event to the device/Xcode console (NSLog = unbuffered, shows up
        // in `log stream` and devicectl --console) so it doesn't have to be mail-exported.
        NSLog("📊 [%@] %@ %@", category, message, metadata.isEmpty ? "" : "\(metadata)")
        #endif
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
            let endOffset = (try? handle.seekToEnd()) ?? 0
            // Keep the diagnostics log bounded — if a bug ever floods it (e.g. a feedback loop),
            // drop the oldest half rather than letting it grow without limit.
            if endOffset > Self.maxDiagnosticsLogBytes {
                trimDiagnosticsLogLocked(url: url)
                if let reopened = try? FileHandle(forWritingTo: url) {
                    defer { try? reopened.close() }
                    _ = try? reopened.seekToEnd()
                    try? reopened.write(contentsOf: payload)
                    return
                }
            }
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: url, options: .atomic)
        }
    }

    private static let maxDiagnosticsLogBytes: UInt64 = 6 * 1024 * 1024

    // Rewrites the log keeping roughly its most recent half, starting at a line boundary.
    private func trimDiagnosticsLogLocked(url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let keep = data.count / 2
        var start = data.count - keep
        if let newline = data[start...].firstIndex(of: 0x0A) {
            start = newline + 1
        }
        let trimmed = data.subdata(in: start..<data.count)
        var prefix = Data("{\"category\":\"diagnostics\",\"message\":\"Log gekürzt (Größenlimit)\"}\n".utf8)
        prefix.append(trimmed)
        try? prefix.write(to: url, options: .atomic)
    }

    private func stringifiedMetadata(from metadata: NSDictionary?) -> [String: String] {
        guard let metadata else { return [:] }
        var converted: [String: String] = [:]
        for (rawKey, rawValue) in metadata {
            let key = String(describing: rawKey)
            let value = rawValue
            if key.range(of: "url", options: .caseInsensitive) != nil {
                let URLString = (value as? URL)?.absoluteString ?? String(describing: value)
                converted[key] = ICRedactedURLStringForLogging(URLString)
            } else if let url = value as? URL {
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

private final class ICTranscriptCheckpointAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [ICTranscriptCue]
    private var lastCheckpointProgress: Float = 0

    init(cues: [ICTranscriptCue]) {
        self.cues = cues
    }

    func appendAndCheckpointSnapshot(cue: ICTranscriptCue,
                                     progress: Float) -> [ICTranscriptCue]? {
        lock.lock()
        defer { lock.unlock() }

        cues.append(cue)
        guard progress - lastCheckpointProgress >= 0.01 else { return nil }
        lastCheckpointProgress = progress
        return cues
    }

    func snapshot() -> [ICTranscriptCue] {
        lock.lock()
        defer { lock.unlock() }
        return cues
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
    private var currentTranscriptionRunID: UUID?
    private var currentCheckpointAccumulator: ICTranscriptCheckpointAccumulator?
    private var currentCheckpointEpisodeHash: String?
    private var currentCheckpointEngineType: ICTranscriptionEngineType?
    private var checkpointCache: [String: TranscriptionCheckpoint] = [:]

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

        let transcriptionRunID = UUID()
        isTranscribing = true
        currentProgress = 0
        currentCompletion = completion
        currentTranscriptionRunID = transcriptionRunID

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
                let checkpointAccumulator = ICTranscriptCheckpointAccumulator(cues: existingCues)
                self.currentCheckpointAccumulator = checkpointAccumulator
                self.currentCheckpointEpisodeHash = episodeHash
                self.currentCheckpointEngineType = effectiveEngine
                let segmentCb: @Sendable (ICTranscriptCue) -> Void = { [weak self] cue in
                    let cueEnd = cue.end
                    let segProgress = Float(cueEnd / totalDuration)
                    let checkpointCues = checkpointAccumulator.appendAndCheckpointSnapshot(
                        cue: cue,
                        progress: segProgress
                    )
                    DispatchQueue.main.async {
                        guard let self = self,
                              self.currentTranscriptionRunID == transcriptionRunID else { return }
                        // Update progress per segment (much more frequent than per-window callback)
                        self.currentProgress = segProgress
                        progress(segProgress, .transcribing)

                        // Keep checkpoint progress close to the visible progress so short
                        // background pauses resume near where the user left off.
                        if let checkpointCues {
                            self.saveCheckpointWithCues(episodeHash: episodeHash,
                                                        cues: checkpointCues,
                                                        engineType: effectiveEngine.rawValue)
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
                self.currentCheckpointAccumulator = nil
                self.currentCheckpointEpisodeHash = nil
                self.currentCheckpointEngineType = nil

                // Reset failure counter
                self.resetFailureCounter(for: episodeHash)

                await MainActor.run {
                    guard self.currentTranscriptionRunID == transcriptionRunID,
                          let completionHandler = self.currentCompletion else { return }
                    self.isTranscribing = false
                    self.currentStatus = .completed
                    self.currentProgress = 1.0
                    self.currentTask = nil
                    self.currentCompletion = nil
                    self.currentTranscriptionRunID = nil
                    progress(1.0, .completed)
                    completionHandler(allCues, nil)
                }

            } catch {
                await MainActor.run {
                    guard self.currentTranscriptionRunID == transcriptionRunID else { return }
                    let wasCancelled = (self.currentCompletion == nil) || error is CancellationError || Task.isCancelled
                    // Increment failure counter only for real errors, not cancellation
                    if !wasCancelled && !Self.isBackgroundGPUExecutionError(error) {
                        self.incrementFailureCounter(for: episodeHash)
                    }

                    self.isTranscribing = false
                    self.currentStatus = wasCancelled ? .none : .failed
                    self.currentTask = nil
                    self.currentCheckpointAccumulator = nil
                    self.currentCheckpointEpisodeHash = nil
                    self.currentCheckpointEngineType = nil
                    // Only call completion if not already called by cancelTranscription()
                    if let completionHandler = self.currentCompletion {
                        self.currentCompletion = nil
                        self.currentTranscriptionRunID = nil
                        completionHandler(nil, error)
                    } else {
                        self.currentTranscriptionRunID = nil
                    }
                }
            }
        }
    }

    @discardableResult
    func persistCurrentCheckpointForInterruption() -> Bool {
        guard let episodeHash = currentCheckpointEpisodeHash,
              let engineType = currentCheckpointEngineType,
              let cues = currentCheckpointAccumulator?.snapshot() else {
            return !isTranscribing
        }
        guard !cues.isEmpty else { return true }
        return saveCheckpointWithCues(episodeHash: episodeHash,
                                      cues: cues,
                                      engineType: engineType.rawValue)
    }

    @objc func cancelTranscription() {
        let cb = currentCompletion
        currentCompletion = nil
        currentTranscriptionRunID = nil
        currentTask?.cancel()
        currentTask = nil
        currentCheckpointAccumulator = nil
        currentCheckpointEpisodeHash = nil
        currentCheckpointEngineType = nil
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

    /// Reads the exact canonical SRT written by this engine. `nil` means no
    /// transcript exists; an empty array means the persisted timeline is
    /// malformed and must not validate revision-bound semantic artifacts.
    func persistedTranscriptCues(for episodeHash: String) throws -> [ICTranscriptCue]? {
        let url = srtURL(for: episodeHash)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let content = try String(contentsOf: url, encoding: .utf8)
        return try parsePersistedSRT(content)
    }

    private func parsePersistedSRT(_ content: String) throws -> [ICTranscriptCue] {
        let lines = content.components(separatedBy: .newlines)
        var cues: [ICTranscriptCue] = []
        var lineIndex = 0
        var previousEnd = -Double.infinity

        while lineIndex < lines.count {
            var line = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                lineIndex += 1
                continue
            }
            if !line.contains("-->") {
                lineIndex += 1
                guard lineIndex < lines.count else { return [] }
                line = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let timeParts = line.components(separatedBy: "-->")
            guard timeParts.count == 2 else { return [] }
            let start = parsePersistedSRTTime(timeParts[0])
            let end = parsePersistedSRTTime(timeParts[1])
            lineIndex += 1

            var textLines: [String] = []
            while lineIndex < lines.count {
                let textLine = lines[lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if textLine.isEmpty {
                    lineIndex += 1
                    break
                }
                textLines.append(textLine)
                lineIndex += 1
            }
            let text = textLines.joined(separator: "\n")
            guard start.isFinite,
                  end.isFinite,
                  start >= 0,
                  end > start,
                  start >= previousEnd - 0.001,
                  !text.isEmpty else { return [] }
            cues.append(ICTranscriptCue(start: start, end: end, text: text))
            previousEnd = end
        }
        return cues.isEmpty ? [] : cues
    }

    /// Validates a server-delivered SRT before it replaces the local transcript.
    /// The final write goes through the normal importer so revisions and caches
    /// stay identical to locally generated transcripts.
    func importServerSRTData(_ data: Data, for episodeHash: String) throws -> [ICTranscriptCue] {
        guard !episodeHash.isEmpty,
              let content = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "TranscriptionEngine.ServerImport", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Das Server-Transkript ist ungültig.", comment: "")])
        }
        let cues = try parsePersistedSRT(content)
        guard !cues.isEmpty else {
            throw NSError(domain: "TranscriptionEngine.ServerImport", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Das Server-Transkript enthält keine Zeitmarken.", comment: "")])
        }
        try saveImportedTranscriptCues(cues, for: episodeHash)
        return cues
    }

    private func parsePersistedSRTTime(_ value: String) -> Double {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let parts = normalized.components(separatedBy: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return -.infinity }
        return hours * 3600 + minutes * 60 + seconds
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
        removeTranscriptCacheFiles(for: episodeHash)
        TranscriptionLogger.shared.clearLog(episodeHash: episodeHash)
        ChapterGenerator.shared.invalidateChaptersCache(for: episodeHash)
        removeCheckpoint(for: episodeHash)
        ICDiagnosticLogger.shared.logEpisodeArtifacts(episodeHash: episodeHash, reason: "transcript-removed")
    }

    private func removeTranscriptCacheFiles(for episodeHash: String) {
        let directory = transcriptCacheDirectory()
        let prefix = "\(episodeHash)_"
        let fileURLs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removedCount = 0
        for fileURL in fileURLs {
            guard fileURL.lastPathComponent.hasPrefix(prefix),
                  fileURL.pathExtension == "trcache" else { continue }
            do {
                try FileManager.default.removeItem(at: fileURL)
                removedCount += 1
            } catch {
                ICDiagnosticLogger.shared.logFileEvent("file-delete",
                                                       message: "Transcript-Cache konnte nicht entfernt werden",
                                                       path: fileURL.path,
                                                       metadata: [
                                                        "episodeHash": episodeHash,
                                                        "error": error.localizedDescription,
                                                       ] as NSDictionary)
            }
        }
        ICDiagnosticLogger.shared.logDirectoryEvent("file-delete",
                                                   message: "Transcript-Cache-Artefakte entfernt",
                                                   path: directory.path,
                                                   metadata: [
                                                    "episodeHash": episodeHash,
                                                    "removedFiles": removedCount,
                                                   ] as NSDictionary)
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
            return NSLocalizedString("Transkription wird vorbereitet.", comment: "") + resumeSuffix
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

    /// Establish one strict timeline before fragments are merged or written to SRT.
    /// WhisperKit reloads a small amount of audio around slice boundaries, so two
    /// otherwise valid segments can describe the same fraction of the timeline.
    private func normalizedTranscriptTimelineCues(_ cues: [ICTranscriptCue]) -> [ICTranscriptCue] {
        var rejectedCount = 0
        let orderedCues = cues.enumerated().compactMap { offset, cue -> (offset: Int, cue: ICTranscriptCue)? in
            let text = cleanedTranscriptText(cue.text)
            guard cue.start.isFinite,
                  cue.end.isFinite,
                  cue.start >= 0,
                  cue.end > cue.start,
                  !text.isEmpty else {
                rejectedCount += 1
                return nil
            }
            return (offset, ICTranscriptCue(start: cue.start, end: cue.end, text: text))
        }.sorted { lhs, rhs in
            if lhs.cue.start != rhs.cue.start { return lhs.cue.start < rhs.cue.start }
            if lhs.cue.end != rhs.cue.end { return lhs.cue.end < rhs.cue.end }
            return lhs.offset < rhs.offset
        }

        var normalized: [ICTranscriptCue] = []
        var overlapClipped = 0
        var overlapCoalesced = 0

        for entry in orderedCues {
            let cue = entry.cue
            guard let previous = normalized.last else {
                normalized.append(cue)
                continue
            }

            if cue.start < previous.end {
                if cue.text == previous.text {
                    normalized[normalized.count - 1] = ICTranscriptCue(
                        start: previous.start,
                        end: max(previous.end, cue.end),
                        text: previous.text
                    )
                    overlapCoalesced += 1
                } else if cue.end <= previous.end {
                    normalized[normalized.count - 1] = ICTranscriptCue(
                        start: previous.start,
                        end: previous.end,
                        text: previous.text + " " + cue.text
                    )
                    overlapCoalesced += 1
                } else {
                    let normalizedStart = previous.end
                    guard normalizedStart < cue.end else {
                        rejectedCount += 1
                        continue
                    }
                    normalized.append(ICTranscriptCue(
                        start: normalizedStart,
                        end: cue.end,
                        text: cue.text
                    ))
                    overlapClipped += 1
                }
            } else {
                normalized.append(cue)
            }
        }

        if overlapClipped > 0 || overlapCoalesced > 0 || rejectedCount > 0 {
            NSLog("[TranscriptionEngine] Transcript cue timeline normalized: overlapClipped=%d overlapCoalesced=%d rejected=%d input=%d output=%d",
                  overlapClipped, overlapCoalesced, rejectedCount, cues.count, normalized.count)
            ICDiagnosticLogger.shared.logEvent("transcription",
                                               message: "Transcript cue timeline normalized",
                                               metadata: [
                                                "overlapClipped": overlapClipped,
                                                "overlapCoalesced": overlapCoalesced,
                                                "rejected": rejectedCount,
                                                "inputCueCount": cues.count,
                                                "outputCueCount": normalized.count,
                                               ] as NSDictionary)
        }

        return normalized
    }

    /// Clean up WhisperKit segments and align persisted sections to sentence endings.
    private func postProcessCues(_ cues: [ICTranscriptCue]) -> [ICTranscriptCue] {
        guard !cues.isEmpty else { return cues }

        let timelineCues = normalizedTranscriptTimelineCues(cues)
        guard !timelineCues.isEmpty else { return [] }

        return sentenceAlignedTranscriptCues(timelineCues)
    }

    /// Whisper segments are decoder implementation details, not semantic text
    /// boundaries. Buffer unfinished text until NaturalLanguage reports a full
    /// sentence. If a segment contains a full sentence plus the next speaker's
    /// first word, only the full sentence is emitted and the suffix is carried on.
    private func sentenceAlignedTranscriptCues(_ cues: [ICTranscriptCue]) -> [ICTranscriptCue] {
        var result: [ICTranscriptCue] = []
        var pendingText = ""
        var pendingStart = 0.0
        var pendingEnd = 0.0

        func isCompleteSentence(_ text: Substring) -> Bool {
            guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
                return false
            }
            return ".!?…".contains(last)
        }

        func lastCompleteSentenceBoundary(in text: String) -> String.Index? {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            var boundary: String.Index?
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                if isCompleteSentence(text[range]) {
                    boundary = range.upperBound
                }
                return true
            }
            return boundary
        }

        func appendPending(end: Double) {
            let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, end > pendingStart else { return }
            result.append(ICTranscriptCue(start: pendingStart, end: end, text: text))
        }

        for cue in cues {
            if pendingText.isEmpty {
                pendingStart = cue.start
            } else {
                pendingText += " "
            }
            pendingText += cue.text
            pendingEnd = cue.end

            guard let boundary = lastCompleteSentenceBoundary(in: pendingText) else {
                // Keep unpunctuated speech bounded without inventing a sentence end.
                if pendingEnd - pendingStart >= 60 {
                    appendPending(end: pendingEnd)
                    pendingText = ""
                }
                continue
            }

            let completeText = String(pendingText[..<boundary])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = String(pendingText[boundary...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !completeText.isEmpty else { continue }

            if suffix.isEmpty {
                appendPending(end: pendingEnd)
                pendingText = ""
            } else {
                let totalCharacters = max(pendingText.count, 1)
                let completedCharacters = pendingText.distance(from: pendingText.startIndex, to: boundary)
                let fraction = Double(completedCharacters) / Double(totalCharacters)
                let boundaryTime = pendingStart + ((pendingEnd - pendingStart) * fraction)
                result.append(ICTranscriptCue(start: pendingStart,
                                              end: boundaryTime,
                                              text: completeText))
                pendingText = suffix
                pendingStart = boundaryTime
            }
        }

        if !pendingText.isEmpty {
            appendPending(end: pendingEnd)
        }

        return result
    }

    private func cleanedTranscriptText(_ text: String) -> String {
        let withoutControlTokens = text.replacingOccurrences(
            of: #"<\|[^>]+\|>"#,
            with: "",
            options: .regularExpression
        )
        return withoutControlTokens
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            ChapterGenerator.shared.invalidateAnalysisCache(for: episodeHash)
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

    /// Persist a publisher-provided timed transcript before semantic analysis.
    /// Revision validation then rereads this exact local artifact instead of
    /// downloading mutable network content a second time.
    func saveImportedTranscriptCues(_ cues: [ICTranscriptCue], for episodeHash: String) throws {
        guard !episodeHash.isEmpty, !cues.isEmpty else {
            throw NSError(
                domain: "TranscriptionEngine.ImportedTranscript",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Ein zeitcodiertes Podcast-Transkript fehlt."]
            )
        }
        try writeSRT(cues: cues, to: ICTranscriptionPaths.srtURL(for: episodeHash))
        invalidateSRTCache(for: episodeHash)
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

    private func writeCheckpoint(_ checkpoint: TranscriptionCheckpoint, episodeHash: String, message: String) -> Bool {
        let url = checkpointURL(for: episodeHash)
        do {
            let data = try JSONEncoder().encode(checkpoint)
            try data.write(to: url, options: .atomic)
            checkpointCache[episodeHash] = checkpoint
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
            return true
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
            return false
        }
    }

    private func saveCheckpoint(episodeHash: String, cues: [ICTranscriptCue], engineType: Int) {
        let checkpoint = TranscriptionCheckpoint(
            lastTimestamp: cues.last?.end ?? 0,
            cues: cues.map { .init(start: $0.start, end: $0.end, text: $0.text) },
            engineType: engineType,
            consecutiveFailures: loadCheckpoint(for: episodeHash)?.consecutiveFailures ?? 0
        )
        _ = writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint geschrieben")
    }

    private func loadCheckpoint(for episodeHash: String) -> TranscriptionCheckpoint? {
        if let cached = checkpointCache[episodeHash] {
            return cached
        }

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
            checkpointCache[episodeHash] = checkpoint
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
    /// Called periodically (~every 1%) during transcription.
    @discardableResult
    func saveCheckpointWithCues(episodeHash: String, cues: [ICTranscriptCue], engineType: Int) -> Bool {
        let existing = loadCheckpoint(for: episodeHash)
        let checkpoint = TranscriptionCheckpoint(
            lastTimestamp: cues.last?.end ?? 0,
            cues: cues.map { .init(start: $0.start, end: $0.end, text: $0.text) },
            engineType: engineType,
            consecutiveFailures: existing?.consecutiveFailures ?? 0
        )
        return writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint aktualisiert")
    }

    private func removeCheckpoint(for episodeHash: String) {
        checkpointCache.removeValue(forKey: episodeHash)
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
        _ = writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint-Failure-Counter aktualisiert")
    }

    private func resetFailureCounter(for episodeHash: String) {
        resetCheckpointFailureCounter(for: episodeHash)
    }

    @objc func resetCheckpointFailureCounter(for episodeHash: String) {
        guard var checkpoint = loadCheckpoint(for: episodeHash),
              checkpoint.consecutiveFailures != 0 else { return }
        checkpoint.consecutiveFailures = 0
        _ = writeCheckpoint(checkpoint, episodeHash: episodeHash, message: "Checkpoint-Failure-Counter zurückgesetzt")
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

    @objc func analysisJSONURL(for episodeHash: String) -> URL {
        return ICTranscriptionPaths.analysisJSONURL(for: episodeHash)
    }

    @objc func musicTimelineURL(for episodeHash: String) -> URL {
        return ICTranscriptionPaths.musicTimelineURL(for: episodeHash)
    }

}

// MARK: - Downloadable Model Catalog

@objc enum ICDownloadableModelRole: Int {
    case voiceToText = 0
    case textToChapters = 1
}

@objc enum ICChapterModelProvider: Int {
    case localGGUF = 0
    case appleFoundation = 1
    case openAIAPI = 2
    case openAICodexOAuth = 3
    case anthropicAPI = 4
    case kimiAPI = 5
}

@objc class ICDownloadableModel: NSObject, @unchecked Sendable {
    @objc let identifier: String
    @objc let title: String
    @objc let shortTitle: String
    @objc let detail: String
    @objc let role: ICDownloadableModelRole
    @objc let downloadSizeBytes: Int64
    @objc let requiresDownload: Bool
    @objc let supportsCompilation: Bool
    @objc let remoteURLString: String?
    @objc let fileName: String?
    @objc let chapterProvider: ICChapterModelProvider
    @objc let remoteModelName: String?
    let whisperModelName: String?

    init(identifier: String,
         title: String,
         shortTitle: String? = nil,
         detail: String,
         role: ICDownloadableModelRole,
         downloadSizeBytes: Int64,
         requiresDownload: Bool,
         supportsCompilation: Bool,
         remoteURLString: String? = nil,
         fileName: String? = nil,
         chapterProvider: ICChapterModelProvider = .localGGUF,
         remoteModelName: String? = nil,
         whisperModelName: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.shortTitle = shortTitle ?? title
        self.detail = detail
        self.role = role
        self.downloadSizeBytes = downloadSizeBytes
        self.requiresDownload = requiresDownload
        self.supportsCompilation = supportsCompilation
        self.remoteURLString = remoteURLString
        self.fileName = fileName
        self.chapterProvider = chapterProvider
        self.remoteModelName = remoteModelName
        self.whisperModelName = whisperModelName
        super.init()
    }

    @objc var downloadSizeText: String {
        guard downloadSizeBytes > 0 else {
            return NSLocalizedString("Kein Download", comment: "")
        }
        return ByteCountFormatter.string(fromByteCount: downloadSizeBytes, countStyle: .file)
    }

    @objc var roleTitle: String {
        switch role {
        case .voiceToText:
            return NSLocalizedString("Transkribieren", comment: "")
        case .textToChapters:
            return NSLocalizedString("Kapitel generieren", comment: "")
        @unknown default:
            return ""
        }
    }

    @objc var usesRemoteChapterService: Bool {
        switch chapterProvider {
        case .openAIAPI, .openAICodexOAuth, .anthropicAPI, .kimiAPI:
            return true
        default:
            return false
        }
    }

}

@objc enum ICModelDownloadPhase: Int {
    case discovering = 0
    case downloading = 1
    case preparing = 2
    case loading = 3
    case ready = 4
}

@objc class ICModelDownloadProgress: NSObject, @unchecked Sendable {
    @objc let phase: ICModelDownloadPhase
    @objc let statusText: String
    @objc let fraction: Float
    @objc let completedBytes: Int64
    @objc let totalBytes: Int64

    @objc init(phase: ICModelDownloadPhase,
               statusText: String,
               fraction: Float,
               completedBytes: Int64,
               totalBytes: Int64) {
        let normalizedTotal = max(0, totalBytes)
        self.phase = phase
        self.statusText = statusText
        self.fraction = min(max(fraction, 0), 1)
        self.completedBytes = normalizedTotal > 0
            ? min(max(0, completedBytes), normalizedTotal)
            : max(0, completedBytes)
        self.totalBytes = normalizedTotal
        super.init()
    }

    convenience init(fraction: Float, completedBytes: Int64, totalBytes: Int64) {
        self.init(
            phase: .downloading,
            statusText: NSLocalizedString("Wird heruntergeladen", comment: ""),
            fraction: fraction,
            completedBytes: completedBytes,
            totalBytes: totalBytes
        )
    }

    @objc var byteText: String {
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        guard totalBytes > 0 else { return completed }
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(completed) / \(total)"
    }

    @objc var displayText: String {
        guard phase == .downloading, totalBytes > 0 else { return statusText }
        return "\(statusText) · \(byteText)"
    }
}

private final class ICModelDownloadCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelHandlers: [@Sendable () -> Void] = []
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func setTask(_ task: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = cancelled
        if !shouldCancel {
            self.task = task
        }
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func addCancelHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldRun = cancelled
        if !shouldRun {
            cancelHandlers.append(handler)
        }
        lock.unlock()
        if shouldRun {
            handler()
        }
    }

    func cancel() {
        let taskToCancel: Task<Void, Never>?
        let handlers: [@Sendable () -> Void]
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        taskToCancel = task
        handlers = cancelHandlers
        cancelHandlers.removeAll()
        lock.unlock()

        taskToCancel?.cancel()
        handlers.forEach { $0() }
    }
}

@objc class ICModelDownloadTask: NSObject {
    private let cancellationBox: ICModelDownloadCancellationBox

    fileprivate init(cancellationBox: ICModelDownloadCancellationBox) {
        self.cancellationBox = cancellationBox
        super.init()
    }

    @objc var isCancelled: Bool {
        cancellationBox.isCancelled
    }

    @objc func cancel() {
        cancellationBox.cancel()
    }
}

@objc final class ICOpenAIDeviceCodeInfo: NSObject, @unchecked Sendable {
    @objc let verificationURL: String
    @objc let userCode: String
    let deviceAuthID: String
    let interval: UInt64

    init(verificationURL: String, userCode: String, deviceAuthID: String, interval: UInt64) {
        self.verificationURL = verificationURL
        self.userCode = userCode
        self.deviceAuthID = deviceAuthID
        self.interval = interval
        super.init()
    }
}

@objc class ICRemoteChapterCredentialStore: NSObject {
    private static let service = "com.vemedio.instacastplus.remote-chapters"
    private static let openAIAPIKeyAccount = "openai-api-key"
    private static let anthropicAPIKeyAccount = "anthropic-api-key"
    private static let kimiAPIKeyAccount = "kimi-api-key"
    private static let kimiBuiltinEnvResourceName = "KimiBuiltin"
    private static let kimiBuiltinEnvResourceExtension = "env"
    private static let kimiBuiltinEnvKey = "KIMI_BUILTIN_API_KEY"
    private static let kimiBuiltinKeyLock = NSLock()
    private nonisolated(unsafe) static var didLoadKimiBuiltinAPIKey = false
    private nonisolated(unsafe) static var cachedKimiBuiltinAPIKey: String?
    private static let openAIAccessTokenAccount = "openai-oauth-access-token"
    private static let openAIRefreshTokenAccount = "openai-oauth-refresh-token"
    private static let openAIIDTokenAccount = "openai-oauth-id-token"
    private static let openAIAccountIDAccount = "openai-oauth-account-id"
    private static let openAIAccountEmailAccount = "openai-oauth-email"
    private static let openAIFedRAMPAccount = "openai-oauth-fedramp"
    private static let openAIClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let openAIIssuer = "https://auth.openai.com"
    private nonisolated(unsafe) static var didMigrateStoredSecretsForDeviceBackup = false
    private nonisolated(unsafe) static var isMigratingStoredSecretsForDeviceBackup = false

    private static var storedSecretAccounts: [String] {
        [
            openAIAPIKeyAccount,
            anthropicAPIKeyAccount,
            kimiAPIKeyAccount,
            openAIAccessTokenAccount,
            openAIRefreshTokenAccount,
            openAIIDTokenAccount,
            openAIAccountIDAccount,
            openAIAccountEmailAccount,
            openAIFedRAMPAccount,
        ]
    }

    @objc static func hasOpenAIAPIKey() -> Bool {
        return !(openAIAPIKey() ?? "").isEmpty
    }

    static func openAIAPIKey() -> String? {
        return secret(account: openAIAPIKeyAccount)
    }

    @objc(setOpenAIAPIKey:)
    static func setOpenAIAPIKey(_ value: String?) {
        setSecret(trimmedSecret(value), account: openAIAPIKeyAccount)
    }

    @objc static func openAIAPIKeyPreview() -> String {
        return preview(secret(account: openAIAPIKeyAccount))
    }

    @objc static func hasAnthropicAPIKey() -> Bool {
        return !(anthropicAPIKey() ?? "").isEmpty
    }

    static func anthropicAPIKey() -> String? {
        return secret(account: anthropicAPIKeyAccount)
    }

    @objc(setAnthropicAPIKey:)
    static func setAnthropicAPIKey(_ value: String?) {
        setSecret(trimmedSecret(value), account: anthropicAPIKeyAccount)
    }

    @objc static func anthropicAPIKeyPreview() -> String {
        return preview(secret(account: anthropicAPIKeyAccount))
    }

    @objc static func hasKimiAPIKey() -> Bool {
        return !(kimiAPIKey() ?? "").isEmpty
    }

    @objc static func hasKimiUserAPIKey() -> Bool {
        return !(kimiUserAPIKey() ?? "").isEmpty
    }

    static func kimiAPIKey() -> String? {
        if let userKey = kimiUserAPIKey(), !userKey.isEmpty {
            return userKey
        }
        return kimiBuiltinAPIKey()
    }

    static func kimiUserAPIKey() -> String? {
        return secret(account: kimiAPIKeyAccount)
    }

    @objc(setKimiAPIKey:)
    static func setKimiAPIKey(_ value: String?) {
        setSecret(trimmedSecret(value), account: kimiAPIKeyAccount)
    }

    @objc static func kimiAPIKeyPreview() -> String {
        if hasKimiUserAPIKey() {
            return preview(kimiUserAPIKey())
        }
        if let builtinKey = kimiBuiltinAPIKey(), !builtinKey.isEmpty {
            return NSLocalizedString("Integrierter Zugang", comment: "")
        }
        return preview(nil)
    }

    @objc static func backupCredentialValues() -> NSDictionary {
        var values: [String: String] = [:]

        if let value = openAIAPIKey(), !value.isEmpty {
            values["openAIAPIKey"] = value
        }
        if let value = anthropicAPIKey(), !value.isEmpty {
            values["anthropicAPIKey"] = value
        }
        if let value = kimiUserAPIKey(), !value.isEmpty {
            values["kimiAPIKey"] = value
        }
        if let value = secret(account: openAIAccessTokenAccount), !value.isEmpty {
            values["openAIOAuthAccessToken"] = value
        }
        if let value = secret(account: openAIRefreshTokenAccount), !value.isEmpty {
            values["openAIOAuthRefreshToken"] = value
        }
        if let value = secret(account: openAIIDTokenAccount), !value.isEmpty {
            values["openAIOAuthIDToken"] = value
        }
        if let value = secret(account: openAIAccountIDAccount), !value.isEmpty {
            values["openAIOAuthAccountID"] = value
        }
        if let value = secret(account: openAIAccountEmailAccount), !value.isEmpty {
            values["openAIOAuthAccountEmail"] = value
        }
        if let value = secret(account: openAIFedRAMPAccount), !value.isEmpty {
            values["openAIOAuthFedRAMP"] = value
        }

        return values as NSDictionary
    }

    @objc(restoreBackupCredentialValues:)
    static func restoreBackupCredentialValues(_ values: NSDictionary) {
        func stringValue(_ key: String) -> String? {
            guard let value = values[key] as? String else { return nil }
            let trimmed = trimmedSecret(value) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }

        if let value = stringValue("openAIAPIKey") {
            setOpenAIAPIKey(value)
        }
        if let value = stringValue("anthropicAPIKey") {
            setAnthropicAPIKey(value)
        }
        if let value = stringValue("kimiAPIKey") {
            setKimiAPIKey(value)
        }
        if let value = stringValue("openAIOAuthAccessToken") {
            setSecret(value, account: openAIAccessTokenAccount)
        }
        if let value = stringValue("openAIOAuthRefreshToken") {
            setSecret(value, account: openAIRefreshTokenAccount)
        }
        if let value = stringValue("openAIOAuthIDToken") {
            setSecret(value, account: openAIIDTokenAccount)
        }
        if let value = stringValue("openAIOAuthAccountID") {
            setSecret(value, account: openAIAccountIDAccount)
        }
        if let value = stringValue("openAIOAuthAccountEmail") {
            setSecret(value, account: openAIAccountEmailAccount)
        }
        if let value = stringValue("openAIOAuthFedRAMP") {
            setSecret(value == "true" ? "true" : nil, account: openAIFedRAMPAccount)
        }
    }

    @objc static func hasOpenAIOAuthCredentials() -> Bool {
        return !(openAIOAuthAccessToken() ?? "").isEmpty
            && !(openAIOAuthAccountID() ?? "").isEmpty
    }

    static func openAIOAuthAccessToken() -> String? {
        return secret(account: openAIAccessTokenAccount)
    }

    static func openAIOAuthAccountID() -> String? {
        return secret(account: openAIAccountIDAccount)
    }

    static func openAIOAuthIsFedRAMPAccount() -> Bool {
        return secret(account: openAIFedRAMPAccount) == "true"
    }

    @objc static func openAIOAuthAccountLabel() -> String {
        if let email = secret(account: openAIAccountEmailAccount), !email.isEmpty {
            return email
        }
        if hasOpenAIOAuthCredentials() {
            return NSLocalizedString("Angemeldet", comment: "")
        }
        return NSLocalizedString("Nicht angemeldet", comment: "")
    }

    @objc static func clearOpenAIOAuthCredentials() {
        setSecret(nil, account: openAIAccessTokenAccount)
        setSecret(nil, account: openAIRefreshTokenAccount)
        setSecret(nil, account: openAIIDTokenAccount)
        setSecret(nil, account: openAIAccountIDAccount)
        setSecret(nil, account: openAIAccountEmailAccount)
        setSecret(nil, account: openAIFedRAMPAccount)
    }

    @objc(requestOpenAIDeviceCodeWithCompletion:)
    static func requestOpenAIDeviceCode(completion: @escaping (ICOpenAIDeviceCodeInfo?, NSError?) -> Void) {
        nonisolated(unsafe) let completionCallback = completion
        Task.detached {
            do {
                let info = try await requestOpenAIDeviceCode()
                DispatchQueue.main.async { completionCallback(info, nil) }
            } catch {
                DispatchQueue.main.async { completionCallback(nil, error as NSError) }
            }
        }
    }

    @objc(completeOpenAIDeviceLoginWithDeviceCode:completion:)
    static func completeOpenAIDeviceLogin(deviceCode: ICOpenAIDeviceCodeInfo,
                                          completion: @escaping (NSError?) -> Void) {
        nonisolated(unsafe) let completionCallback = completion
        Task.detached {
            do {
                try await completeOpenAIDeviceLogin(deviceCode: deviceCode)
                DispatchQueue.main.async { completionCallback(nil) }
            } catch {
                DispatchQueue.main.async { completionCallback(error as NSError) }
            }
        }
    }

    static func refreshedOpenAIOAuthAccessToken() async throws -> String {
        if let token = openAIOAuthAccessToken(), !token.isEmpty {
            return token
        }
        return try await refreshOpenAIOAuthAccessToken()
    }

    static func refreshOpenAIOAuthAccessToken() async throws -> String {
        guard let refreshToken = secret(account: openAIRefreshTokenAccount), !refreshToken.isEmpty else {
            throw error(code: 41, message: NSLocalizedString("Codex Login fehlt.", comment: ""))
        }

        var request = URLRequest(url: URL(string: "\(openAIIssuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": openAIClientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let data = try await data(for: request, expectedStatusCodes: 200..<300)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              !accessToken.isEmpty else {
            throw error(code: 42, message: NSLocalizedString("Codex Login konnte nicht erneuert werden.", comment: ""))
        }
        storeOpenAITokens(accessToken: accessToken,
                          refreshToken: object["refresh_token"] as? String ?? refreshToken,
                          idToken: object["id_token"] as? String)
        return accessToken
    }

    private static func requestOpenAIDeviceCode() async throws -> ICOpenAIDeviceCodeInfo {
        var request = URLRequest(url: URL(string: "\(openAIIssuer)/api/accounts/deviceauth/usercode")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": openAIClientID,
        ])

        let data = try await data(for: request, expectedStatusCodes: 200..<300)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceAuthID = object["device_auth_id"] as? String,
              let userCode = (object["user_code"] as? String) ?? (object["usercode"] as? String) else {
            throw error(code: 43, message: NSLocalizedString("Codex Gerätecode konnte nicht gelesen werden.", comment: ""))
        }
        let interval = intervalSeconds(from: object["interval"]) ?? 5
        return ICOpenAIDeviceCodeInfo(verificationURL: "\(openAIIssuer)/codex/device",
                                      userCode: userCode,
                                      deviceAuthID: deviceAuthID,
                                      interval: interval)
    }

    private static func completeOpenAIDeviceLogin(deviceCode: ICOpenAIDeviceCodeInfo) async throws {
        let codeResponse = try await pollOpenAIDeviceCode(deviceCode)
        guard let authorizationCode = codeResponse["authorization_code"] as? String,
              let codeVerifier = codeResponse["code_verifier"] as? String else {
            throw error(code: 44, message: NSLocalizedString("ChatGPT Anmeldung lieferte keinen Autorisierungscode.", comment: ""))
        }

        var request = URLRequest(url: URL(string: "\(openAIIssuer)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded([
            "grant_type": "authorization_code",
            "code": authorizationCode,
            "redirect_uri": "\(openAIIssuer)/deviceauth/callback",
            "client_id": openAIClientID,
            "code_verifier": codeVerifier,
        ])

        let data = try await data(for: request, expectedStatusCodes: 200..<300)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String,
              let refreshToken = object["refresh_token"] as? String else {
            throw error(code: 45, message: NSLocalizedString("ChatGPT Anmeldung konnte keine Tokens speichern.", comment: ""))
        }
        storeOpenAITokens(accessToken: accessToken,
                          refreshToken: refreshToken,
                          idToken: object["id_token"] as? String)
    }

    private static func pollOpenAIDeviceCode(_ deviceCode: ICOpenAIDeviceCodeInfo) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15 * 60)
        let sleepSeconds = max(deviceCode.interval, 1)

        while Date() < deadline {
            var request = URLRequest(url: URL(string: "\(openAIIssuer)/api/accounts/deviceauth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceCode.deviceAuthID,
                "user_code": deviceCode.userCode,
            ])

            let (data, statusCode) = try await dataAndStatusCode(for: request)
            if (200..<300).contains(statusCode),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            if statusCode != 403 && statusCode != 404 {
                throw error(code: statusCode, message: String(format: NSLocalizedString("Codex Gerätecode wurde abgelehnt. HTTP %d", comment: ""), statusCode))
            }
            try await Task.sleep(nanoseconds: sleepSeconds * 1_000_000_000)
        }

        throw error(code: 46, message: NSLocalizedString("Codex Gerätecode ist abgelaufen.", comment: ""))
    }

    private static func storeOpenAITokens(accessToken: String, refreshToken: String, idToken: String?) {
        setSecret(accessToken, account: openAIAccessTokenAccount)
        setSecret(refreshToken, account: openAIRefreshTokenAccount)
        if let idToken, !idToken.isEmpty {
            setSecret(idToken, account: openAIIDTokenAccount)
            let claims = jwtClaims(idToken)
            let authClaims = claims?["https://api.openai.com/auth"] as? [String: Any]
            let profileClaims = claims?["https://api.openai.com/profile"] as? [String: Any]
            let accountID = (authClaims?["chatgpt_account_id"] as? String)
                ?? (claims?["chatgpt_account_id"] as? String)
            let email = (profileClaims?["email"] as? String)
                ?? (claims?["email"] as? String)
            let isFedRAMP = (authClaims?["chatgpt_account_is_fedramp"] as? Bool) ?? false
            setSecret(accountID, account: openAIAccountIDAccount)
            setSecret(email, account: openAIAccountEmailAccount)
            setSecret(isFedRAMP ? "true" : nil, account: openAIFedRAMPAccount)
        }
    }

    private static func data(for request: URLRequest, expectedStatusCodes: Range<Int>) async throws -> Data {
        let (data, statusCode) = try await dataAndStatusCode(for: request)
        guard expectedStatusCodes.contains(statusCode) else {
            throw error(code: statusCode, message: String(format: NSLocalizedString("Remote-Anfrage fehlgeschlagen. HTTP %d", comment: ""), statusCode))
        }
        return data
    }

    private static func dataAndStatusCode(for request: URLRequest) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw error(code: 47, message: NSLocalizedString("Remote-Anfrage lieferte keine HTTP-Antwort.", comment: ""))
        }
        return (data, http.statusCode)
    }

    private static func secret(account: String) -> String? {
        migrateStoredSecretsForDeviceBackupIfNeeded()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func migrateStoredSecretsForDeviceBackupIfNeeded() {
        guard !didMigrateStoredSecretsForDeviceBackup, !isMigratingStoredSecretsForDeviceBackup else { return }
        isMigratingStoredSecretsForDeviceBackup = true
        var migrationComplete = true
        defer {
            isMigratingStoredSecretsForDeviceBackup = false
            if migrationComplete {
                didMigrateStoredSecretsForDeviceBackup = true
            }
        }

        for account in storedSecretAccounts {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let attributes: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                migrationComplete = false
                NSLog("[ICRemoteChapterCredentialStore] Keychain accessibility migration failed for %@: %d", account, status)
            }
        }
    }

    private static func setSecret(_ value: String?, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        guard let value = trimmedSecret(value), !value.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func trimmedSecret(_ value: String?) -> String? {
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func preview(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return NSLocalizedString("Nicht eingerichtet", comment: "")
        }
        if value.count <= 8 {
            return NSLocalizedString("Eingerichtet", comment: "")
        }
        let suffix = value.suffix(4)
        return "•••• \(suffix)"
    }

    private static func kimiBuiltinAPIKey() -> String? {
        kimiBuiltinKeyLock.lock()
        if didLoadKimiBuiltinAPIKey {
            let cached = cachedKimiBuiltinAPIKey
            kimiBuiltinKeyLock.unlock()
            return cached
        }
        didLoadKimiBuiltinAPIKey = true
        kimiBuiltinKeyLock.unlock()

        var loadedKey: String?
        if let url = Bundle.main.url(forResource: kimiBuiltinEnvResourceName,
                                     withExtension: kimiBuiltinEnvResourceExtension),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            loadedKey = envValue(named: kimiBuiltinEnvKey, in: text)
        }

        kimiBuiltinKeyLock.lock()
        cachedKimiBuiltinAPIKey = loadedKey
        kimiBuiltinKeyLock.unlock()
        return loadedKey
    }

    private static func envValue(named name: String, in text: String) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == name else {
                continue
            }
            var value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               ((value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))) {
                value.removeFirst()
                value.removeLast()
            }
            return trimmedSecret(value)
        }
        return nil
    }

    private static func intervalSeconds(from value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        if let string = value as? String { return UInt64(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func formURLEncoded(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        let encoded = values.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func error(code: Int, message: String) -> NSError {
        return NSError(domain: "ICRemoteChapterCredentialStore", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class ICTextModelDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let remoteURL: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (ICModelDownloadProgress) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var finishedTemporaryURL: URL?
    private var finishedResponse: URLResponse?
    private var finishedError: Error?

    init(remoteURL: URL,
         expectedBytes: Int64,
         progress: @escaping @Sendable (ICModelDownloadProgress) -> Void) {
        self.remoteURL = remoteURL
        self.expectedBytes = expectedBytes
        self.progress = progress
        super.init()
    }

    func start() async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.default
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: remoteURL)

                lock.lock()
                self.continuation = continuation
                self.session = session
                self.task = task
                lock.unlock()

                task.resume()
            }
        }, onCancel: {
            self.cancel()
        })
    }

    func cancel() {
        lock.lock()
        let task = self.task
        let session = self.session
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        let fraction = total > 0 ? Float(min(Double(totalBytesWritten) / Double(total), 1.0)) : 0
        progress(ICModelDownloadProgress(fraction: fraction,
                                         completedBytes: totalBytesWritten,
                                         totalBytes: total))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("download")
        do {
            try? FileManager.default.removeItem(at: temporaryURL)
            do {
                try FileManager.default.moveItem(at: location, to: temporaryURL)
            } catch {
                try FileManager.default.copyItem(at: location, to: temporaryURL)
            }
            lock.lock()
            finishedTemporaryURL = temporaryURL
            finishedResponse = downloadTask.response
            lock.unlock()
        } catch {
            lock.lock()
            finishedError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let temporaryURL = finishedTemporaryURL
        let response = finishedResponse ?? URLResponse(url: remoteURL,
                                                       mimeType: nil,
                                                       expectedContentLength: Int(expectedBytes),
                                                       textEncodingName: nil)
        let finishError = finishedError
        self.task = nil
        self.session = nil
        lock.unlock()

        session.finishTasksAndInvalidate()

        if let error {
            continuation?.resume(throwing: error)
        } else if let finishError {
            continuation?.resume(throwing: finishError)
        } else if let temporaryURL {
            continuation?.resume(returning: (temporaryURL, response))
        } else {
            continuation?.resume(throwing: NSError(domain: "ICDownloadableModelStore", code: 5,
                                                  userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Download konnte nicht abgeschlossen werden.", comment: "")]))
        }
    }
}

@objc class ICDownloadableModelStore: NSObject {
    private static let chapterModelKey = "ChapterGenerationModel"
    private static let defaultChapterModelIdentifier = "gemma-4-e2b-it-q4-k"
    private static let removedTextModelIdentifiers: Set<String> = ["granite-3.3-2b-instruct-q4-k-m"]
    private static let legacyChapterModelSuccessors: [String: String] = [
        "openai-chatgpt-5.5-oauth": "openai-codex-gpt-5.6-sol-oauth",
        "openai-codex-oauth": "openai-codex-gpt-5.6-sol-oauth",
        "anthropic-claude-opus-4.7-api-key": "anthropic-claude-sonnet-5-api-key",
        "kimi-k2.6-api-key": "kimi-k3-api-key",
    ]
    private static let modelRootDirectoryName = "DownloadedModels"
    private static let downloadStateLock = NSLock()
    private static let removedModelCleanupLock = NSLock()
    private nonisolated(unsafe) static var activeDownloadTasksByModelID: [String: ICModelDownloadTask] = [:]
    private nonisolated(unsafe) static var activeDownloadProgressByModelID: [String: ICModelDownloadProgress] = [:]
    private nonisolated(unsafe) static var didScheduleRemovedTextModelCleanup = false

    private static let models: [ICDownloadableModel] = [
        ICDownloadableModel(
            identifier: "whisperkit-large-v3-turbo",
            title: "WhisperKit Large V3 Turbo",
            shortTitle: "Whisper Large",
            detail: NSLocalizedString("Beste lokale Genauigkeit, aber langsamer und energieintensiver. Kostenlos; Laufzeit geräteabhängig.", comment: ""),
            role: .voiceToText,
            downloadSizeBytes: 645_000_000,
            requiresDownload: true,
            supportsCompilation: true,
            whisperModelName: "openai_whisper-large-v3-v20240930_turbo_632MB"
        ),
        ICDownloadableModel(
            identifier: "whisperkit-small",
            title: "WhisperKit Small",
            shortTitle: "Whisper Small",
            detail: NSLocalizedString("Schneller und sparsamer, aber weniger genau. Kostenlos; Laufzeit geräteabhängig.", comment: ""),
            role: .voiceToText,
            downloadSizeBytes: 216_000_000,
            requiresDownload: true,
            supportsCompilation: true,
            whisperModelName: "openai_whisper-small_216MB"
        ),
        ICDownloadableModel(
            identifier: "apple-speech",
            title: NSLocalizedString("Apple Spracherkennung", comment: ""),
            shortTitle: "Apple",
            detail: NSLocalizedString("Kostenlos · Verarbeitung auf dem Gerät. Geschwindigkeit und Sprachunterstützung hängen von iOS und Gerät ab.", comment: ""),
            role: .voiceToText,
            downloadSizeBytes: 0,
            requiresDownload: false,
            supportsCompilation: false
        ),
        ICDownloadableModel(
            identifier: "openai-codex-gpt-5.6-sol-oauth",
            title: "OpenAI GPT-5.6 Sol",
            shortTitle: "GPT-5.6 Sol",
            detail: NSLocalizedString("OpenAI-Qualitätsmodell; höhere Latenz und Kosten. Geschätzte Kosten pro 1 h Transkript: USD 0,10–0,40.", comment: ""),
            role: .textToChapters,
            downloadSizeBytes: 0,
            requiresDownload: false,
            supportsCompilation: false,
            chapterProvider: .openAICodexOAuth,
            remoteModelName: "gpt-5.6-sol"
        ),
        ICDownloadableModel(
            identifier: "openai-gpt-5.6-terra-api-key",
            title: "OpenAI GPT-5.6 Terra",
            shortTitle: "GPT-5.6 Terra",
            detail: NSLocalizedString("OpenAI-Modell mit ausgewogenem Verhältnis aus Qualität, Geschwindigkeit und Kosten. Geschätzte Kosten pro 1 h Transkript: USD 0,05–0,20.", comment: ""),
            role: .textToChapters,
            downloadSizeBytes: 0,
            requiresDownload: false,
            supportsCompilation: false,
            chapterProvider: .openAIAPI,
            remoteModelName: "gpt-5.6-terra"
        ),
        ICDownloadableModel(
            identifier: "kimi-k3-api-key",
            title: "Kimi K3",
            shortTitle: "Kimi K3",
            detail: NSLocalizedString("Analyse mit aktivem Reasoning. Geschätzte Kosten pro 1 h Transkript: USD 0,10–0,30 mit eigenem API-Key; integrierter Zugang ohne eigene Abrechnung.", comment: ""),
            role: .textToChapters,
            downloadSizeBytes: 0,
            requiresDownload: false,
            supportsCompilation: false,
            chapterProvider: .kimiAPI,
            remoteModelName: "kimi-k3"
        ),
        ICDownloadableModel(
            identifier: "anthropic-claude-sonnet-5-api-key",
            title: "Anthropic Claude Sonnet 5",
            shortTitle: "Claude Sonnet 5",
            detail: NSLocalizedString("Ausgewogenes Qualitätsmodell. Geschätzte Kosten pro 1 h Transkript: USD 0,05–0,20.", comment: ""),
            role: .textToChapters,
            downloadSizeBytes: 0,
            requiresDownload: false,
            supportsCompilation: false,
            chapterProvider: .anthropicAPI,
            remoteModelName: "claude-sonnet-5"
        ),
        ICDownloadableModel(
            identifier: "gemma-4-e2b-it-q4-k",
            title: "Gemma 4 E2B-it",
            shortTitle: "Gemma 4",
            detail: NSLocalizedString("Kostenlos und vollständig lokal. Sehr hoher Speicherbedarf, langsame Verarbeitung; Qualität schwankt je nach Folge.", comment: ""),
            role: .textToChapters,
            downloadSizeBytes: 2_629_991_680,
            requiresDownload: true,
            supportsCompilation: false,
            remoteURLString: "https://huggingface.co/eaddario/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K.gguf",
            fileName: "gemma-4-E2B-it-Q4_K.gguf"
        ),
        ICDownloadableModel(
            identifier: "apple-foundation-models",
            title: NSLocalizedString("Apple Intelligence", comment: ""),
            shortTitle: "Apple",
            detail: NSLocalizedString("Kostenlos · Kapitelanalyse auf dem Gerät. Nur auf unterstützten Apple-Intelligence-Geräten; Laufzeit und Qualität hängen von Gerät und Transkriptlänge ab.", comment: ""),
            role: .textToChapters,
            downloadSizeBytes: 0,
            requiresDownload: false,
            supportsCompilation: false,
            chapterProvider: .appleFoundation
        ),
    ]

    @objc static func allModels() -> [ICDownloadableModel] {
        cleanupRemovedTextModelsIfNeeded()
        return models
    }

    @objc(modelsForRole:)
    static func models(for role: ICDownloadableModelRole) -> [ICDownloadableModel] {
        cleanupRemovedTextModelsIfNeeded()
        return models.filter { $0.role == role }
    }

    @objc(modelWithIdentifier:)
    static func model(identifier: String) -> ICDownloadableModel? {
        models.first { $0.identifier == identifier }
    }

    @objc(selectedModelForRole:)
    static func selectedModel(for role: ICDownloadableModelRole) -> ICDownloadableModel {
        cleanupRemovedTextModelsIfNeeded()
        switch role {
        case .voiceToText:
            let engine = UserDefaults.standard.string(forKey: "TranscriptionEngine") ?? ""
            if engine == "Apple" {
                return model(identifier: "apple-speech")!
            }
            let modelName = WhisperKitBackend.resolvedModelName()
            if modelName.contains("large") {
                return model(identifier: "whisperkit-large-v3-turbo")!
            }
            return model(identifier: "whisperkit-small")!
        case .textToChapters:
            if let identifier = UserDefaults.standard.string(forKey: chapterModelKey) {
                if let successorIdentifier = legacyChapterModelSuccessors[identifier],
                   let selectedModel = model(identifier: successorIdentifier) {
                    UserDefaults.standard.set(selectedModel.identifier, forKey: chapterModelKey)
                    return selectedModel
                }
                if let selectedModel = model(identifier: identifier) {
                    return selectedModel
                }
            }
            UserDefaults.standard.set(defaultChapterModelIdentifier, forKey: chapterModelKey)
            return model(identifier: defaultChapterModelIdentifier)!
        @unknown default:
            return models.first!
        }
    }

    @objc(selectModel:)
    static func select(model: ICDownloadableModel) {
        switch model.role {
        case .voiceToText:
            if model.identifier == "apple-speech" {
                UserDefaults.standard.set("Apple", forKey: "TranscriptionEngine")
            } else if let whisperModelName = model.whisperModelName {
                UserDefaults.standard.set("WhisperKit", forKey: "TranscriptionEngine")
                UserDefaults.standard.set(whisperModelName, forKey: "TranscriptionWhisperModel")
            }
        case .textToChapters:
            UserDefaults.standard.set(model.identifier, forKey: chapterModelKey)
        @unknown default:
            break
        }
        ICDiagnosticLogger.shared.logEvent("model", message: "Modell ausgewählt", metadata: [
            "model": model.identifier,
            "role": model.roleTitle,
        ] as NSDictionary)
    }

    @objc static func selectedVoiceModelIsReady() -> Bool {
        isDownloaded(model: selectedModel(for: .voiceToText))
    }

    @objc static func selectedChapterModelIsReady() -> Bool {
        isDownloaded(model: selectedModel(for: .textToChapters))
    }

    @MainActor
    @objc static func selectedChapterModelCanGenerate() -> Bool {
        let model = selectedModel(for: .textToChapters)
        guard isDownloaded(model: model) else { return false }
        switch model.chapterProvider {
        case .appleFoundation:
            return ChapterGenerator.isAvailable()
        case .openAIAPI:
            return ICRemoteChapterCredentialStore.hasOpenAIAPIKey()
        case .openAICodexOAuth:
            return ICRemoteChapterCredentialStore.hasOpenAIAPIKey() || ICRemoteChapterCredentialStore.hasOpenAIOAuthCredentials()
        case .anthropicAPI:
            return ICRemoteChapterCredentialStore.hasAnthropicAPIKey()
        case .kimiAPI:
            return ICRemoteChapterCredentialStore.hasKimiAPIKey()
        case .localGGUF:
            return model.role == .textToChapters && modelFileURL(for: model) != nil
        }
    }

    @MainActor
    @objc static func selectedChapterModelUnavailableReason() -> String {
        let model = selectedModel(for: .textToChapters)
        if !isDownloaded(model: model) {
            return NSLocalizedString("Kapitelmodell ist nicht geladen.", comment: "")
        }
        switch model.chapterProvider {
        case .appleFoundation:
            return ChapterGenerator.unavailabilityReason() ?? NSLocalizedString("Apple Intelligence nicht verfügbar.", comment: "")
        case .openAIAPI:
            return NSLocalizedString("OpenAI API-Key fehlt.", comment: "")
        case .openAICodexOAuth:
            return NSLocalizedString("OpenAI API-Key oder Codex Login fehlt.", comment: "")
        case .anthropicAPI:
            return NSLocalizedString("Anthropic API-Key fehlt.", comment: "")
        case .kimiAPI:
            return NSLocalizedString("Kimi Zugang fehlt.", comment: "")
        case .localGGUF:
            return NSLocalizedString("Kapitelmodell ist nicht bereit.", comment: "")
        }
    }

    @objc(isDownloadedModel:)
    static func isDownloaded(model: ICDownloadableModel) -> Bool {
        guard model.requiresDownload else { return true }
        switch model.role {
        case .voiceToText:
            guard let modelName = model.whisperModelName else { return false }
            return WhisperKitBackend.shared.isModelDownloadedSync(modelName: modelName)
        case .textToChapters:
            return modelFileURL(for: model) != nil
        @unknown default:
            return false
        }
    }

    @objc(sizeOnDiskForModel:)
    static func sizeOnDisk(model: ICDownloadableModel) -> Int64 {
        guard model.requiresDownload else { return 0 }
        switch model.role {
        case .voiceToText:
            guard let modelName = model.whisperModelName else { return 0 }
            return WhisperKitBackend.shared.modelSizeOnDiskSync(modelName: modelName)
        case .textToChapters:
            return directorySize(at: modelDirectory(for: model))
        @unknown default:
            return 0
        }
    }

    @objc(modelFileURLForModel:)
    static func modelFileURL(for model: ICDownloadableModel) -> URL? {
        guard model.role == .textToChapters, let fileName = model.fileName else { return nil }
        let url = modelDirectory(for: model).appendingPathComponent(fileName)
        return validateTextModelFile(at: url, expectedBytes: model.downloadSizeBytes) ? url : nil
    }

    @objc(downloadTaskForModel:)
    static func downloadTask(for model: ICDownloadableModel) -> ICModelDownloadTask? {
        downloadStateLock.lock()
        let task = activeDownloadTasksByModelID[model.identifier]
        downloadStateLock.unlock()
        return task
    }

    @objc(downloadProgressForModel:)
    static func downloadProgress(for model: ICDownloadableModel) -> ICModelDownloadProgress? {
        downloadStateLock.lock()
        let progress = activeDownloadProgressByModelID[model.identifier]
        downloadStateLock.unlock()
        return progress
    }

    @objc(isDownloadingModel:)
    static func isDownloading(model: ICDownloadableModel) -> Bool {
        return downloadTask(for: model) != nil
    }

    @objc(cancelDownloadForModel:)
    static func cancelDownload(for model: ICDownloadableModel) {
        guard let task = downloadTask(for: model) else { return }
        ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Download abgebrochen", metadata: [
            "model": model.identifier,
            "role": model.roleTitle,
        ] as NSDictionary)
        task.cancel()
    }

    @objc(downloadModel:progress:completion:)
    @discardableResult
    static func download(model: ICDownloadableModel,
                         progress: @escaping (Float) -> Void,
                         completion: @escaping (NSError?) -> Void) -> ICModelDownloadTask {
        return download(model: model, detailProgress: { detail in
            progress(detail.fraction)
        }, completion: completion)
    }

    @objc(downloadModel:detailProgress:completion:)
    @discardableResult
    static func download(model: ICDownloadableModel,
                         detailProgress: @escaping (ICModelDownloadProgress) -> Void,
                         completion: @escaping (NSError?) -> Void) -> ICModelDownloadTask {
        select(model: model)
        if let existingTask = downloadTask(for: model) {
            if let existingProgress = downloadProgress(for: model) {
                detailProgress(existingProgress)
            }
            return existingTask
        }
        let cancellationBox = ICModelDownloadCancellationBox()
        let downloadTask = ICModelDownloadTask(cancellationBox: cancellationBox)
        guard model.requiresDownload else {
            detailProgress(ICModelDownloadProgress(
                phase: .ready,
                statusText: NSLocalizedString("Bereit", comment: ""),
                fraction: 1,
                completedBytes: 0,
                totalBytes: 0
            ))
            completion(nil)
            return downloadTask
        }

        let selectedModel = model
        nonisolated(unsafe) let detailProgressCallback = detailProgress
        nonisolated(unsafe) let completionCallback = completion
        setActiveDownloadTask(downloadTask, for: selectedModel)
        ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Download gestartet", metadata: [
            "model": selectedModel.identifier,
            "role": selectedModel.roleTitle,
            "expectedBytes": selectedModel.downloadSizeBytes,
        ] as NSDictionary)
        let task = Task.detached {
            do {
                let reportProgress: @Sendable (ICModelDownloadProgress) -> Void = { progress in
                    setActiveDownloadProgress(progress, for: selectedModel)
                    DispatchQueue.main.async {
                        detailProgressCallback(progress)
                    }
                }

                reportProgress(ICModelDownloadProgress(
                    phase: .discovering,
                    statusText: NSLocalizedString("Download wird vorbereitet.", comment: ""),
                    fraction: 0,
                    completedBytes: 0,
                    totalBytes: selectedModel.downloadSizeBytes
                ))

                try Task.checkCancellation()
                switch selectedModel.role {
                case .voiceToText:
                    guard let modelName = selectedModel.whisperModelName else {
                        throw NSError(domain: "ICDownloadableModelStore", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "Whisper model name missing"])
                    }
                    do {
                        try await WhisperKitBackend.shared.downloadModel(
                            modelName: modelName,
                            transferProgress: { hubProgress in
                                let total = selectedModel.downloadSizeBytes
                                let fraction = Float(min(max(hubProgress.fractionCompleted, 0), 1))
                                let completed = total > 0 ? Int64((Double(total) * Double(fraction)).rounded()) : 0
                                reportProgress(ICModelDownloadProgress(
                                    phase: .downloading,
                                    statusText: NSLocalizedString("Wird heruntergeladen", comment: ""),
                                    fraction: fraction,
                                    completedBytes: completed,
                                    totalBytes: total
                                ))
                            },
                            phaseUpdate: { phase, status in
                                let total = selectedModel.downloadSizeBytes
                                let completed = phase.rawValue >= ICModelDownloadPhase.preparing.rawValue ? total : 0
                                reportProgress(ICModelDownloadProgress(
                                    phase: phase,
                                    statusText: status,
                                    fraction: phase == .ready ? 1 : 0,
                                    completedBytes: completed,
                                    totalBytes: total
                                ))
                            }
                        )
                    } catch {
                        if cancellationBox.isCancelled || Task.isCancelled {
                            await WhisperKitBackend.shared.deleteModel(modelName: modelName)
                        }
                        throw error
                    }
                case .textToChapters:
                    try await downloadTextModel(selectedModel,
                                                progress: reportProgress,
                                                cancellationBox: cancellationBox)
                @unknown default:
                    break
                }
                try Task.checkCancellation()
                clearActiveDownload(for: selectedModel)
                await MainActor.run {
                    detailProgressCallback(ICModelDownloadProgress(
                        phase: .ready,
                        statusText: NSLocalizedString("Geladen und vorbereitet.", comment: ""),
                        fraction: 1,
                        completedBytes: selectedModel.downloadSizeBytes,
                        totalBytes: selectedModel.downloadSizeBytes
                    ))
                    completionCallback(nil)
                }
                ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Download beendet", metadata: [
                    "model": selectedModel.identifier,
                    "role": selectedModel.roleTitle,
                ] as NSDictionary)
            } catch {
                let nsError = downloadError(error, cancelled: cancellationBox.isCancelled || Task.isCancelled)
                ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Download fehlgeschlagen", metadata: [
                    "model": selectedModel.identifier,
                    "role": selectedModel.roleTitle,
                    "error": nsError.localizedDescription,
                ] as NSDictionary)
                clearActiveDownload(for: selectedModel)
                await MainActor.run {
                    completionCallback(nsError)
                }
            }
        }
        cancellationBox.setTask(task)
        return downloadTask
    }

    private static func setActiveDownloadTask(_ task: ICModelDownloadTask, for model: ICDownloadableModel) {
        downloadStateLock.lock()
        activeDownloadTasksByModelID[model.identifier] = task
        downloadStateLock.unlock()
    }

    private static func setActiveDownloadProgress(_ progress: ICModelDownloadProgress, for model: ICDownloadableModel) {
        downloadStateLock.lock()
        activeDownloadProgressByModelID[model.identifier] = progress
        downloadStateLock.unlock()
    }

    private static func clearActiveDownload(for model: ICDownloadableModel) {
        downloadStateLock.lock()
        activeDownloadTasksByModelID.removeValue(forKey: model.identifier)
        activeDownloadProgressByModelID.removeValue(forKey: model.identifier)
        downloadStateLock.unlock()
    }

    @objc(prepareModel:completion:)
    static func prepare(model: ICDownloadableModel,
                        completion: @escaping (NSError?) -> Void) {
        guard isDownloaded(model: model) else {
            completion(NSError(domain: "ICDownloadableModelStore", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Modell ist nicht geladen.", comment: "")]))
            return
        }

        let selectedModel = model
        nonisolated(unsafe) let completionCallback = completion
        Task.detached {
            do {
                if selectedModel.role == .voiceToText, let modelName = selectedModel.whisperModelName {
                    try await WhisperKitBackend.shared.prepareModel(modelName: modelName)
                } else {
                    ICDiagnosticLogger.shared.logEvent("model", message: "Kapitelmodell geprüft", metadata: [
                        "model": selectedModel.identifier,
                        "path": modelDirectory(for: selectedModel).path,
                    ] as NSDictionary)
                }
                await MainActor.run { completionCallback(nil) }
            } catch {
                await MainActor.run { completionCallback(error as NSError) }
            }
        }
    }

    @MainActor
    @objc(deleteModel:completion:)
    static func delete(model: ICDownloadableModel,
                       completion: @escaping (NSError?) -> Void) {
        guard model.requiresDownload else {
            completion(nil)
            return
        }

        let selectedModel = model
        if let blockedReason = TranscriptionQueue.shared.modelDeletionBlockReason(for: selectedModel) {
            let error = NSError(domain: "ICDownloadableModelStore.deleteModelBlocked", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: blockedReason])
            ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Löschung blockiert", metadata: [
                "model": selectedModel.identifier,
                "role": selectedModel.roleTitle,
                "reason": blockedReason,
            ] as NSDictionary)
            completion(error)
            return
        }

        nonisolated(unsafe) let completionCallback = completion
        Task.detached {
            do {
                switch selectedModel.role {
                case .voiceToText:
                    if let modelName = selectedModel.whisperModelName {
                        await WhisperKitBackend.shared.deleteModel(modelName: modelName)
                    }
                case .textToChapters:
                    try? FileManager.default.removeItem(at: modelDirectory(for: selectedModel))
                @unknown default:
                    break
                }
                ICDiagnosticLogger.shared.logEvent("model", message: "Modell gelöscht", metadata: [
                    "model": selectedModel.identifier,
                    "role": selectedModel.roleTitle,
                ] as NSDictionary)
                await MainActor.run { completionCallback(nil) }
            }
        }
    }

    private static func downloadTextModel(_ model: ICDownloadableModel,
                                          progress: @escaping @Sendable (ICModelDownloadProgress) -> Void,
                                          cancellationBox: ICModelDownloadCancellationBox) async throws {
        guard let urlString = model.remoteURLString,
              let remoteURL = URL(string: urlString),
              let fileName = model.fileName else {
            throw NSError(domain: "ICDownloadableModelStore", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Model download URL missing"])
        }

        if model.downloadSizeBytes > 0 {
            let requiredBytes = model.downloadSizeBytes + 512 * 1024 * 1024
            let availableBytes = freeDiskBytes()
            if availableBytes < requiredBytes {
                let requiredText = ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)
                let availableText = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
                throw NSError(domain: "ICDownloadableModelStore", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: String(format: NSLocalizedString("Nicht genug freier Speicher für diesen Download. Benötigt %@. Verfügbar %@.", comment: ""), requiredText, availableText)])
            }
        }

        let directory = modelDirectory(for: model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ICSetExcludedFromBackup(directory)

        let destinationURL = directory.appendingPathComponent(fileName)
        let operation = ICTextModelDownloadOperation(remoteURL: remoteURL,
                                                     expectedBytes: model.downloadSizeBytes,
                                                     progress: progress)
        cancellationBox.addCancelHandler {
            operation.cancel()
        }
        let (temporaryURL, response) = try await operation.start()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw NSError(domain: "ICDownloadableModelStore", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }

        guard validateTextModelFile(at: temporaryURL, expectedBytes: model.downloadSizeBytes) else {
            try? FileManager.default.removeItem(at: temporaryURL)
            ICDiagnosticLogger.shared.logEvent("model", message: "Modell-Download ungültig", metadata: [
                "model": model.identifier,
                "expectedBytes": model.downloadSizeBytes,
            ] as NSDictionary)
            throw NSError(domain: "ICDownloadableModelStore", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Modell-Download ungültig. Bitte erneut laden.", comment: "")])
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        ICSetExcludedFromBackup(destinationURL)
        progress(ICModelDownloadProgress(fraction: 1,
                                         completedBytes: model.downloadSizeBytes,
                                         totalBytes: model.downloadSizeBytes))
        ICDiagnosticLogger.shared.logEvent("model", message: "Kapitelmodell heruntergeladen", metadata: [
            "model": model.identifier,
            "path": destinationURL.path,
            "bytesOnDisk": directorySize(at: directory),
        ] as NSDictionary)
    }

    private static func modelDirectory(for model: ICDownloadableModel) -> URL {
        return modelRootDirectory()
            .appendingPathComponent(model.identifier, isDirectory: true)
    }

    private static func modelRootDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(modelRootDirectoryName, isDirectory: true)
    }

    private static func cleanupRemovedTextModelsIfNeeded() {
        removedModelCleanupLock.lock()
        if didScheduleRemovedTextModelCleanup {
            removedModelCleanupLock.unlock()
            return
        }
        didScheduleRemovedTextModelCleanup = true
        removedModelCleanupLock.unlock()

        let identifiers = removedTextModelIdentifiers
        Task.detached {
            let root = modelRootDirectory()
            for identifier in identifiers {
                let directory = root.appendingPathComponent(identifier, isDirectory: true)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                do {
                    try FileManager.default.removeItem(at: directory)
                    ICDiagnosticLogger.shared.logEvent("model", message: "Entferntes Kapitelmodell gelöscht", metadata: [
                        "model": identifier,
                        "path": directory.path,
                    ] as NSDictionary)
                } catch {
                    ICDiagnosticLogger.shared.logEvent("model", message: "Entferntes Kapitelmodell konnte nicht gelöscht werden", metadata: [
                        "model": identifier,
                        "path": directory.path,
                        "error": error.localizedDescription,
                    ] as NSDictionary)
                }
            }
        }
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var totalSize: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    totalSize += Int64(size)
                }
            }
        }
        return totalSize
    }

    private static func validateTextModelFile(at url: URL, expectedBytes: Int64) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if expectedBytes > 0 {
            let minimumBytes = Int64(Double(expectedBytes) * 0.98)
            guard size >= minimumBytes else { return false }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4),
              data.count == 4,
              String(data: data, encoding: .ascii) == "GGUF" else { return false }
        return true
    }

    private static func freeDiskBytes() -> Int64 {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            return available
        }
        if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let available = values.volumeAvailableCapacity {
            return Int64(available)
        }
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
              let freeSpace = attrs[.systemFreeSize] as? NSNumber else { return Int64.max }
        return freeSpace.int64Value
    }

    private static func downloadError(_ error: Error, cancelled: Bool) -> NSError {
        if cancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
            return NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                           userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Download abgebrochen.", comment: "")])
        }
        return error as NSError
    }
}

// MARK: - Crash backtrace capture
//
// Captures a backtrace for uncaught Obj-C exceptions and fatal signals (EXC_BAD_ACCESS,
// EXC_BREAKPOINT / dispatch_assert_queue, SIGABRT, …) into a file that is folded into the
// diagnostics log on the next launch. This makes standalone / TestFlight crashes
// self-documenting — no attached debugger required. (Under the Xcode debugger the Mach
// exception handler intercepts first, so these handlers fire when running WITHOUT a debugger.)

// Set once in ICInstallCrashBacktraceHandler before any handler can run, then only read
// from the handlers — hence nonisolated(unsafe) rather than a lock.
nonisolated(unsafe) private var icCrashReportFD: Int32 = -1
nonisolated(unsafe) private var icCrashSignalMarker: UnsafeMutablePointer<CChar>?
nonisolated(unsafe) private var icCrashBacktraceBuffer: UnsafeMutablePointer<UnsafeMutableRawPointer?>?

// Signal handlers must stay async-signal-safe: pre-allocated buffer + marker, and only
// backtrace()/backtrace_symbols_fd()/write()/fsync()/raise() — no Swift allocation.
private let icCrashSignalHandler: @convention(c) (Int32) -> Void = { signo in
    if icCrashReportFD >= 0, let buffer = icCrashBacktraceBuffer {
        if let marker = icCrashSignalMarker { _ = write(icCrashReportFD, marker, strlen(marker)) }
        let frames = backtrace(buffer, 256)
        backtrace_symbols_fd(buffer, frames, icCrashReportFD)
        fsync(icCrashReportFD)
    }
    signal(signo, SIG_DFL)
    raise(signo)
}

private let icCrashExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    guard icCrashReportFD >= 0 else { return }
    // Runs in a normal (non-signal) context, so Foundation usage is fine here.
    var text = "\n========== CRASH (NSException) ==========\n"
    text += "name: \(exception.name.rawValue)\n"
    text += "reason: \(exception.reason ?? "")\n"
    text += exception.callStackSymbols.joined(separator: "\n")
    text += "\n"
    text.withCString { _ = write(icCrashReportFD, $0, strlen($0)) }
    fsync(icCrashReportFD)
}

func ICInstallCrashBacktraceHandler(_ path: String) {
    guard icCrashReportFD < 0 else { return }
    let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
    guard fd >= 0 else { return }
    icCrashReportFD = fd
    icCrashSignalMarker = strdup("\n========== CRASH (signal) ==========\n")
    icCrashBacktraceBuffer = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 256)
    NSSetUncaughtExceptionHandler(icCrashExceptionHandler)
    for signo in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
        signal(signo, icCrashSignalHandler)
    }
}
