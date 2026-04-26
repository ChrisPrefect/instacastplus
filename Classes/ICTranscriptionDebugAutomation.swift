//
//  ICTranscriptionDebugAutomation.swift
//  Instacast
//
//  Narrow command surface for remote transcription and chapter debugging.
//

import Foundation

@MainActor
@objc class ICTranscriptionDebugAutomation: NSObject {

    private static var commandTimer: Timer?
    private static var didStartCommandProcessing = false
    private static var lastCommandIdentifier: String?

    @objc static func startCommandProcessing() {
        guard !didStartCommandProcessing else { return }
        didStartCommandProcessing = true

        let directory = automationDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        processCommandFile()

        commandTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                processCommandFile()
            }
        }
        commandTimer?.tolerance = 0.25

        ICDiagnosticLogger.shared.logEvent("debug-automation",
                                           message: "Transkriptionsbefehle werden beobachtet",
                                           metadata: [
                                            "commandPath": directory.appendingPathComponent("command.json").path,
                                           ] as NSDictionary)
    }

    @objc static func handleLaunchArguments() -> Bool {
        guard let command = commandFromLaunchArguments(ProcessInfo.processInfo.arguments) else {
            return false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                _ = handleCommandDictionary(command, source: "launchArgument", commandID: command["id"] as? String)
            }
        }
        return true
    }

    @objc static func handleCommandDictionary(_ command: NSDictionary) -> Bool {
        handleCommandDictionary(command, source: "dictionary", commandID: command["id"] as? String)
    }

    @objc static func handle(_ url: URL) -> Bool {
        guard url.scheme == "instacastplus", url.host == "transcription-debug" else {
            return false
        }

        return handleAutomationURL(url, source: "url", commandID: nil)
    }

    private static func processCommandFile() {
        let commandURL = automationDirectory().appendingPathComponent("command.json")
        guard let data = try? Data(contentsOf: commandURL), !data.isEmpty else {
            return
        }

        let rawCommand = String(data: data, encoding: .utf8) ?? "\(data.count)"
        guard let object = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            if lastCommandIdentifier != rawCommand {
                lastCommandIdentifier = rawCommand
                let response = errorResponse(action: "commandFile", message: "command.json ist kein JSON-Objekt")
                _ = writeResponse(response, action: "commandFile")
            }
            return
        }

        let commandID = object["id"] as? String ?? rawCommand
        guard commandID != lastCommandIdentifier else { return }
        lastCommandIdentifier = commandID

        _ = handleCommandDictionary(object, source: "commandFile", commandID: commandID)
    }

    private static func commandFromLaunchArguments(_ arguments: [String]) -> NSDictionary? {
        var command: [String: Any] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let nextValue: String? = index + 1 < arguments.count ? arguments[index + 1] : nil

            switch argument {
            case "--transcription-debug":
                if let nextValue {
                    if nextValue.contains("://") {
                        command["url"] = nextValue
                    } else {
                        command["action"] = nextValue
                    }
                    index += 1
                }
            case "--transcription-debug-url":
                if let nextValue {
                    command["url"] = nextValue
                    index += 1
                }
            case "--transcription-debug-action":
                if let nextValue {
                    command["action"] = nextValue
                    index += 1
                }
            case "--transcription-debug-episode", "--transcription-debug-episodeHash":
                if let nextValue {
                    command["episodeHash"] = nextValue
                    index += 1
                }
            case "--transcription-debug-limit":
                if let nextValue {
                    command["limit"] = nextValue
                    index += 1
                }
            default:
                break
            }
            index += 1
        }

        guard command["url"] != nil || command["action"] != nil else {
            return nil
        }
        command["id"] = command["id"] ?? "launch-\(filenameTimestamp(Date()))"
        return command as NSDictionary
    }

    private static func handleCommandDictionary(_ command: NSDictionary, source: String, commandID: String?) -> Bool {
        if let urlString = stringValue(command["url"]), let url = URL(string: urlString) {
            guard url.scheme == "instacastplus", url.host == "transcription-debug" else {
                let response = errorResponse(action: "command", message: "URL ist kein Transkriptions-Debug-Befehl")
                _ = writeResponse(response, action: "command")
                return false
            }
            return handleAutomationURL(url, source: source, commandID: commandID)
        }

        var parameters: [String: String] = [:]
        for (key, value) in command {
            guard let keyString = key as? String else { continue }
            if let valueString = stringValue(value) {
                parameters[keyString] = valueString
            }
        }
        let action = parameters["action"] ?? "status"
        handleAutomation(action: action, parameters: parameters, source: source, commandID: commandID)
        return true
    }

    private static func handleAutomationURL(_ url: URL, source: String, commandID: String?) -> Bool {
        let parameters = queryParameters(from: url)
        let action = parameters["action"] ?? pathAction(from: url) ?? "status"
        handleAutomation(action: action, parameters: parameters, source: source, commandID: commandID)
        return true
    }

    private static func handleAutomation(action: String, parameters: [String: String], source: String, commandID: String?) {
        var response: [String: Any] = [
            "ok": true,
            "action": action,
            "source": source,
            "timestamp": timestampString(Date()),
        ]
        if let commandID {
            response["commandID"] = commandID
        }

        let queue = TranscriptionQueue.shared
        let episodeHash = parameters["episodeHash"] ?? parameters["hash"]

        switch action {
        case "status":
            response["queue"] = queue.debugQueueSnapshot()
            response["selectedChapterModel"] = modelDictionary(ICDownloadableModelStore.selectedModel(for: .textToChapters))
        case "modelStatus":
            response["voiceModels"] = modelList(role: .voiceToText)
            response["chapterModels"] = modelList(role: .textToChapters)
            response["selectedChapterModel"] = modelDictionary(ICDownloadableModelStore.selectedModel(for: .textToChapters))
        case "listEpisodes":
            response["episodes"] = episodeList(limit: Int(parameters["limit"] ?? "") ?? 50)
        case "inspect":
            guard let episodeHash else {
                response = errorResponse(action: action, message: "episodeHash fehlt")
                break
            }
            response["inspection"] = queue.debugInspection(episodeHash: episodeHash)
        case "enqueue", "transcribe":
            guard let episodeHash else {
                response = errorResponse(action: action, message: "episodeHash fehlt")
                break
            }
            response["started"] = queue.enqueueExistingEpisode(episodeHash: episodeHash)
            response["inspection"] = queue.debugInspection(episodeHash: episodeHash)
        case "chapters", "generateChapters":
            guard let episodeHash else {
                response = errorResponse(action: action, message: "episodeHash fehlt")
                break
            }
            response["started"] = queue.generateChaptersForExistingEpisode(episodeHash: episodeHash)
            if response["started"] as? Bool != true {
                response["chapterModelReady"] = ICDownloadableModelStore.selectedChapterModelIsReady()
                response["chapterModelCanGenerate"] = ICDownloadableModelStore.selectedChapterModelCanGenerate()
                response["chapterModelUnavailableReason"] = ICDownloadableModelStore.selectedChapterModelUnavailableReason()
            }
            response["inspection"] = queue.debugInspection(episodeHash: episodeHash)
        case "downloadChapterModel":
            guard let model = requestedChapterModel(parameters: parameters) else {
                response = errorResponse(action: action, message: "Kapitelmodell nicht gefunden")
                break
            }
            response["downloadStarted"] = startModelDownloadIfNeeded(model)
            response["model"] = modelDictionary(model)
        case "cancelChapterModelDownload":
            guard let model = requestedChapterModel(parameters: parameters) else {
                response = errorResponse(action: action, message: "Kapitelmodell nicht gefunden")
                break
            }
            ICDownloadableModelStore.cancelDownload(for: model)
            response["cancelled"] = true
            response["model"] = modelDictionary(model)
        case "retry":
            if let episodeHash {
                queue.retry(episodeHash: episodeHash)
                response["inspection"] = queue.debugInspection(episodeHash: episodeHash)
            } else {
                queue.retryProcessing()
                response["queue"] = queue.debugQueueSnapshot()
            }
        case "cancel":
            queue.cancelAll()
            response["queue"] = queue.debugQueueSnapshot()
        default:
            response = errorResponse(action: action, message: "Unbekannte Aktion")
        }

        let outputURL = writeResponse(response, action: action)
        var metadata: [String: String] = [
            "action": action,
            "ok": String(describing: response["ok"] ?? false),
        ]
        if let episodeHash {
            metadata["episodeHash"] = episodeHash
        }
        if let outputURL {
            metadata["outputPath"] = outputURL.path
        }
        if let commandID {
            metadata["commandID"] = commandID
        }
        metadata["source"] = source
        ICDiagnosticLogger.shared.logEvent("debug-automation",
                                           message: "Transkriptionsbefehl verarbeitet",
                                           metadata: metadata as NSDictionary)
    }

    private static func pathAction(from url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.first
    }

    private static func queryParameters(from url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [:] }
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name] = item.value ?? ""
        }
        return parameters
    }

    private static func episodeList(limit: Int) -> NSArray {
        guard let dmanager = DatabaseManager.shared() else { return [] }
        let cacheManager = CacheManager.shared()
        var result: [NSDictionary] = []
        for feed in dmanager.feeds as? [CDFeed] ?? [] {
            let episodes = (feed.episodes as? Set<CDEpisode> ?? [])
                .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
            for episode in episodes {
                guard let episodeHash = episode.objectHash else { continue }
                result.append([
                    "episodeHash": episodeHash,
                    "episodeTitle": episode.title ?? "",
                    "feedTitle": feed.title ?? "",
                    "cached": cacheManager?.episodeIsCached(episode) ?? false,
                    "hasSRT": TranscriptionEngine.shared.hasSRT(for: episodeHash),
                    "hasGeneratedChapters": ChapterGenerator.shared.hasChapters(for: episodeHash),
                ] as NSDictionary)
                if result.count >= limit {
                    return result as NSArray
                }
            }
        }
        return result as NSArray
    }

    private static func modelList(role: ICDownloadableModelRole) -> NSArray {
        ICDownloadableModelStore.models(for: role).map { modelDictionary($0) } as NSArray
    }

    private static func requestedChapterModel(parameters: [String: String]) -> ICDownloadableModel? {
        if let identifier = parameters["modelID"] ?? parameters["model"] ?? parameters["identifier"] {
            guard let model = ICDownloadableModelStore.model(identifier: identifier), model.role == .textToChapters else {
                return nil
            }
            return model
        }
        return ICDownloadableModelStore.selectedModel(for: .textToChapters)
    }

    private static func modelDictionary(_ model: ICDownloadableModel) -> NSDictionary {
        var result: [String: Any] = [
            "identifier": model.identifier,
            "title": model.title,
            "shortTitle": model.shortTitle,
            "role": model.role.rawValue,
            "roleTitle": model.roleTitle,
            "downloadSizeBytes": model.downloadSizeBytes,
            "downloadSizeText": model.downloadSizeText,
            "requiresDownload": model.requiresDownload,
            "downloaded": ICDownloadableModelStore.isDownloaded(model: model),
            "downloading": ICDownloadableModelStore.isDownloading(model: model),
            "sizeOnDiskBytes": ICDownloadableModelStore.sizeOnDisk(model: model),
        ]
        if let progress = ICDownloadableModelStore.downloadProgress(for: model) {
            result["progress"] = [
                "fraction": progress.fraction,
                "completedBytes": progress.completedBytes,
                "totalBytes": progress.totalBytes,
                "byteText": progress.byteText,
            ] as NSDictionary
        }
        if model.role == .textToChapters {
            result["selected"] = ICDownloadableModelStore.selectedModel(for: .textToChapters).identifier == model.identifier
        } else if model.role == .voiceToText {
            result["selected"] = ICDownloadableModelStore.selectedModel(for: .voiceToText).identifier == model.identifier
        }
        return result as NSDictionary
    }

    private static func startModelDownloadIfNeeded(_ model: ICDownloadableModel) -> Bool {
        guard !ICDownloadableModelStore.isDownloaded(model: model) else {
            ICDownloadableModelStore.select(model: model)
            return false
        }
        guard !ICDownloadableModelStore.isDownloading(model: model) else {
            return false
        }
        ICDownloadableModelStore.download(model: model, detailProgress: { progress in
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Modell-Download Fortschritt",
                                               metadata: [
                                                "model": model.identifier,
                                                "fraction": progress.fraction,
                                                "bytes": progress.byteText,
                                               ] as NSDictionary)
        }, completion: { error in
            var metadata: [String: Any] = ["model": model.identifier]
            if let error {
                metadata["error"] = error.localizedDescription
            }
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: error == nil ? "Modell-Download abgeschlossen" : "Modell-Download fehlgeschlagen",
                                               metadata: metadata as NSDictionary)
        })
        return true
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func errorResponse(action: String, message: String) -> [String: Any] {
        [
            "ok": false,
            "action": action,
            "timestamp": timestampString(Date()),
            "error": message,
        ]
    }

    @discardableResult
    private static func writeResponse(_ response: [String: Any], action: String) -> URL? {
        guard JSONSerialization.isValidJSONObject(response),
              let data = try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        let directory = automationDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeAction = action.replacingOccurrences(of: "/", with: "-")
        let timestamp = filenameTimestamp(Date())
        let url = directory.appendingPathComponent("\(timestamp)_\(safeAction).json")
        let latestURL = directory.appendingPathComponent("latest.json")
        do {
            try data.write(to: url, options: .atomic)
            try data.write(to: latestURL, options: .atomic)
            return url
        } catch {
            ICDiagnosticLogger.shared.logEvent("debug-automation",
                                               message: "Antwort konnte nicht geschrieben werden",
                                               metadata: [
                                                "action": action,
                                                "error": error.localizedDescription,
                                               ] as NSDictionary)
            return nil
        }
    }

    private static func automationDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TranscriptionAutomation", isDirectory: true)
    }

    private static func timestampString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func filenameTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}
