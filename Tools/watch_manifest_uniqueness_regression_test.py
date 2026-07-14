#!/usr/bin/env python3
"""Executes the real watch manifest store against duplicate persisted and incoming rows."""

from pathlib import Path
import os
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WATCH_EPISODE = ROOT / "InstacastWatch" / "WatchEpisode.swift"
WATCH_COLLECTION = ROOT / "InstacastWatch" / "WatchEpisodeCollectionState.swift"
WATCH_MANIFEST = ROOT / "InstacastWatch" / "WatchManifestStore.swift"


STUBS = r"""
import Foundation

protocol ObservableObject: AnyObject {}

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

@MainActor
final class WatchStorageManager {
    static let shared = WatchStorageManager()
    private init() {}

    func resolvedLocalFileURL(for episode: WatchEpisode) -> URL? {
        guard let url = episode.localFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

@MainActor
enum WatchDiagnostics {
    static func log(_ event: String, message: String, metadata: [String: String] = [:]) {}
    static func metadata(for episode: WatchEpisode, prefix: String = "") -> [String: String] { [:] }
    static func stableHash(_ value: String) -> String { value }
}
"""


HARNESS = r"""
import Foundation

@main
struct ManifestUniquenessHarness {
    @MainActor
    static func entry(hash: String = "duplicate", title: String = "Episode") -> WatchManifestEntry {
        WatchManifestEntry(
            episodeHash: hash,
            selectionIdentifier: "selection-\(title)",
            feedIdentifier: "feed",
            title: title,
            podcastTitle: "Podcast",
            imageURL: nil,
            pubDate: Date(timeIntervalSince1970: 100),
            durationHint: 60,
            position: 0,
            consumed: false,
            mediaURL: URL(string: "https://example.com/episode.mp3")!,
            selectionSource: .manual,
            watchAddedDate: Date(timeIntervalSince1970: 100),
            playbackOrder: nil,
            skipForwardSeconds: 30,
            skipBackwardSeconds: 15,
            expectedFileSize: 4,
            skipChapterNames: [],
            autoSkipSponsors: false
        )
    }

    @MainActor
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    @MainActor
    static func main() async throws {
        let scenario = CommandLine.arguments.dropFirst().first ?? "apply"
        let store = WatchManifestStore.shared

        switch scenario {
        case "apply":
            _ = try await store.applyManifest(entries: [entry(title: "first"), entry(title: "second")])
            require(store.episodes.count == 1, "duplicate incoming manifest rows were persisted")
        case "replace":
            _ = try await store.applyManifest(entries: [entry(title: "first"), entry(title: "second")])
            _ = try await store.applyManifest(entries: [entry(title: "third")])
            require(store.episodes.count == 1, "a second replace did not preserve unique identity")
        case "upsert":
            _ = try await store.applyManifest(entries: [entry(title: "first"), entry(title: "second")])
            try await store.upsert(entries: [entry(title: "third")])
            require(store.episodes.count == 1, "upsert did not repair duplicate stored rows")
        case "revision":
            _ = try await store.applyManifest(entries: [entry()], manifestRevision: 42)
            require(!store.shouldApplyManifestRevision(42), "committed revision was not restored from the manifest archive")
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("WatchManifest", isDirectory: true)
            let data = try Data(contentsOf: support.appendingPathComponent("manifest.json"))
            let archive = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            require((archive?["manifestRevision"] as? NSNumber)?.int64Value == 42,
                    "manifest revision was persisted outside the atomic episode archive")
        case "pending-removal":
            _ = try await store.applyManifest(entries: [entry()], manifestRevision: 41)
            _ = try await store.applyManifest(entries: [], manifestRevision: 42)
            require(store.episodes.count == 1 && store.episodes[0].status == .removing,
                    "removed episode metadata was lost before physical cleanup")
        case "removal-restart":
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("WatchManifest", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let localFile = support.appendingPathComponent("removed.mp3")
            try Data([1, 2, 3, 4]).write(to: localFile)
            _ = try await store.applyManifest(entries: [entry()], manifestRevision: 41)
            store.updateEpisode(hash: "duplicate") { episode in
                episode.status = .downloaded
                episode.localFileURL = localFile
                episode.actualFileSize = 4
            }
            _ = try await store.applyManifest(entries: [], manifestRevision: 42)
            try FileManager.default.removeItem(at: localFile)
            await store.load()
            require(store.episodes.count == 1 && store.episodes[0].status == .removing,
                    "restart resurrected a physically removed pending episode")
        case "load":
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("WatchManifest", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let localFile = support.appendingPathComponent("download.mp3")
            try Data([1, 2, 3, 4]).write(to: localFile)

            var queued = WatchEpisode(
                entry: entry(title: "queued"),
                existing: nil,
                existingLocalFileWasValidated: false
            )
            queued.status = .queued
            var downloaded = WatchEpisode(
                entry: entry(title: "downloaded"),
                existing: nil,
                existingLocalFileWasValidated: false
            )
            downloaded.status = .downloaded
            downloaded.localFileURL = localFile
            downloaded.actualFileSize = 4

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode([downloaded, queued]).write(
                to: support.appendingPathComponent("manifest.json"),
                options: [.atomic]
            )
            await store.load()
            require(store.episodes.count == 1, "load retained duplicate persisted rows")
            require(store.episodes[0].status == .downloaded, "load discarded the valid downloaded duplicate")
            require(store.episodes[0].localFileURL == localFile, "load discarded the valid local file")
        default:
            fatalError("unknown scenario")
        }
    }
}
"""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


with tempfile.TemporaryDirectory(prefix="watch-manifest-uniqueness-") as temp_dir:
    temp = Path(temp_dir)
    stubs = temp / "Stubs.swift"
    harness = temp / "Harness.swift"
    executable = temp / "manifest-uniqueness"
    stubs.write_text(STUBS)
    harness.write_text(HARNESS)

    compile_result = subprocess.run(
        [
            "swiftc",
            "-parse-as-library",
            str(stubs),
            str(WATCH_EPISODE),
            str(WATCH_COLLECTION),
            str(WATCH_MANIFEST),
            str(harness),
            "-o",
            str(executable),
        ],
        text=True,
        capture_output=True,
    )
    require(
        compile_result.returncode == 0,
        f"Watch manifest regression harness did not compile:\n{compile_result.stdout}{compile_result.stderr}",
    )

    for scenario in ("apply", "replace", "upsert", "revision", "pending-removal", "removal-restart", "load"):
        home = temp / f"home-{scenario}"
        home.mkdir()
        environment = os.environ.copy()
        environment["CFFIXED_USER_HOME"] = str(home)
        environment["HOME"] = str(home)
        result = subprocess.run(
            [str(executable), scenario],
            text=True,
            capture_output=True,
            env=environment,
        )
        require(
            result.returncode == 0,
            f"Watch manifest duplicate scenario '{scenario}' failed:\n{result.stdout}{result.stderr}",
        )

source = WATCH_MANIFEST.read_text()
require(
    "Dictionary(uniqueKeysWithValues: episodes" not in source,
    "Watch manifest code must not trap when old storage contains duplicate episode hashes.",
)

print("Watch manifest uniqueness regression checks passed")
