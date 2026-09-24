#!/usr/bin/env python3
"""Exercise durable Watch manifest inbox staging, decoding, and removal."""

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
struct ManifestInboxHarness {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("incoming.jsonl")
        let header: [String: Any] = [
            "type": "manifest.replace",
            "manifestRevision": NSNumber(value: 42),
            "entryCount": 0,
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        try (headerData + Data([0x0A])).write(to: source)

        let staged = try WatchManifestTransferInbox.stage(
            fileURL: source,
            revision: 42,
            directoryURL: inbox
        )
        try FileManager.default.removeItem(at: source)
        let pendingAfterRestart = try WatchManifestTransferInbox.pendingFileURLs(directoryURL: inbox)
        require(pendingAfterRestart.count == 1 &&
                pendingAfterRestart[0].lastPathComponent == staged.lastPathComponent &&
                FileManager.default.fileExists(atPath: staged.path),
                "staged manifest was not recoverable after callback return")
        let snapshot = try WatchManifestTransferSnapshot.decode(fileURL: staged)
        require(snapshot.manifestRevision == 42, "staged manifest changed")
        try WatchManifestTransferInbox.remove(fileURL: staged)
        let pendingAfterCommit = try WatchManifestTransferInbox.pendingFileURLs(directoryURL: inbox)
        require(pendingAfterCommit.isEmpty,
                "committed inbox file was not removed")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="watch-manifest-inbox-") as temp_dir:
    temp = Path(temp_dir)
    harness = temp / "Harness.swift"
    executable = temp / "watch-manifest-inbox"
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
            f"Watch manifest inbox harness did not compile:\n{compiled.stdout}{compiled.stderr}")
    result = subprocess.run([str(executable)], text=True, capture_output=True)
    require(result.returncode == 0,
            f"Watch manifest inbox harness failed:\n{result.stdout}{result.stderr}")

print("Watch manifest durability regression checks passed")
