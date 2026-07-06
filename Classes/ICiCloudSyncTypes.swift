//
//  ICiCloudSyncTypes.swift
//  Instacast
//
//  Support types for ICiCloudSyncManager (split out of the 5000-line manager file).
//

@preconcurrency import CloudKit
import Foundation

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
    private var deviceRecordIDs: [CKRecord.ID] = []
    private let lock = NSLock()

    func record(_ record: CKRecord) {
        lock.lock()
        recordNamesByType[record.recordType, default: []].insert(record.recordID.recordName)
        if record.recordType == "ICDevice", !deviceRecordIDs.contains(record.recordID) {
            deviceRecordIDs.append(record.recordID)
        }
        lock.unlock()
    }

    func remove(recordName: String) {
        lock.lock()
        for type in recordNamesByType.keys {
            recordNamesByType[type]?.remove(recordName)
        }
        deviceRecordIDs.removeAll { $0.recordName == recordName }
        lock.unlock()
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
}
