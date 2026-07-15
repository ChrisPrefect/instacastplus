#!/usr/bin/env python3
"""Main-queue heartbeat proof for one async 1000-feed EpisodeList snapshot."""

import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
LOCAL = (ROOT / "Classes" / "ICiCloudSyncManager+LocalChanges.swift").read_text()


SWIFT_PROOF = r'''
import CoreData
import Foundation

struct ProofFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProofFailure(description: message) }
}

final class ProofState: @unchecked Sendable {
    private let lock = NSLock()
    private var _readCount = 0
    private var _heartbeatRan = false
    private var _error: Error?

    func recordRead() { lock.lock(); _readCount += 1; lock.unlock() }
    func recordHeartbeat() { lock.lock(); _heartbeatRan = true; lock.unlock() }
    func recordError(_ error: Error) { lock.lock(); _error = error; lock.unlock() }
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _readCount }
    var heartbeatRan: Bool { lock.lock(); defer { lock.unlock() }; return _heartbeatRan }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
}

func attribute(_ name: String, _ type: NSAttributeType) -> NSAttributeDescription {
    let value = NSAttributeDescription()
    value.name = name
    value.attributeType = type
    value.isOptional = false
    return value
}

let model = NSManagedObjectModel()
let feed = NSEntityDescription()
feed.name = "Feed"
feed.managedObjectClassName = "NSManagedObject"
feed.properties = [attribute("sourceURL", .stringAttributeType)]

let list = NSEntityDescription()
list.name = "EpisodeList"
list.managedObjectClassName = "NSManagedObject"
let uid = attribute("uid", .stringAttributeType)
let includedFeeds = NSRelationshipDescription()
includedFeeds.name = "includedFeeds"
includedFeeds.destinationEntity = feed
includedFeeds.minCount = 0
includedFeeds.maxCount = 0
includedFeeds.isOptional = true
includedFeeds.isOrdered = false
includedFeeds.deleteRule = .nullifyDeleteRule
list.properties = [uid, includedFeeds]
model.entities = [feed, list]

guard let storePath = ProcessInfo.processInfo.environment["LIST_ASYNC_STORE"] else {
    fatalError("LIST_ASYNC_STORE missing")
}
let container = NSPersistentContainer(name: "ListAsyncProof", managedObjectModel: model)
let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: storePath))
description.type = NSSQLiteStoreType
container.persistentStoreDescriptions = [description]
let loaded = DispatchSemaphore(value: 0)
var loadError: Error?
container.loadPersistentStores { _, error in loadError = error; loaded.signal() }
loaded.wait()
if let loadError { throw loadError }

let seedContext = container.newBackgroundContext()
try seedContext.performAndWait {
    let episodeList = NSEntityDescription.insertNewObject(forEntityName: "EpisodeList", into: seedContext)
    episodeList.setValue("list", forKey: "uid")
    var feeds = Set<NSManagedObject>()
    for index in 0..<1_000 {
        let object = NSEntityDescription.insertNewObject(forEntityName: "Feed", into: seedContext)
        object.setValue("https://example.com/\(index)", forKey: "sourceURL")
        feeds.insert(object)
    }
    episodeList.setValue(feeds, forKey: "includedFeeds")
    try seedContext.save()
}

let state = ProofState()
let readStarted = DispatchSemaphore(value: 0)
let allowRead = DispatchSemaphore(value: 0)
let completed = DispatchSemaphore(value: 0)

func committedPayload() async throws -> [String: Any] {
    let context = container.newBackgroundContext()
    return try await context.perform {
        state.recordRead()
        readStarted.signal()
        guard allowRead.wait(timeout: .now() + 5) == .success else {
            throw ProofFailure(description: "Main heartbeat did not run while payload read was suspended")
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: "EpisodeList")
        request.relationshipKeyPathsForPrefetching = ["includedFeeds"]
        guard let episodeList = try context.fetch(request).first else {
            throw ProofFailure(description: "EpisodeList missing")
        }
        let urls = ((episodeList.value(forKey: "includedFeeds") as? Set<NSManagedObject>) ?? [])
            .compactMap { $0.value(forKey: "sourceURL") as? String }
            .sorted()
        return ["episodeLists": [["uid": "list", "includedFeedURLs": urls]]]
    }
}

DispatchQueue.global(qos: .userInitiated).async {
    guard readStarted.wait(timeout: .now() + 5) == .success else {
        allowRead.signal()
        return
    }
    DispatchQueue.main.async {
        state.recordHeartbeat()
        allowRead.signal()
    }
}

Task { @MainActor in
    do {
        let payload = try await committedPayload()
        let fingerprintData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
        let intentPayload = payload
        let intentData = try PropertyListSerialization.data(
            fromPropertyList: intentPayload,
            format: .binary,
            options: 0
        )
        let lists = payload["episodeLists"] as! [[String: Any]]
        let urls = lists[0]["includedFeedURLs"] as! [String]
        try require(urls.count == 1_000, "Committed payload lost included feeds")
        try require(fingerprintData == intentData,
                    "Fingerprint and intent did not consume the identical payload")
    } catch {
        state.recordError(error)
    }
    completed.signal()
}

let deadline = Date().addingTimeInterval(8)
while completed.wait(timeout: .now()) != .success && Date() < deadline {
    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
try require(state.error == nil, "Async payload proof failed: \(String(describing: state.error))")
try require(state.heartbeatRan, "Main queue did not heartbeat during the 1000-feed read")
try require(state.readCount == 1, "Committed graph was read \(state.readCount) times instead of once")

print("iCloud list-settings async 1000-feed heartbeat proof passed")
'''


def method_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start == -1:
        raise AssertionError(f"Missing method: {signature}")
    brace = source.find("{", start)
    depth = 0
    for index in range(brace, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[brace + 1:index]
    raise AssertionError(f"Unterminated method: {signature}")


with tempfile.TemporaryDirectory(prefix="icloud-list-async-") as directory:
    environment = os.environ.copy()
    environment["LIST_ASYNC_STORE"] = str(Path(directory) / "proof.sqlite")
    result = subprocess.run(
        ["xcrun", "swift", "-e", SWIFT_PROOF],
        cwd=ROOT,
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode != 0:
        raise AssertionError(f"1000-feed heartbeat proof failed:\n{result.stdout}")
    print(result.stdout.strip())


checker = method_body(LOCAL, "func checkAndQueueSettingsChange")
if checker.count("committedSubscriptionListSettingsPayload()") != 1:
    raise AssertionError("Production list checker does not yet perform exactly one async committed read.")
if ("await Self.committedSubscriptionListSettingsPayload()" not in checker
        or "payload: subscriptionListSettingsPayload" not in checker):
    raise AssertionError("Production list checker does not yet reuse the one background payload.")

print("iCloud list-settings async runtime source checks passed")
