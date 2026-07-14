#!/usr/bin/env python3
"""Pins crash-safe receipt and acknowledgement of Watch manifest files."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
CONNECTIVITY_PATH = ROOT / "InstacastWatch" / "WatchConnectivityController.swift"
DOWNLOAD_PATH = ROOT / "InstacastWatch" / "WatchDownloadManager.swift"
STORE_PATH = ROOT / "InstacastWatch" / "WatchManifestStore.swift"
TRANSFER_PATH = ROOT / "InstacastWatch" / "WatchManifestTransfer.swift"
EPISODE_PATH = ROOT / "InstacastWatch" / "WatchEpisode.swift"
PHONE_PATH = ROOT / "Classes" / "AppleWatchSyncManager.m"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    require(start != -1, f"Missing method/function: {signature}")
    brace = source.find("{", start)
    require(brace != -1, f"Missing body: {signature}")
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


connectivity = CONNECTIVITY_PATH.read_text()
download = DOWNLOAD_PATH.read_text()
store = STORE_PATH.read_text()
transfer = TRANSFER_PATH.read_text()
phone = PHONE_PATH.read_text()

activation = method_body(connectivity, "activationDidCompleteWith")
receive_file = method_body(connectivity, "didReceive file:")
require("resumePendingManifestTransfers" in activation,
        "Watch activation must resume a staged manifest only after ACK delivery is available.")
require("WatchManifestTransferInbox.stage" in receive_file and
        "scheduleManifestInboxProcessing" in receive_file and
        receive_file.find("WatchManifestTransferInbox.stage") < receive_file.find("scheduleManifestInboxProcessing") and
        "decodeStagedManifest" not in receive_file and
        "decode(fileURL: file.fileURL)" not in receive_file,
        "The temporary WCSession file must be durably staged before the delegate callback returns.")
processor = method_body(connectivity, "private func scheduleManifestInboxProcessing()")
require("manifestInboxProcessing" in processor and "manifestInboxProcessingRequested" in processor and
        "guard !manifestInboxProcessing" in processor and "Task.detached" in processor and
        "WatchManifestTransferSnapshot.decode" in processor and
        "removedInvalidFile" in processor and "processNext: removedInvalidFile" in processor,
        "Exactly one serialized consumer may enumerate and decode the durable inbox at a time.")

apply_replace = method_body(connectivity, "private func applyManifestReplace(")
require("try await WatchDownloadManager.shared.replaceManifest" in apply_replace and
        apply_replace.find("try await WatchDownloadManager.shared.replaceManifest") < apply_replace.find("acknowledgeManifest") and
        "isManifestRevisionCommitted" in apply_replace and
        "manifestCommitFailed" in apply_replace,
        "The Watch may ACK only after both manifest data and its revision were durably committed, never merely while that revision is in flight.")

store_apply_start = store.find("func applyManifest(")
store_apply_brace = store.find("{", store_apply_start)
store_apply_signature = store[store_apply_start:store_apply_brace]
store_apply = method_body(store, "func applyManifest(")
store_merge_plan = method_body(store, "private nonisolated static func buildManifestMergePlan(")
require("throws" in store_apply_signature and
        "reserveIncomingManifestRevision" in store_apply and
        "try await persistEpisodes" in store_apply and
        "episodes = previousEpisodes" not in store_apply,
        "A manifest revision must be reserved before suspension and failed writes must not restore a stale per-call snapshot.")
require("struct WatchManifestArchive" in store and "manifestRevision" in store_apply_signature and
        "lastAppliedManifestRevisionKey" not in store and "recordAppliedManifestRevision" not in connectivity,
        "Episodes and their applied revision must be one atomic archive, never two independently persisted values.")
require("return plan.pendingRemovals" in store_apply and
        "pendingRemovals" in store_merge_plan and
        "pendingRemoval.status = .removing" in store_merge_plan and
        "!desiredHashes.contains" in store_merge_plan,
        "Removed episode metadata must remain durably pending until physical file cleanup completes.")
persist = method_body(store, "private func persistEpisodesNow(")
writer = method_body(store, "private actor WatchManifestPersistenceWriter")
require("await persistenceWriter" in persist and "restoreLastCommittedArchive" in persist and
        "try encoder.encode" in writer and "try data.write" in writer and ".atomic" in writer,
        "Manifest persistence must propagate directory, encoding, and atomic-write failures.")

download_replace_start = download.find("func replaceManifest(")
download_replace_brace = download.find("{", download_replace_start)
download_replace_signature = download[download_replace_start:download_replace_brace]
download_replace = method_body(download, "func replaceManifest(")
require("throws" in download_replace_signature and "acknowledgeManifest" not in download_replace,
        "Download reconciliation must propagate commit failure instead of acknowledging it internally.")
require('watch.manifestFailed' in phone,
        "The iPhone needs an explicit actionable failure state when the Watch cannot commit a manifest.")
failure_route = phone.split('if ([type isEqualToString:@"watch.manifestFailed"])', 1)[1].split(
    'if ([type isEqualToString:@"watch.ackManifest"])', 1
)[0]
require("ICAppleWatchPendingManifestRevisionKey" in failure_route and
        "legacyManifestRevisionAwaitingResult" in failure_route and
        failure_route.find("manifestRevision") < failure_route.find("needsManifestSyncAfterActivation = YES"),
        "A delayed failure may affect UI only when it belongs to the currently pending file or legacy manifest.")

require("enum WatchManifestTransferInbox" in transfer and "copyItem" in transfer and
        "moveItem" in transfer and "pendingFileURLs" in transfer,
        "Received files need an atomic, enumerable inbox that survives process termination.")


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
