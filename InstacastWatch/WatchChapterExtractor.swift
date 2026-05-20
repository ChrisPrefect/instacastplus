import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct WatchChapterExtractionResult {
    let chapters: [WatchChapter]
    let artworkBaseURL: URL?
}

final class WatchChapterExtractor: Sendable {
    static let shared = WatchChapterExtractor()

    private init() {}

    func extractChapters(from fileURL: URL, episodeHash: String, artworkDirectory: URL) async -> WatchChapterExtractionResult {
        let asset = AVURLAsset(url: fileURL)
        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []

        var extracted: [ExtractedChapter] = []
        if formats.contains(.id3Metadata) {
            extracted = await id3Chapters(from: asset)
        }
        if extracted.isEmpty, formats.contains(.iTunesMetadata) || formats.contains(.quickTimeMetadata) {
            extracted = await m4aChapters(from: asset)
        }

        guard !extracted.isEmpty else {
            return WatchChapterExtractionResult(chapters: [], artworkBaseURL: nil)
        }

        let safeEpisodeHash = safeFileComponent(episodeHash)
        removeExistingArtwork(for: safeEpisodeHash, in: artworkDirectory)

        let chapters = persistArtworkAndBuildChapters(
            extracted.sorted { $0.startSeconds < $1.startSeconds },
            episodeHash: safeEpisodeHash,
            artworkDirectory: artworkDirectory
        )
        let hasArtwork = chapters.contains { $0.imageFileName != nil }
        return WatchChapterExtractionResult(chapters: chapters, artworkBaseURL: hasArtwork ? artworkDirectory : nil)
    }

    private func id3Chapters(from asset: AVURLAsset) async -> [ExtractedChapter] {
        guard let metadata = try? await asset.loadMetadata(for: .id3Metadata) else { return [] }
        let chapterItems = AVMetadataItem.metadataItems(from: metadata, withKey: "CHAP", keySpace: .id3)

        var chapters: [ExtractedChapter] = []
        for item in chapterItems {
            guard let data = try? await item.load(.dataValue),
                  let chapter = Self.parseID3Chapter(data)
            else {
                continue
            }
            chapters.append(chapter)
        }
        return chapters
    }

    private func m4aChapters(from asset: AVURLAsset) async -> [ExtractedChapter] {
        guard
            let locales = try? await asset.load(.availableChapterLocales),
            let locale = preferredLocale(from: locales),
            let groups = try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: [AVMetadataKey.commonKeyTitle, AVMetadataKey.commonKeyArtwork]
            )
        else {
            return []
        }

        var chapters: [ExtractedChapter] = []
        for group in groups {
            let startSeconds = roundedSeconds(group.timeRange.start)
            guard startSeconds >= 0 else { continue }

            var title: String?
            var imageData: Data?
            for item in group.items {
                if item.commonKey == .commonKeyTitle {
                    title = (try? await item.load(.stringValue)) ?? title
                } else if item.commonKey == .commonKeyArtwork {
                    imageData = (try? await item.load(.dataValue)) ?? imageData
                }
            }

            chapters.append(ExtractedChapter(
                title: cleanTitle(title, startSeconds: startSeconds),
                startSeconds: startSeconds,
                endSeconds: roundedSeconds(CMTimeRangeGetEnd(group.timeRange)),
                imageData: imageData
            ))
        }
        return chapters
    }

    private func preferredLocale(from locales: [Locale]) -> Locale? {
        guard !locales.isEmpty else { return nil }
        let preferredLanguage = Locale.current.language.languageCode?.identifier
        return locales.first { locale in
            locale.language.languageCode?.identifier == preferredLanguage
        } ?? locales.first
    }

    private func persistArtworkAndBuildChapters(_ extracted: [ExtractedChapter],
                                                episodeHash: String,
                                                artworkDirectory: URL) -> [WatchChapter] {
        try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)

        return extracted.enumerated().map { index, chapter in
            let imageFileName: String?
            if let imageData = chapter.imageData, let normalizedData = normalizedArtworkData(from: imageData) {
                let fileName = "\(episodeHash)-chapter-\(index).jpg"
                let url = artworkDirectory.appendingPathComponent(fileName)
                try? normalizedData.write(to: url, options: [.atomic])
                imageFileName = fileName
            } else {
                imageFileName = nil
            }

            let nextStart = extracted.indices.contains(index + 1) ? extracted[index + 1].startSeconds : nil
            let resolvedEnd = chapter.endSeconds.flatMap { $0 > chapter.startSeconds ? $0 : nil } ?? nextStart
            return WatchChapter(
                title: chapter.title,
                startSeconds: chapter.startSeconds,
                endSeconds: resolvedEnd,
                imageFileName: imageFileName
            )
        }
    }

    private func normalizedArtworkData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.82]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func removeExistingArtwork(for episodeHash: String, in directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix("\(episodeHash)-chapter-") {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func safeFileComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }

    private static func parseID3Chapter(_ data: Data) -> ExtractedChapter? {
        var reader = ID3Reader(data: data)
        guard reader.readNullTerminatedLatin1String() != nil,
              let startMilliseconds = reader.readUInt32(),
              let endMilliseconds = reader.readUInt32()
        else {
            return nil
        }
        guard reader.skip(8) else { return nil }

        let startSeconds = Int((Double(startMilliseconds) / 1000.0).rounded())
        guard startSeconds >= 0 else { return nil }

        var title: String?
        var imageData: Data?
        while reader.remaining >= 10 {
            guard
                let frameID = reader.readLatin1String(length: 4),
                let size = reader.readUInt32(),
                reader.skip(2),
                size > 0,
                Int(size) <= reader.remaining,
                let payload = reader.readData(length: Int(size))
            else {
                break
            }

            switch frameID {
            case "TIT2":
                title = parseID3TextFrame(payload) ?? title
            case "TIT3":
                if title == nil {
                    title = parseID3TextFrame(payload)
                }
            case "APIC":
                imageData = parseID3APICFrame(payload) ?? imageData
            default:
                continue
            }
        }

        let endSeconds = endMilliseconds > startMilliseconds ? Int((Double(endMilliseconds) / 1000.0).rounded()) : nil
        return ExtractedChapter(
            title: cleanTitle(title, startSeconds: startSeconds),
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            imageData: imageData
        )
    }

    private static func parseID3TextFrame(_ data: Data) -> String? {
        guard let encodingByte = data.first else { return nil }
        let textData = data.dropFirst()
        let encoding = stringEncoding(for: encodingByte)
        guard let text = String(data: Data(textData), encoding: encoding) else { return nil }
        let cleaned = text
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func parseID3APICFrame(_ data: Data) -> Data? {
        guard data.count > 4, let encodingByte = data.first else { return nil }
        let bytes = [UInt8](data)
        var offset = 1

        guard let mimeEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = mimeEnd + 1
        guard offset < bytes.count else { return nil }

        offset += 1
        guard offset < bytes.count else { return nil }

        let terminatorLength = (encodingByte == 1 || encodingByte == 2) ? 2 : 1
        guard let descriptionEnd = firstTerminator(in: bytes, from: offset, length: terminatorLength) else {
            return nil
        }
        offset = descriptionEnd + terminatorLength
        guard offset < bytes.count else { return nil }

        return Data(bytes[offset...])
    }

    private static func firstTerminator(in bytes: [UInt8], from start: Int, length: Int) -> Int? {
        guard start < bytes.count else { return nil }
        if length == 1 {
            return bytes[start...].firstIndex(of: 0)
        }
        guard start + 1 < bytes.count else { return nil }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                return index
            }
            index += 2
        }
        return nil
    }

    private static func stringEncoding(for value: UInt8) -> String.Encoding {
        switch value {
        case 1:
            return .utf16
        case 2:
            return .utf16BigEndian
        case 3:
            return .utf8
        default:
            return .isoLatin1
        }
    }
}

private struct ExtractedChapter {
    let title: String
    let startSeconds: Int
    let endSeconds: Int?
    let imageData: Data?
}

private struct ID3Reader {
    let data: Data
    var offset = 0

    var remaining: Int {
        max(0, data.count - offset)
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, remaining >= count else { return false }
        offset += count
        return true
    }

    mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(length: 4) else { return nil }
        return bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func readLatin1String(length: Int) -> String? {
        guard let bytes = readBytes(length: length) else { return nil }
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    mutating func readNullTerminatedLatin1String() -> String? {
        guard remaining > 0 else { return nil }
        let start = offset
        while offset < data.count {
            if data[offset] == 0 {
                let bytes = data[start..<offset]
                offset += 1
                return String(data: Data(bytes), encoding: .isoLatin1)
            }
            offset += 1
        }
        return nil
    }

    mutating func readData(length: Int) -> Data? {
        guard let bytes = readBytes(length: length) else { return nil }
        return Data(bytes)
    }

    private mutating func readBytes(length: Int) -> [UInt8]? {
        guard length >= 0, remaining >= length else { return nil }
        let range = offset..<(offset + length)
        offset += length
        return Array(data[range])
    }
}

private func roundedSeconds(_ time: CMTime) -> Int {
    let seconds = CMTimeGetSeconds(time)
    guard seconds.isFinite else { return -1 }
    return max(0, Int(seconds.rounded()))
}

private func cleanTitle(_ title: String?, startSeconds: Int) -> String {
    let cleaned = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleaned.isEmpty {
        return cleaned
    }
    return formatChapterStart(startSeconds)
}

private func formatChapterStart(_ seconds: Int) -> String {
    let totalSeconds = max(0, seconds)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    if hours > 0 {
        return String(format: "%d:%02d", hours, minutes)
    }
    return "\(minutes)m"
}
