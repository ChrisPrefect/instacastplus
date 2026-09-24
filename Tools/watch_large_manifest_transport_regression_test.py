#!/usr/bin/env python3
"""Exercise large and malformed manifests through the production Watch file decoder."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
TRANSFER_PATH = ROOT / "InstacastWatch" / "WatchManifestTransfer.swift"
EPISODE_PATH = ROOT / "InstacastWatch" / "WatchEpisode.swift"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


HARNESS = r'''
import Foundation

@main
struct LargeManifestHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func dictionary(index: Int) -> [String: Any] {
        [
            "episodeHash": "episode-\(index)",
            "feedIdentifier": "feed-\(index % 100)",
            "title": "Episode \(index)",
            "podcastTitle": "Podcast \(index % 100)",
            "subtitle": "Subtitle",
            "imageURL": "https://example.com/image.jpg",
            "pubDate": "2026-07-12T12:00:00Z",
            "durationHint": 3600,
            "position": 30,
            "consumed": false,
            "mediaURL": "https://example.com/episode-\(index).mp3",
            "expectedFileSize": 1_000_000,
            "selectionSource": "manual",
            "watchAddedDate": "2026-07-12T12:00:00Z",
            "playbackOrder": index,
            "skipForwardSeconds": 30,
            "skipBackwardSeconds": 15,
            "skipChapterNames": [],
            "autoSkipSponsors": false,
        ]
    }

    static func writeManifest(
        to url: URL,
        revision: Int64,
        entries: [[String: Any]],
        accentColorHex: String? = nil,
        declaredEntryCount: Int? = nil
    ) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var header: [String: Any] = [
            "type": "manifest.replace",
            "manifestRevision": NSNumber(value: revision),
            "entryCount": declaredEntryCount ?? entries.count,
        ]
        header["accentColorHex"] = accentColorHex
        for object in [header] + entries {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        }
    }

    static func main() throws {
        let dictionaries = (0..<4_500).map(dictionary(index:))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent("manifest.jsonl")
        try writeManifest(to: manifestURL, revision: 9_001, entries: dictionaries, accentColorHex: "#123456")
        let snapshot = try WatchManifestTransferSnapshot.decode(fileURL: manifestURL)
        require(snapshot.manifestRevision == 9_001, "revision was not preserved")
        require(snapshot.accentColorHex == "#123456", "accent was not preserved")
        require(snapshot.entries.count == 4_500, "large manifest was truncated")
        require(snapshot.entries.first?.episodeHash == "episode-0", "first entry order changed")
        require(snapshot.entries.last?.episodeHash == "episode-4499", "last entry order changed")

        let emptyURL = directory.appendingPathComponent("empty.jsonl")
        try writeManifest(to: emptyURL, revision: 9_002, entries: [])
        let emptySnapshot = try WatchManifestTransferSnapshot.decode(fileURL: emptyURL)
        require(emptySnapshot.entries.isEmpty,
                "an empty replacement must remain a valid atomic manifest")

        var invalidEntries = dictionaries
        invalidEntries[2].removeValue(forKey: "mediaURL")
        let invalidURL = directory.appendingPathComponent("invalid.jsonl")
        try writeManifest(to: invalidURL, revision: 9_003, entries: invalidEntries)
        do {
            _ = try WatchManifestTransferSnapshot.decode(fileURL: invalidURL)
            fatalError("invalid entry produced a destructive partial manifest")
        } catch {
            // Expected: the active manifest remains untouched.
        }

        let oversizedCountURL = directory.appendingPathComponent("oversized-count.jsonl")
        try writeManifest(to: oversizedCountURL, revision: 9_004, entries: [], declaredEntryCount: 10_001)
        do {
            _ = try WatchManifestTransferSnapshot.decode(fileURL: oversizedCountURL)
            fatalError("unbounded entry count was accepted")
        } catch WatchManifestTransferError.invalidEntries {
            // Expected before reserveCapacity.
        }

        var oversizedLineEntry = dictionary(index: 0)
        oversizedLineEntry["title"] = String(repeating: "x", count: 300_000)
        let oversizedLineURL = directory.appendingPathComponent("oversized-line.jsonl")
        try writeManifest(to: oversizedLineURL, revision: 9_005, entries: [oversizedLineEntry])
        do {
            _ = try WatchManifestTransferSnapshot.decode(fileURL: oversizedLineURL)
            fatalError("unbounded JSON line was accepted")
        } catch WatchManifestTransferError.invalidJSONLine {
            // Expected before constructing the oversized dictionary graph.
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix="watch-large-manifest-") as temp_dir:
    temp = Path(temp_dir)
    harness = temp / "Harness.swift"
    executable = temp / "watch-large-manifest"
    harness.write_text(HARNESS)
    compiled = subprocess.run(
        [
            "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
            str(EPISODE_PATH), str(TRANSFER_PATH), str(harness), "-o", str(executable),
        ],
        text=True,
        capture_output=True,
    )
    require(compiled.returncode == 0,
            f"Watch manifest file harness did not compile:\n{compiled.stdout}{compiled.stderr}")
    result = subprocess.run([str(executable)], text=True, capture_output=True)
    require(result.returncode == 0,
            f"Watch manifest file harness failed:\n{result.stdout}{result.stderr}")

print("Watch large-manifest transport regression checks passed")
