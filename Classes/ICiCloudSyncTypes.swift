//
//  ICiCloudSyncTypes.swift
//  Instacast
//
//  Support types for ICiCloudSyncManager (split out of the 5000-line manager file).
//

@preconcurrency import CloudKit
import Foundation

final class ICCloudInventoryCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

final class ICCloudRecordBatchBox: @unchecked Sendable {
    let records: [CKRecord]

    init(_ records: [CKRecord]) {
        self.records = records
    }
}

struct ICCloudSyncOutboxSnapshot: Sendable {
    let accountRecordName: String
    let recordName: String
    let category: String
    let operation: String
    let acknowledged: Bool
    let revision: String
    let changedAt: Date
    let payloadData: Data

    func payloadDictionary() -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: payloadData, options: [], format: nil)) as? [String: Any]
    }

    func replacingAcknowledged(_ acknowledged: Bool) -> ICCloudSyncOutboxSnapshot {
        ICCloudSyncOutboxSnapshot(accountRecordName: accountRecordName,
                                  recordName: recordName,
                                  category: category,
                                  operation: operation,
                                  acknowledged: acknowledged,
                                  revision: revision,
                                  changedAt: changedAt,
                                  payloadData: payloadData)
    }
}

struct ICCloudLocalOutboxAcknowledgementAttempt: Sendable, Equatable {
    let revision: String
    let operation: String
}

struct ICCloudLocalOutboxAcknowledgementResult: Sendable {
    let objectIDURIsByRecordName: [String: URL]
    let updatedObjectIDURIs: [URL]
    let acknowledgedAttemptsByRecordName: [String: ICCloudLocalOutboxAcknowledgementAttempt]
    let fullyAcknowledgedAttemptsByRecordName: [String: ICCloudLocalOutboxAcknowledgementAttempt]
    let needsOutboxDrain: Bool
}

struct ICCloudPendingEpisodeStateWrite: Sendable {
    let recordName: String
    let payloadData: Data
}

struct ICCloudPendingEpisodeStateSnapshot: Sendable {
    let accountRecordName: String
    let recordName: String
    let payloadData: Data

    func payloadDictionary() throws -> [String: Any] {
        guard let payload = try PropertyListSerialization.propertyList(
            from: payloadData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(
                domain: "ICiCloudSyncPendingEpisodeState",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Der wartende iCloud-Episodenstatus ist beschädigt."]
            )
        }
        return payload
    }
}

enum ICiCloudRemoteApplyCategory: Hashable, Sendable {
    case episodes
    case subscriptions
    case localCapture
}

struct ICiCloudRemoteApplyCommitLease: Hashable, Sendable {
    let identifier: UUID
    let category: ICiCloudRemoteApplyCategory
    let generation: Int
    let accountRecordName: String
    let epoch: UInt64
}

struct ICCloudEpisodeApplyBatchResult: Sendable {
    let appliedCount: Int
    let recordNamesToUpload: Set<String>
    let recordNamesNeedingOutboxDrain: Set<String>
    let resolvedOutboxRevisions: [String: String]
    let remoteClockFloors: [String: Date]
    let insertedObjectURIStrings: Set<String>
    let updatedObjectURIStrings: Set<String>
    let remoteEpisodeObjectURIStrings: Set<String>
    let originRegistration: UUID?
    let clockRegistration: UUID?
    let commitLease: ICiCloudRemoteApplyCommitLease?
}

final class ICiCloudRemoteEpisodeOriginGate: @unchecked Sendable {
    private let lock = NSLock()
    private var objectURIStringsByRegistration: [UUID: Set<String>] = [:]

    func register(_ objectURIStrings: Set<String>) -> UUID? {
        guard !objectURIStrings.isEmpty else { return nil }
        let registration = UUID()
        lock.lock()
        objectURIStringsByRegistration[registration] = objectURIStrings
        lock.unlock()
        return registration
    }

    func take(_ registration: UUID?) -> Set<String> {
        guard let registration else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return objectURIStringsByRegistration.removeValue(forKey: registration) ?? []
    }

    func discard(_ registration: UUID?) {
        guard let registration else { return }
        lock.lock()
        objectURIStringsByRegistration.removeValue(forKey: registration)
        lock.unlock()
    }
}

final class ICiCloudRemoteEpisodeClockGate: @unchecked Sendable {
    private let lock = NSLock()
    private var floorsByRegistration: [UUID: [String: Date]] = [:]

    func register(_ floors: [String: Date]) -> UUID? {
        guard !floors.isEmpty else { return nil }
        let registration = UUID()
        lock.lock()
        floorsByRegistration[registration] = floors
        lock.unlock()
        return registration
    }

    func floor(for recordName: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return floorsByRegistration.values.compactMap { $0[recordName] }.max()
    }

    func remove(_ registration: UUID?) {
        guard let registration else { return }
        lock.lock()
        floorsByRegistration.removeValue(forKey: registration)
        lock.unlock()
    }
}

struct ICCloudPendingSubscriptionStateWrite: Sendable {
    let recordName: String
    let payloadData: Data
}

struct ICCloudPendingSubscriptionStateSnapshot: Sendable {
    let accountRecordName: String
    let recordName: String
    let payloadData: Data

    func payloadDictionary() throws -> [String: Any] {
        guard let payload = try PropertyListSerialization.propertyList(
            from: payloadData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(
                domain: "ICiCloudSyncPendingSubscriptionState",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Das wartende iCloud-Abonnement ist beschädigt."]
            )
        }
        return payload
    }
}

struct ICCloudPendingSubscriptionStatePage: Sendable {
    let snapshots: [ICCloudPendingSubscriptionStateSnapshot]
    let nextRecordName: String?
}

struct ICCloudSubscriptionCredentialUpdate: Sendable {
    let feedObjectURIString: String
    let sourceURLString: String
    let username: String
    let expectedPassword: String?
    let password: String
}

struct ICCloudSubscriptionCleanupIntentSnapshot: Sendable {
    let recordName: String
    let revision: String
    let payloadData: Data
    let feedObjectURIString: String
    let feedURL: String
    let pendingSnapshots: [ICCloudPendingSubscriptionStateSnapshot]
    var feedSubscribed: Bool? = nil
}

struct ICCloudSubscriptionCleanupDrainResult: Sendable {
    let error: NSError?
    let attemptedGeneration: UInt64
    let completedGeneration: UInt64
}

struct ICCloudSubscriptionCleanupProtectionStage: Sendable {
    let revision: String
    let stageToken: String
}

struct ICCloudSubscriptionApplyBatchResult: Sendable {
    let appliedSnapshots: [ICCloudPendingSubscriptionStateSnapshot]
    let needsOutboxDrain: Bool
    let finalOutboxSnapshots: [String: ICCloudSyncOutboxSnapshot]
    let removedOutboxRevisions: [String: String]
    let completedOutboxRecordNames: Set<String>
    let insertedObjectURIStrings: Set<String>
    let updatedObjectURIStrings: Set<String>
    let deletedObjectURIStrings: Set<String>
    let remoteObjectURIStrings: Set<String>
    let credentialUpdates: [ICCloudSubscriptionCredentialUpdate]
    let credentialPendingSnapshots: [ICCloudPendingSubscriptionStateSnapshot]
    let hasPendingSubscriptionCleanup: Bool
    let originRegistration: UUID?
    let commitLease: ICiCloudRemoteApplyCommitLease?
}

struct ICCloudSyncItemMetadataWrite: Sendable {
    let category: String
    let recordName: String
    let itemIdentifier: String
    let localModifiedAt: Date?
    let localState: Bool?
    let payloadHash: String?
}

struct ICCloudSyncItemMetadataSnapshot: Sendable {
    let accountRecordName: String
    let category: String
    let recordName: String
    let itemIdentifier: String
    let localModifiedAt: Date?
    let localState: Bool?
    let payloadHash: String?
}

struct ICCloudSyncItemMetadataUpdateFields: OptionSet, Sendable {
    let rawValue: Int

    static let localModifiedAt = ICCloudSyncItemMetadataUpdateFields(rawValue: 1 << 0)
    static let localState = ICCloudSyncItemMetadataUpdateFields(rawValue: 1 << 1)
    static let payloadHash = ICCloudSyncItemMetadataUpdateFields(rawValue: 1 << 2)
    static let all: ICCloudSyncItemMetadataUpdateFields = [
        .localModifiedAt,
        .localState,
        .payloadHash,
    ]
}

@objcMembers final class ICiCloudSyncDeviceInfo: NSObject {
    let deviceID: String
    let name: String
    let model: String
    let systemVersion: String
    let appVersion: String
    let lastSyncDate: Date?
    let episodesEnabled: Bool
    let subscriptionsEnabled: Bool
    let settingsEnabled: Bool
    let isCurrentDevice: Bool

    init(deviceID: String,
         name: String,
         model: String,
         systemVersion: String,
         appVersion: String,
         lastSyncDate: Date?,
         episodesEnabled: Bool,
         subscriptionsEnabled: Bool,
         settingsEnabled: Bool,
         isCurrentDevice: Bool) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.lastSyncDate = lastSyncDate
        self.episodesEnabled = episodesEnabled
        self.subscriptionsEnabled = subscriptionsEnabled
        self.settingsEnabled = settingsEnabled
        self.isCurrentDevice = isCurrentDevice
        super.init()
    }
}

@objcMembers final class ICiCloudSyncCounts: NSObject {
    // "synced" = how many of "total" are already on iCloud; "total" = how many will be synced
    // from this device (e.g. episodes with play state). Shown as "synced / total".
    let episodesSynced: Int
    let episodesTotal: Int
    let subscriptionsSynced: Int
    let subscriptionsTotal: Int
    let settings: Int
    // false while the background count hasn't produced a value yet — the UI shows a
    // placeholder then instead of a misleading "0 / 0".
    let countsAvailable: Bool

    init(episodesSynced: Int,
         episodesTotal: Int,
         subscriptionsSynced: Int,
         subscriptionsTotal: Int,
         settings: Int,
         countsAvailable: Bool) {
        self.episodesSynced = episodesSynced
        self.episodesTotal = episodesTotal
        self.subscriptionsSynced = subscriptionsSynced
        self.subscriptionsTotal = subscriptionsTotal
        self.settings = settings
        self.countsAvailable = countsAvailable
        super.init()
    }
}

// Hard record counts straight from the CloudKit zone — what is actually ON iCloud,
// independent of local state, switches or sync progress.
@objcMembers final class ICiCloudSyncCloudInventory: NSObject {
    let episodeStates: Int
    let subscriptions: Int
    let settings: Int
    let fetchDate: Date

    init(episodeStates: Int, subscriptions: Int, settings: Int, fetchDate: Date) {
        self.episodeStates = episodeStates
        self.subscriptions = subscriptions
        self.settings = settings
        self.fetchDate = fetchDate
        super.init()
    }
}

// Record-type counters shared with the (serially executing) CloudKit operation callbacks.
// Collects the inventory from a change-stream fetch. Deduplicated by record name:
// a nil-token CKFetchRecordZoneChangesOperation streams CHANGES, so a record that is
// modified while the fetch runs can be delivered twice (the phantom "ICDevice=3,
// ICListScrollPositions=2" counts) — and deletions during the stream must subtract.
final class ICCloudInventoryCountsBox: @unchecked Sendable {
    private var recordNamesByType: [String: Set<String>] = [:]
    private var allObservedRecordNames = Set<String>()
    private var deviceRecordIDs: [CKRecord.ID] = []
    private var transitionalSubscriptionRecordChangeTags: [String: String]
    private var observedSubscriptionRecordNames = Set<String>()
    private var recordFetchFailed = false
    private var zoneFetchCompleted = false
    private var zoneMissing = false
    private let inspectSubscriptionPayloads: Bool
    private let lock = NSLock()

    init(transitionalSubscriptionRecordChangeTags: [String: String],
         inspectSubscriptionPayloads: Bool) {
        self.transitionalSubscriptionRecordChangeTags = transitionalSubscriptionRecordChangeTags
        self.inspectSubscriptionPayloads = inspectSubscriptionPayloads
    }

    func record(_ record: CKRecord) {
        lock.lock()
        allObservedRecordNames.insert(record.recordID.recordName)
        if record.recordType == "ICSubscription" {
            let recordName = record.recordID.recordName
            observedSubscriptionRecordNames.insert(recordName)
            if inspectSubscriptionPayloads, Self.isTransitionalSubscriptionTombstone(record) {
                if let changeTag = record.recordChangeTag {
                    transitionalSubscriptionRecordChangeTags[recordName] = changeTag
                }
                recordNamesByType[record.recordType]?.remove(recordName)
            } else if !inspectSubscriptionPayloads,
                      transitionalSubscriptionRecordChangeTags[recordName] == record.recordChangeTag {
                // This exact transitional tombstone was identified during the one-time
                // payload scan. System fields are enough to keep excluding it; a changed
                // tag means the same record name was resubscribed and must count again.
                recordNamesByType[record.recordType]?.remove(recordName)
            } else {
                transitionalSubscriptionRecordChangeTags.removeValue(forKey: recordName)
                recordNamesByType[record.recordType, default: []].insert(recordName)
            }
        } else {
            recordNamesByType[record.recordType, default: []].insert(record.recordID.recordName)
        }
        if record.recordType == "ICDevice", !deviceRecordIDs.contains(record.recordID) {
            deviceRecordIDs.append(record.recordID)
        }
        lock.unlock()
    }

    private static func isTransitionalSubscriptionTombstone(_ record: CKRecord) -> Bool {
        guard let rawPayload = record.encryptedValues["payload"] else { return false }
        let data: Data
        if let value = rawPayload as? Data {
            data = value
        } else if let value = rawPayload as? NSData {
            data = value as Data
        } else {
            return false
        }
        guard let payload = (try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil)) as? [String: Any] else { return false }
        return (payload["deleted"] as? Bool) ?? false
    }

    func remove(recordName: String) {
        lock.lock()
        allObservedRecordNames.remove(recordName)
        for type in recordNamesByType.keys {
            recordNamesByType[type]?.remove(recordName)
        }
        transitionalSubscriptionRecordChangeTags.removeValue(forKey: recordName)
        observedSubscriptionRecordNames.remove(recordName)
        deviceRecordIDs.removeAll { $0.recordName == recordName }
        lock.unlock()
    }

    func markRecordFetchFailure() {
        lock.lock()
        recordFetchFailed = true
        lock.unlock()
    }

    func markZoneFetchCompleted(moreComing: Bool) {
        lock.lock()
        if !moreComing {
            zoneFetchCompleted = true
        }
        lock.unlock()
    }

    func markZoneMissing() {
        lock.lock()
        zoneMissing = true
        lock.unlock()
    }

    func inventoryIsComplete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return zoneFetchCompleted && !recordFetchFailed && !zoneMissing
    }

    func observedRecordNames() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return allObservedRecordNames
    }

    func observedMissingZone() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return zoneMissing
    }

    func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordNamesByType.mapValues { $0.count }
    }

    func deviceIDs() -> [CKRecord.ID] {
        lock.lock()
        defer { lock.unlock() }
        return deviceRecordIDs
    }

    func transitionalSubscriptionRecords() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return transitionalSubscriptionRecordChangeTags.filter {
            observedSubscriptionRecordNames.contains($0.key)
        }
    }
}
