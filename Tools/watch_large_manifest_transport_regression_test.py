#!/usr/bin/env python3
"""Pins atomic file transport and revision-bound ACKs for large Watch manifests."""

from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
PHONE_PATH = ROOT / "Classes" / "AppleWatchSyncManager.m"
CONNECTIVITY_PATH = ROOT / "InstacastWatch" / "WatchConnectivityController.swift"
DOWNLOAD_PATH = ROOT / "InstacastWatch" / "WatchDownloadManager.swift"
EPISODE_PATH = ROOT / "InstacastWatch" / "WatchEpisode.swift"
TRANSFER_PATH = ROOT / "InstacastWatch" / "WatchManifestTransfer.swift"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def method_body(source: str, signature: str) -> str:
    search_start = 0
    while True:
        start = source.find(signature, search_start)
        require(start != -1, f"Missing method/function: {signature}")
        brace = source.find("{", start)
        require(brace != -1, f"Missing body: {signature}")
        semicolon = source.find(";", start, brace)
        if semicolon == -1:
            break
        search_start = semicolon + 1
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated body: {signature}")


require(TRANSFER_PATH.exists(), "Large Watch manifests need a Foundation-only file decoder.")
phone = PHONE_PATH.read_text()
connectivity = CONNECTIVITY_PATH.read_text()
download = DOWNLOAD_PATH.read_text()
episode = EPISODE_PATH.read_text()
transfer = TRANSFER_PATH.read_text()

prepare = method_body(phone, "- (NSURL*)_prepareManifestFileForPayload:")
require("NSOutputStream" in prepare and "ICWriteJSONObjectLine" in prepare and
        "NSJSONSerialization dataWithJSONObject:object" in phone and
        'stringByAppendingString:@".tmp"' in prepare and "moveItemAtURL" in prepare,
        "The manifest must be streamed entry-by-entry to an atomic temporary file off-main.")
require("NSPropertyListSerialization" not in prepare and "dataWithJSONObject:payload" not in prepare,
        "File preparation must not allocate a second complete serialized manifest.")
require("ICAppleWatchMaximumManifestEntryCount" in prepare and
        "ICAppleWatchMaximumManifestFileSize" in prepare and
        "attributesOfItemAtPath" in prepare and
        "Reduce the Apple Watch selection" in prepare,
        "The phone must reject an unsupported manifest before transfer with actionable size guidance.")

send = method_body(phone, "- (BOOL)_sendManifestPayload:")
require("watchManifestProtocolVersion >= 2" in send and
        "ICAppleWatchManifestFileAvailable" in send and "updateApplicationContext:descriptor" in send,
        "Protocol-v2 applicationContext must contain only the small durable file descriptor.")
require("transferFile:fileURL metadata:descriptor" in send and "updateApplicationContext:payload" in send,
        "v2 must use file transfer while an older Watch retains the original inline protocol.")
require("outError" in send and "NSUnderlyingErrorKey" in send,
        "A descriptor failure must preserve the real transport error for actionable UI guidance.")
require("Update the Apple Watch app" in send,
        "An old Watch that cannot accept a large inline manifest needs explicit update guidance.")

current_state = method_body(phone, "- (void)_sendCurrentStateMessage:")
require("ICAppleWatchManifestFileAvailable" in current_state and "phonePlaybackState" in current_state,
        "Playback updates must preserve and augment the durable manifest-file descriptor.")

finish_file = method_body(phone, "didFinishFileTransfer:")
require("removeItemAtURL" in finish_file and "needsManifestSyncAfterActivation" in finish_file,
        "Outgoing files must be retained through transfer and cleaned up on completion or failure.")

prepared_send = method_body(phone, "- (void)_sendPreparedManifestPayload:")
require(prepared_send.find("_sendManifestPayload:") < prepared_send.find("_applyManifestSentStateForEpisodeHashes:"),
        "Phone delivery state must only advance after WatchConnectivity accepted the transfer.")
require("_manifestDeliveryFailedWithError:" in prepared_send,
        "A manual Watch sync must surface a real file-transfer failure instead of silently doing nothing.")
require("_applyManifestRevisionForSnapshot:" not in phone,
        "An unacknowledged or rejected file must never leave causal floors for a manifest the Watch did not apply.")

ack_route = phone.split('@"watch.ackManifest"', 1)[1].split("else if", 1)[0]
require("manifestRevision" in ack_route and "_applyManifestAcknowledgementForRevision:" in ack_route,
        "A large ACK must be compact and gated by the exact pending manifest revision.")
ack_revision = method_body(phone, "- (void)_applyManifestAcknowledgementForRevision:")
require("_episodeHashesFromManifestFileForRevision:" in ack_revision and
        "manifestBuildQueue" in ack_revision and "dispatch_async(dispatch_get_main_queue()" in ack_revision,
        "A compact ACK must resolve its exact durable hash set off-main from the transferred file.")
ack_batch = method_body(phone, "- (void)_applyManifestAcknowledgementBatchForEpisodeHashes:")
require("ICAppleWatchStateWriteBatchSize" in ack_batch and "manifestRevision" in ack_batch and
        "saveReturningError" in ack_batch and "dispatch_async(dispatch_get_main_queue()" in ack_batch,
        "Resolved ACK hashes must advance in small revision-gated UI-yielding batches.")
hash_reader = method_body(phone, "- (NSArray<NSString*>*)_episodeHashesFromManifestFileForRevision:")
require("ICEnumerateJSONLinesAtURL" in hash_reader and "NSInputStream" in phone and
        "NSJSONSerialization" in phone and "dataWithContentsOfURL" not in hash_reader and
        "NSPropertyListSerialization" not in hash_reader,
        "ACK hash recovery must stream the durable file instead of rebuilding its whole object graph.")
require("ICAppleWatchReceivedManifestAcknowledgementRevisionKey" in ack_revision and
        "ICAppleWatchAcknowledgedManifestRevisionKey" not in phone,
        "The durable ACK marker must only resume status reconciliation; it must never reject valid delayed episode events.")

receive_file = method_body(connectivity, "didReceive file:")
decode_staged = method_body(connectivity, "private func scheduleManifestInboxProcessing()")
require("WatchManifestTransferInbox.stage" in receive_file and
        "WatchManifestTransferSnapshot" in decode_staged and "decode(fileURL:" in decode_staged and
        "Data(contentsOf:" not in decode_staged,
        "The Watch must durably stage and stream-decode the received file before touching its active manifest.")
descriptor_case = connectivity.split('case "manifest.fileAvailable"', 1)
require(len(descriptor_case) == 2 and "replaceManifest" not in descriptor_case[1].split("case ", 1)[0],
        "A descriptor arriving before its file must never behave like an empty replace.")

replace = method_body(download, "func replaceManifest(")
apply_replace = method_body(connectivity, "private func applyManifestReplace(")
acknowledge = method_body(connectivity, "private func acknowledgeManifest(")
require("throws" in download[download.find("func replaceManifest("):download.find("{", download.find("func replaceManifest("))] and
        "try await WatchDownloadManager.shared.replaceManifest" in apply_replace and
        'payload["manifestRevision"]' in acknowledge,
        "The Watch ACK must identify the applied manifest revision.")
versioned_ack = acknowledge.split("if compactAcknowledgement", 1)[1].split("else", 1)[0]
require("episodeHashes" not in versioned_ack,
        "Versioned manifest ACKs must not send thousands of hashes back to the phone.")

activation = method_body(connectivity, "activationDidCompleteWith")
require('"manifestProtocolVersion": 3' in activation,
        "The Watch must explicitly advertise file-manifest support before the phone switches protocols.")
phone_request = phone.split('if ([type isEqualToString:@"watch.requestManifest"])', 1)[1].split("return;", 1)[0]
require("watchManifestProtocolVersion" in phone_request,
        "The phone must negotiate the active Watch protocol from its manifest request.")
require("MAX(self.watchManifestProtocolVersion" in phone_request and
        "_storeWatchManifestProtocolVersion:" in phone_request,
        "Delayed legacy requests must not downgrade a negotiated v2 session, and the capability must survive an iPhone restart.")
phone_activation = method_body(phone, "activationDidCompleteWithState:")
require("_storedWatchManifestProtocolVersionForSession:" in phone_activation and
        "watchDirectoryURL" in phone,
        "Protocol capability must be restored from the selected Watch's own durable directory before automatic sync.")

require("struct WatchManifestTransferSnapshot: Sendable" in transfer and
        "struct WatchManifestEntry: Sendable" in episode,
        "Decoded entries must cross from the WatchConnectivity delegate queue to MainActor safely.")
require("PropertyListSerialization" not in transfer and "Data(contentsOf:" not in transfer and
        "read(upToCount:" in transfer,
        "Watch decoding must keep only a small read buffer plus the final typed entries in memory.")
require("maximumEntryCount" in transfer and "count <= maximumEntryCount" in transfer and
        transfer.find("count <= maximumEntryCount") < transfer.find("entries.reserveCapacity(count)"),
        "A corrupt header must be bounded before it can reserve an untrusted amount of Watch memory.")
require("maximumManifestBytes" in transfer and "maximumLineBytes" in transfer and
        "totalBytesRead" in transfer and "pendingData.count > maximumLineBytes" in transfer,
        "Manifest and JSON-line sizes must be bounded while streaming so malformed input cannot grow without limit.")
manifest_entry = method_body(phone, "- (NSDictionary*)_manifestEntryForEpisode:")
require('@"subtitle"' not in manifest_entry and "episode.summary" not in manifest_entry and
        "let subtitle" not in episode,
        "Unused, unbounded episode summaries must not inflate every phone snapshot, transfer, and Watch manifest object.")


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
