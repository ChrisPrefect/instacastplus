//
//  ICSilenceTrimHTTPSource.swift
//  InstacastPlus
//
//  Reads a stream for ICSilenceTrimPlayer when the app does not keep streamed episodes ("Beim
//  Streamen laden" off, or caching not allowed for the episode). AVAssetReader refuses http URLs
//  (AVError -11838) but reads through a resource loader; this source answers the loader's
//  requests with HTTP range requests. The bytes go to a temporary file that is deleted when the
//  player closes, so nothing is kept as a download.
//
//  Measured 21.11.2026: AVFoundation regulates what it takes itself. Pushed a whole 140 MB file,
//  it accepted 12 MB, cancelled the request and asked again at the position it needed; memory
//  grew by 28 MB. The source therefore answers in pieces of at most 1 MB and downloads at most
//  16 MB beyond the newest request.
//

import AVFoundation
import Foundation
import UniformTypeIdentifiers

final class ICSilenceTrimHTTPSource: NSObject, ICSilenceTrimStreamSource, URLSessionDataDelegate, @unchecked Sendable {
    let resourceLoaderQueue = DispatchQueue(label: "com.iteconomy.instacast.silencetrim.http")
    private static let chunkLength: Int64 = 512 * 1024
    private static let readAheadLength: Int64 = 16 * 1024 * 1024
    private static let responsePiece: Int64 = 1024 * 1024
    private static let filePrefix = "SilenceTrimStream-"

    private let remoteURL: URL
    private let authorization: String?
    private let fallbackContentType: String
    private let fileURL: URL
    private var session: URLSession?

    // Everything below on `resourceLoaderQueue`.
    private var file: FileHandle?
    private var contentLength: Int64?
    private var contentType: String?
    /// The server answers range requests (206). Without them only one download from the start works.
    private var rangesSupported = true
    private var downloaded: [(start: Int64, end: Int64)] = []
    private var pending: [AVAssetResourceLoadingRequest] = []
    /// Requests of the metadata asset (chapters, artwork). They are answered from the same file
    /// but never decide where the download goes while playback waits, nor move the read-ahead.
    private var metadataRequests = Set<ObjectIdentifier>()
    private var metadataLoader: MetadataLoader?
    private var task: URLSessionDataTask?
    private var taskStart: Int64 = 0
    private var taskOffset: Int64 = 0
    private var taskEnd: Int64 = 0
    private var newestRequestOffset: Int64 = 0
    private var stopped = false
    /// Downloads that broke off in a row (connection lost, timed out); reset by received data.
    private var consecutiveFailures = 0
    private static let maximumRetries = 2

    init(remoteURL: URL, username: String?, password: String?, mimeType: String?) {
        self.remoteURL = remoteURL
        if let username, !username.isEmpty {
            let raw = "\(username):\(password ?? "")"
            authorization = "Basic " + Data(raw.utf8).base64EncodedString()
        } else {
            authorization = nil
        }
        fallbackContentType = Self.contentType(forMIMEType: mimeType)
            ?? UTType(filenameExtension: remoteURL.pathExtension, conformingTo: .audiovisualContent)?.identifier
            ?? UTType.mp3.identifier
        // A crash leaves the file of an earlier stream behind; only one player runs at a time.
        let directory = FileManager.default.temporaryDirectory
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix(Self.filePrefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        fileURL = directory.appendingPathComponent(Self.filePrefix + UUID().uuidString)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        file = try? FileHandle(forUpdating: fileURL)
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = resourceLoaderQueue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    /// Ends all requests and deletes the temporary file. The session keeps its delegate until it
    /// is invalidated here.
    func stop() {
        resourceLoaderQueue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.task?.cancel()
            self.task = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            for request in self.pending where !request.isFinished && !request.isCancelled {
                request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            }
            self.pending.removeAll()
            try? self.file?.close()
            self.file = nil
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    // MARK: Resource loader

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        enqueue(loadingRequest, metadata: false)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        resourceLoaderQueue.async {
            self.pending.removeAll { $0 === loadingRequest }
            self.metadataRequests.remove(ObjectIdentifier(loadingRequest))
        }
    }

    /// An asset for the app's chapter and artwork reading (PlaybackManager's `mediaAsset`). Read
    /// over its own HTTP connection, the file's start was fetched twice (measured 21.11.2026:
    /// 655 KB per opened stream through AVFoundation next to this source).
    func makeMetadataAsset() -> AVURLAsset {
        let loader = metadataLoader ?? MetadataLoader(source: self)
        metadataLoader = loader
        let asset = AVURLAsset(url: URL(string: "instacast-silencetrim-metadata://\(UUID().uuidString)")!)
        asset.resourceLoader.setDelegate(loader, queue: resourceLoaderQueue)
        return asset
    }

    fileprivate func enqueue(_ loadingRequest: AVAssetResourceLoadingRequest, metadata: Bool) {
        resourceLoaderQueue.async {
            guard !self.stopped else {
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                return
            }
            self.pending.append(loadingRequest)
            if metadata {
                self.metadataRequests.insert(ObjectIdentifier(loadingRequest))
            } else if let dataRequest = loadingRequest.dataRequest {
                self.newestRequestOffset = dataRequest.requestedOffset
            }
            self.answerPendingRequests()
            self.scheduleDownload()
        }
    }

    func abandonLoadingRequests(_ requests: [AVAssetResourceLoadingRequest]) {
        resourceLoaderQueue.async {
            for request in requests where self.pending.contains(where: { $0 === request }) {
                self.pending.removeAll { $0 === request }
                if !request.isFinished && !request.isCancelled {
                    request.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                }
            }
            self.scheduleDownload()
        }
    }

    // MARK: Answering

    private func answerPendingRequests() {
        for request in pending {
            if request.isCancelled || request.isFinished {
                pending.removeAll { $0 === request }
                continue
            }
            if let information = request.contentInformationRequest {
                guard let length = contentLength else { continue }
                information.contentType = contentType ?? fallbackContentType
                information.contentLength = length
                // Ranges come from the temporary file, also when the server sends whole files.
                information.isByteRangeAccessSupported = true
            }
            guard let dataRequest = request.dataRequest else {
                finish(request)
                continue
            }
            var end = dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
            if dataRequest.requestsAllDataToEndOfResource {
                guard let length = contentLength else { continue }
                end = length
            } else if let length = contentLength {
                end = min(end, length)
            }
            var current = dataRequest.currentOffset
            let available = min(end, contiguousEnd(from: current))
            while current < available && !request.isCancelled {
                guard let data = read(at: current, length: min(Self.responsePiece, available - current)), !data.isEmpty else { break }
                dataRequest.respond(with: data)
                current += Int64(data.count)
            }
            if current >= end && !request.isCancelled {
                finish(request)
            }
        }
    }

    private func finish(_ request: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === request }
        metadataRequests.remove(ObjectIdentifier(request))
        if !request.isFinished && !request.isCancelled {
            request.finishLoading()
        }
    }

    private func failPendingRequests(_ error: Error) {
        let failed = pending
        pending.removeAll()
        metadataRequests.removeAll()
        for request in failed where !request.isFinished && !request.isCancelled {
            request.finishLoading(with: error)
        }
    }

    // MARK: Downloading

    /// Downloads what the newest playback request waits for first, then what a metadata request
    /// waits for; otherwise reads ahead of playback.
    private func scheduleDownload() {
        guard !stopped, session != nil else { return }
        if let length = contentLength, contiguousEnd(from: 0) >= length { return }
        func missingOffset(metadata: Bool) -> Int64? {
            guard let request = pending.last(where: {
                $0.dataRequest != nil && !$0.isCancelled && metadataRequests.contains(ObjectIdentifier($0)) == metadata
            }), let dataRequest = request.dataRequest else { return nil }
            let offset = dataRequest.currentOffset
            guard contentLength.map({ offset < $0 }) ?? true, contiguousEnd(from: offset) == offset else { return nil }
            return offset
        }
        let wanted = missingOffset(metadata: false) ?? missingOffset(metadata: true)
        // Without ranges only a whole download from the start works; it reaches every offset.
        if !rangesSupported {
            if task == nil { startDownload(at: 0) }
            return
        }
        if let wanted {
            // The running download delivers in order; it reaches `wanted` itself.
            if task != nil && taskOffset <= wanted && wanted < taskEnd { return }
            startDownload(at: wanted)
            return
        }
        guard task == nil else { return }
        let next = contiguousEnd(from: newestRequestOffset)
        if let length = contentLength, next >= length { return }
        guard next < newestRequestOffset + Self.readAheadLength else { return }
        startDownload(at: next)
    }

    private func startDownload(at offset: Int64) {
        task?.cancel()
        var end = offset + Self.chunkLength
        if let length = contentLength { end = min(end, length) }
        if let following = downloaded.first(where: { $0.start > offset }) { end = min(end, following.start) }
        var request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.networkServiceType = .avStreaming
        request.setValue("bytes=\(offset)-\(end - 1)", forHTTPHeaderField: "Range")
        request.setValue("", forHTTPHeaderField: "Accept-Encoding")
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        guard let session else { return }
        let newTask = session.dataTask(with: request)
        task = newTask
        taskStart = offset
        taskOffset = offset
        taskEnd = end
        newTask.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard dataTask === task, let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        switch http.statusCode {
        case 206:
            let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.start == taskStart else {
                completionHandler(.cancel)
                task = nil
                failPendingRequests(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                            userInfo: [NSLocalizedDescriptionKey: "unexpected Content-Range"]))
                return
            }
            if let total = range.total { contentLength = total }
            taskEnd = min(taskEnd, range.end + 1)
        case 200 where taskStart == 0:
            // No ranges: the whole file comes once, in order.
            rangesSupported = false
            if http.expectedContentLength > 0 { contentLength = http.expectedContentLength }
            taskEnd = contentLength ?? Int64.max
        default:
            completionHandler(.cancel)
            task = nil
            failPendingRequests(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for a range request"]))
            return
        }
        if contentType == nil {
            contentType = Self.contentType(forMIMEType: http.mimeType)
        }
        completionHandler(.allow)
        answerPendingRequests()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task, let file, !data.isEmpty else { return }
        let usable = Int(min(Int64(data.count), max(0, taskEnd - taskOffset)))
        guard usable > 0 else { return }
        do {
            try file.seek(toOffset: UInt64(taskOffset))
            try file.write(contentsOf: data.prefix(usable))
        } catch {
            dataTask.cancel()
            task = nil
            failPendingRequests(error)
            return
        }
        addDownloaded(start: taskOffset, end: taskOffset + Int64(usable))
        taskOffset += Int64(usable)
        consecutiveFailures = 0
        answerPendingRequests()
    }

    func urlSession(_ session: URLSession, task finishedTask: URLSessionTask, didCompleteWithError error: Error?) {
        guard finishedTask === task else { return }
        task = nil
        if let error, (error as NSError).code != NSURLErrorCancelled {
            // A broken connection is asked again at once (the waiting requests stay); after that
            // the requests fail and the player hands the stream to AVPlayer.
            let code = (error as NSError).code
            let transient = (error as NSError).domain == NSURLErrorDomain &&
                [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotConnectToHost].contains(code)
            if transient && consecutiveFailures < Self.maximumRetries {
                consecutiveFailures += 1
                scheduleDownload()
                return
            }
            consecutiveFailures = 0
            failPendingRequests(error)
            return
        }
        answerPendingRequests()
        scheduleDownload()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    // MARK: File

    private func read(at offset: Int64, length: Int64) -> Data? {
        guard let file else { return nil }
        do {
            try file.seek(toOffset: UInt64(offset))
            return try file.read(upToCount: Int(length))
        } catch {
            return nil
        }
    }

    private func contiguousEnd(from offset: Int64) -> Int64 {
        for range in downloaded where range.start <= offset && offset < range.end {
            return range.end
        }
        return offset
    }

    private func addDownloaded(start: Int64, end: Int64) {
        var merged = (start: start, end: end)
        var result: [(start: Int64, end: Int64)] = []
        for range in downloaded {
            if range.end < merged.start || range.start > merged.end {
                result.append(range)
            } else {
                merged = (min(merged.start, range.start), max(merged.end, range.end))
            }
        }
        result.append(merged)
        downloaded = result.sorted { $0.start < $1.start }
    }

    // MARK: Helpers

    /// Resource loader delegate of the metadata asset (AVAssetResourceLoader keeps its delegate weakly).
    private final class MetadataLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
        private weak var source: ICSilenceTrimHTTPSource?
        init(source: ICSilenceTrimHTTPSource) { self.source = source }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                            shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
            guard let source else { return false }
            source.enqueue(loadingRequest, metadata: true)
            return true
        }

        func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
            source?.resourceLoader(resourceLoader, didCancel: loadingRequest)
        }
    }

    private static func contentType(forMIMEType mimeType: String?) -> String? {
        guard let mimeType, !mimeType.isEmpty else { return nil }
        let type = UTType(mimeType: mimeType)
        guard let type, type.conforms(to: .audiovisualContent) else { return nil }
        return type.identifier
    }

    /// "bytes 0-511/1234" (total "*" when unknown).
    private static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value, value.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/")
        guard parts.count == 2 else { return nil }
        let bounds = parts[0].split(separator: "-")
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]) else { return nil }
        return (start, end, Int64(parts[1]))
    }
}
