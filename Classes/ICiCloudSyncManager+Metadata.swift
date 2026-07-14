//
//  ICiCloudSyncManager+Metadata.swift
//  Instacast
//
//  Sync metadata storage, device cache, record IDs, status and diagnostics.
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Foundation
import UIKit

struct ICCloudSyncItemMetadataContextBatch {
    let accountRecordName: String
    let context: NSManagedObjectContext
    let loadedRecordNames: Set<String>
    var entriesByRecordName: [String: NSManagedObject]
}

final class ICCloudLegacyKnownRecordSystemFieldsBatch: @unchecked Sendable {
    let records: [CKRecord]
    let sourcePaths: [String]

    init(records: [CKRecord], sourcePaths: [String]) {
        self.records = records
        self.sourcePaths = sourcePaths
    }
}

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    func localDevicePayload() -> [String: Any] {
        Self.devicePayload(deviceID: deviceID,
                           episodesEnabled: episodesSyncEnabled,
                           subscriptionsEnabled: subscriptionsSyncEnabled,
                           settingsEnabled: settingsSyncEnabled,
                           lastSyncDate: lastSyncDate)
    }

    nonisolated static func feedPropertyValueType(for property: CDFeedProperty) -> String {
        if property.stringValue != nil {
            return "string"
        }
        guard let key = property.key else {
            return "bool"
        }
        return defaultFeedPropertyValueType(for: key)
    }

    nonisolated static func defaultFeedPropertyValueType(for key: String) -> String {
        guard let value = UserDefaults.standard.object(forKey: key) else {
            return "bool"
        }
        if value is String {
            return "string"
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return "bool"
            }
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                return "double"
            }
            return "integer"
        }
        return "bool"
    }

    nonisolated static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    nonisolated static func int32Value(_ value: Any?) -> Int32? {
        if let value = value as? NSNumber { return value.int32Value }
        if let value = value as? Int { return Int32(value) }
        return nil
    }

    func payloadDictionary(from record: CKRecord) -> [String: Any]? {
        guard let rawPayload = record.encryptedValues["payload"] else { return nil }
        let data: Data
        if let swiftData = rawPayload as? Data {
            data = swiftData
        } else if let nsData = rawPayload as? NSData {
            data = nsData as Data
        } else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    nonisolated static var knownRecordSystemFieldsEntityName: String {
        "ICCloudKnownRecordSystemFields"
    }

    nonisolated static func knownRecordSystemFieldsStoreError(code: Int,
                                                               description: String) -> NSError {
        NSError(domain: "ICCloudKnownRecordSystemFields",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    nonisolated static func persistKnownRecordSystemFields(
        _ records: [CKRecord],
        accountRecordName: String
    ) async throws {
        guard !accountRecordName.isEmpty else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale CloudKit-Systemfelder konnte nicht bestimmt werden."
            )
        }
        guard !records.isEmpty else { return }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der lokale CloudKit-Systemfeldspeicher konnte nicht geöffnet werden."
            )
        }
        var index = records.startIndex
        while index < records.endIndex {
            let end = records.index(
                index,
                offsetBy: maximumRecordZoneChangesPerBatch,
                limitedBy: records.endIndex
            ) ?? records.endIndex
            let box = ICCloudRecordBatchBox(Array(records[index..<end]))
            let chunk: [(recordName: String, data: Data)] = try await Task.detached(priority: .utility) {
                var latestDataByRecordName: [String: Data] = [:]
                for record in box.records {
                    let recordName = record.recordID.recordName
                    guard !recordName.isEmpty else {
                        throw knownRecordSystemFieldsStoreError(
                            code: 2,
                            description: "Ein CloudKit-Systemfeldeintrag hat keine Datensatz-ID."
                        )
                    }
                    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
                    record.encodeSystemFields(with: archiver)
                    archiver.finishEncoding()
                    latestDataByRecordName[recordName] = archiver.encodedData
                }
                return latestDataByRecordName
                    .map { (recordName: $0.key, data: $0.value) }
                    .sorted { $0.recordName < $1.recordName }
            }.value
            try await context.perform {
                let recordNames = chunk.map(\.recordName)
                let request = NSFetchRequest<NSManagedObject>(entityName: knownRecordSystemFieldsEntityName)
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    recordNames
                )
                request.includesSubentities = false
                request.fetchLimit = maximumRecordZoneChangesPerBatch
                request.fetchBatchSize = maximumRecordZoneChangesPerBatch
                var entriesByRecordName: [String: NSManagedObject] = [:]
                for entry in try context.fetch(request) {
                    guard let recordName = entry.value(forKey: "recordName") as? String,
                          entriesByRecordName[recordName] == nil else {
                        throw knownRecordSystemFieldsStoreError(
                            code: 2,
                            description: "Ein lokaler CloudKit-Systemfeldeintrag ist beschädigt oder mehrfach vorhanden."
                        )
                    }
                    entriesByRecordName[recordName] = entry
                }
                for write in chunk {
                    let entry = entriesByRecordName[write.recordName]
                        ?? NSEntityDescription.insertNewObject(
                            forEntityName: knownRecordSystemFieldsEntityName,
                            into: context
                        )
                    entry.setValue(accountRecordName, forKey: "accountRecordName")
                    entry.setValue(write.recordName, forKey: "recordName")
                    entry.setValue(write.data, forKey: "systemFieldsData")
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
            }
            index = end
            if index < records.endIndex {
                await Task.yield()
            }
        }
    }

    nonisolated static func removeKnownRecordSystemFields(
        _ recordIDs: [CKRecord.ID],
        accountRecordName: String
    ) async throws {
        guard !accountRecordName.isEmpty else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale CloudKit-Systemfelder konnte nicht bestimmt werden."
            )
        }
        let recordNames = Set(recordIDs.map(\.recordName)).filter { !$0.isEmpty }.sorted()
        guard !recordNames.isEmpty else { return }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der lokale CloudKit-Systemfeldspeicher konnte nicht geöffnet werden."
            )
        }
        var index = recordNames.startIndex
        while index < recordNames.endIndex {
            let end = recordNames.index(
                index,
                offsetBy: maximumRecordZoneChangesPerBatch,
                limitedBy: recordNames.endIndex
            ) ?? recordNames.endIndex
            let chunk = Array(recordNames[index..<end])
            try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: knownRecordSystemFieldsEntityName)
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    chunk
                )
                request.includesSubentities = false
                request.fetchLimit = maximumRecordZoneChangesPerBatch
                request.fetchBatchSize = maximumRecordZoneChangesPerBatch
                for entry in try context.fetch(request) {
                    context.delete(entry)
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
            }
            index = end
            if index < recordNames.endIndex {
                await Task.yield()
            }
        }
    }

    nonisolated static func snapshotKnownRecordSystemFieldsForPruning(
        accountRecordName: String
    ) async throws -> [String: Data] {
        guard !accountRecordName.isEmpty else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale CloudKit-Systemfelder konnte nicht bestimmt werden."
            )
        }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der lokale CloudKit-Systemfeldspeicher konnte nicht geöffnet werden."
            )
        }

        var candidates: [String: Data] = [:]
        var lastRecordName: String?
        while true {
            let lowerBound = lastRecordName
            let page: (scanned: Int, digests: [String: Data], lastRecordName: String?) = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: knownRecordSystemFieldsEntityName)
                if let lowerBound {
                    request.predicate = NSPredicate(
                        format: "accountRecordName == %@ AND recordName > %@",
                        accountRecordName,
                        lowerBound
                    )
                } else {
                    request.predicate = NSPredicate(
                        format: "accountRecordName == %@",
                        accountRecordName
                    )
                }
                request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
                request.includesSubentities = false
                request.fetchLimit = maximumRecordZoneChangesPerBatch
                request.fetchBatchSize = maximumRecordZoneChangesPerBatch
                let entries = try context.fetch(request)
                var pageDigests: [String: Data] = [:]
                var pageLastRecordName: String?
                for entry in entries {
                    guard let recordName = entry.value(forKey: "recordName") as? String,
                          !recordName.isEmpty,
                          let systemFieldsData = entry.value(forKey: "systemFieldsData") as? Data,
                          pageDigests[recordName] == nil else {
                        throw knownRecordSystemFieldsStoreError(
                            code: 2,
                            description: "Ein lokaler CloudKit-Systemfeldeintrag ist beschädigt."
                        )
                    }
                    pageLastRecordName = recordName
                    pageDigests[recordName] = Data(SHA256.hash(data: systemFieldsData))
                }
                let result = (entries.count, pageDigests, pageLastRecordName)
                context.reset()
                return result
            }
            for (recordName, digest) in page.digests {
                guard candidates[recordName] == nil else {
                    throw knownRecordSystemFieldsStoreError(
                        code: 2,
                        description: "Ein lokaler CloudKit-Systemfeldeintrag ist mehrfach vorhanden."
                    )
                }
                candidates[recordName] = digest
            }
            guard page.scanned > 0, let pageLastRecordName = page.lastRecordName else {
                return candidates
            }
            lastRecordName = pageLastRecordName
            await Task.yield()
        }
    }

    @discardableResult
    nonisolated static func pruneKnownRecordSystemFields(
        keeping observedRecordNames: Set<String>,
        candidatesAtInventoryStart: [String: Data],
        accountRecordName: String
    ) async throws -> Int {
        guard !accountRecordName.isEmpty else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale CloudKit-Systemfelder konnte nicht bestimmt werden."
            )
        }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der lokale CloudKit-Systemfeldspeicher konnte nicht geöffnet werden."
            )
        }

        let staleCandidates = candidatesAtInventoryStart
            .filter { !observedRecordNames.contains($0.key) }
            .sorted { $0.key < $1.key }
        var deletedCount = 0
        var index = staleCandidates.startIndex
        while index < staleCandidates.endIndex {
            let end = staleCandidates.index(
                index,
                offsetBy: maximumRecordZoneChangesPerBatch,
                limitedBy: staleCandidates.endIndex
            ) ?? staleCandidates.endIndex
            let chunk = Dictionary<String, Data>(
                uniqueKeysWithValues: staleCandidates[index..<end].map { ($0.key, $0.value) }
            )
            let chunkDeletedCount = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: knownRecordSystemFieldsEntityName)
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    Array(chunk.keys)
                )
                request.includesSubentities = false
                request.fetchLimit = maximumRecordZoneChangesPerBatch
                request.fetchBatchSize = maximumRecordZoneChangesPerBatch
                var loadedRecordNames: Set<String> = []
                var pageDeletedCount = 0
                for entry in try context.fetch(request) {
                    guard let recordName = entry.value(forKey: "recordName") as? String,
                          !recordName.isEmpty,
                          loadedRecordNames.insert(recordName).inserted,
                          let candidateDigest = chunk[recordName],
                          let currentData = entry.value(forKey: "systemFieldsData") as? Data else {
                        throw knownRecordSystemFieldsStoreError(
                            code: 2,
                            description: "Ein lokaler CloudKit-Systemfeldeintrag ist beschädigt oder mehrfach vorhanden."
                        )
                    }
                    let currentDigest = Data(SHA256.hash(data: currentData))
                    if candidateDigest == currentDigest {
                        context.delete(entry)
                        pageDeletedCount += 1
                    }
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
                return pageDeletedCount
            }
            deletedCount += chunkDeletedCount
            index = end
            if index < staleCandidates.endIndex {
                await Task.yield()
            }
        }
        return deletedCount
    }

    @discardableResult
    nonisolated static func deleteKnownRecordSystemFields(
        accountRecordName: String? = nil
    ) async throws -> Int {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der lokale CloudKit-Systemfeldspeicher konnte nicht geöffnet werden."
            )
        }
        var deletedCount = 0
        while true {
            let batchCount = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: knownRecordSystemFieldsEntityName)
                if let accountRecordName {
                    request.predicate = NSPredicate(format: "accountRecordName == %@", accountRecordName)
                }
                request.includesSubentities = false
                request.fetchLimit = maximumRecordZoneChangesPerBatch
                request.fetchBatchSize = maximumRecordZoneChangesPerBatch
                let entries = try context.fetch(request)
                for entry in entries {
                    context.delete(entry)
                }
                if context.hasChanges {
                    try context.save()
                }
                let count = entries.count
                context.reset()
                return count
            }
            deletedCount += batchCount
            guard batchCount > 0 else { return deletedCount }
            await Task.yield()
        }
    }

    func deviceCache() -> [String: [String: Any]] {
        Self.syncMetadataValue(forKey: Self.deviceCacheKey) as? [String: [String: Any]] ?? [:]
    }

    func updateDeviceCache(with payload: [String: Any]) {
        guard let id = payload["deviceID"] as? String, !id.isEmpty else { return }
        var cache = deviceCache()
        cache[id] = payload
        setSyncMetadata(cache, forKey: Self.deviceCacheKey)
        postDevicesChanged()
    }

    func removeDeviceFromCache(_ deviceID: String) {
        var cache = deviceCache()
        guard cache.removeValue(forKey: deviceID) != nil else { return }
        setSyncMetadata(cache, forKey: Self.deviceCacheKey)
        postDevicesChanged()
    }

    // Removes a stale device entry — every (re-)installation registers under a fresh
    // device ID, so old installs linger in everyone's device list forever. Deletes the
    // ICDevice record from CloudKit; the other devices clean up their cached entry when
    // the deletion arrives in their next fetch. The CURRENT device cannot be removed.
    @objc func deleteDevice(withID targetDeviceID: String) {
        guard !targetDeviceID.isEmpty, targetDeviceID != deviceID else { return }
        initializeSyncEngineIfNeeded()
        syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(deviceRecordID(for: targetDeviceID))])
        removeDeviceFromCache(targetDeviceID)
        logSyncEvent("Geräte-Eintrag wird entfernt", metadata: ["targetDeviceID": targetDeviceID])
        scheduleLowPrioritySync()
    }

    func deviceParticipates(_ payload: [String: Any]) -> Bool {
        ((payload["episodesEnabled"] as? Bool) ?? false)
        || ((payload["subscriptionsEnabled"] as? Bool) ?? false)
        || ((payload["settingsEnabled"] as? Bool) ?? false)
    }

    nonisolated static var syncItemMetadataEntityName: String {
        "ICCloudSyncItemMetadata"
    }

    nonisolated static func syncItemMetadataStoreError(code: Int,
                                                       description: String) -> NSError {
        NSError(domain: "ICiCloudSyncItemMetadata",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    nonisolated static func legacySyncItemMetadataError(underlyingError: Error? = nil) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: NSLocalizedString(
                "The local iCloud sync metadata on this device is damaged. Automatic synchronization has been stopped to protect your data. Export a backup and contact support.",
                comment: ""
            ),
        ]
        if let underlyingError {
            userInfo[NSUnderlyingErrorKey] = underlyingError
        }
        return NSError(domain: legacySyncItemMetadataErrorDomain,
                       code: 1,
                       userInfo: userInfo)
    }

    nonisolated static func isDeterministicLegacySyncItemMetadataError(_ error: Error) -> Bool {
        (error as NSError).domain == legacySyncItemMetadataErrorDomain
    }

    nonisolated static func isDeterministicSyncItemMetadataMigrationError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == "ICiCloudSyncItemMetadata"
            && (error.code == 2 || error.code == 3)
    }

    nonisolated static func episodeSyncItemMetadataIdentityWrite(
        recordName: String,
        objectHash: String
    ) throws -> ICCloudSyncItemMetadataWrite {
        guard !objectHash.isEmpty,
              recordName == RecordPrefix.episode + objectHash else {
            throw syncItemMetadataStoreError(
                code: 3,
                description: "Ein empfangener iCloud-Episodenstatus hat eine widersprüchliche Identität."
            )
        }
        return ICCloudSyncItemMetadataWrite(
            category: localOutboxEpisodeCategory,
            recordName: recordName,
            itemIdentifier: objectHash,
            localModifiedAt: nil,
            localState: nil,
            payloadHash: nil
        )
    }

    nonisolated static func syncItemMetadataSnapshot(
        from entry: NSManagedObject
    ) throws -> ICCloudSyncItemMetadataSnapshot {
        guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
              let category = entry.value(forKey: "category") as? String,
              let recordName = entry.value(forKey: "recordName") as? String,
              let itemIdentifier = entry.value(forKey: "itemIdentifier") as? String else {
            throw syncItemMetadataStoreError(
                code: 2,
                description: "Ein lokaler iCloud-Metadateneintrag ist beschädigt."
            )
        }
        return ICCloudSyncItemMetadataSnapshot(
            accountRecordName: accountRecordName,
            category: category,
            recordName: recordName,
            itemIdentifier: itemIdentifier,
            localModifiedAt: entry.value(forKey: "localModifiedAt") as? Date,
            localState: (entry.value(forKey: "localState") as? NSNumber)?.boolValue,
            payloadHash: entry.value(forKey: "payloadHash") as? String
        )
    }

    // Main-context callers use this synchronous, indexed prefetch before mutating any
    // episode/feed or outbox rows. The caller remains the transaction owner and performs
    // the single save after both the user data and its conflict metadata have been updated.
    nonisolated static func prepareSyncItemMetadataContextBatch(
        accountRecordName: String,
        recordNames: Set<String>,
        context: NSManagedObjectContext
    ) throws -> ICCloudSyncItemMetadataContextBatch {
        guard !accountRecordName.isEmpty else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale Sync-Metadaten konnte nicht bestimmt werden."
            )
        }
        let sortedRecordNames = recordNames.filter { !$0.isEmpty }.sorted()
        var entriesByRecordName: [String: NSManagedObject] = [:]
        var index = sortedRecordNames.startIndex
        while index < sortedRecordNames.endIndex {
            let end = sortedRecordNames.index(
                index,
                offsetBy: remoteApplyBatchSize,
                limitedBy: sortedRecordNames.endIndex
            ) ?? sortedRecordNames.endIndex
            let chunk = Array(sortedRecordNames[index..<end])
            let request = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
            request.predicate = NSPredicate(
                format: "accountRecordName == %@ AND recordName IN %@",
                accountRecordName,
                chunk
            )
            request.fetchBatchSize = remoteApplyBatchSize
            for entry in try context.fetch(request) {
                let snapshot = try syncItemMetadataSnapshot(from: entry)
                guard entriesByRecordName[snapshot.recordName] == nil else {
                    throw syncItemMetadataStoreError(
                        code: 3,
                        description: "Ein lokaler iCloud-Metadateneintrag ist mehrfach vorhanden."
                    )
                }
                entriesByRecordName[snapshot.recordName] = entry
            }
            index = end
        }
        return ICCloudSyncItemMetadataContextBatch(
            accountRecordName: accountRecordName,
            context: context,
            loadedRecordNames: Set(sortedRecordNames),
            entriesByRecordName: entriesByRecordName
        )
    }

    nonisolated static func syncItemMetadataSnapshot(
        forRecordName recordName: String,
        metadataBatch: ICCloudSyncItemMetadataContextBatch
    ) throws -> ICCloudSyncItemMetadataSnapshot? {
        guard metadataBatch.loadedRecordNames.contains(recordName) else {
            throw syncItemMetadataStoreError(
                code: 2,
                description: "Ein lokaler iCloud-Metadateneintrag wurde nicht vorbereitet."
            )
        }
        guard let entry = metadataBatch.entriesByRecordName[recordName] else { return nil }
        return try syncItemMetadataSnapshot(from: entry)
    }

    // This overload deliberately does not save. It is the atomic bridge used by local and
    // remote apply transactions; optional fields can be updated independently so a hash-only
    // re-baseline never clears the logical clock/state, while a tombstone can explicitly clear
    // its payload hash.
    @discardableResult
    nonisolated static func upsertSyncItemMetadata(
        _ writes: [ICCloudSyncItemMetadataWrite],
        updating fields: ICCloudSyncItemMetadataUpdateFields = .all,
        metadataBatch: inout ICCloudSyncItemMetadataContextBatch,
        context: NSManagedObjectContext
    ) throws -> [ICCloudSyncItemMetadataSnapshot] {
        guard metadataBatch.context === context else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Lokale iCloud-Metadaten wurden im falschen Datenbankkontext vorbereitet."
            )
        }
        var latestWriteByRecordName: [String: ICCloudSyncItemMetadataWrite] = [:]
        for write in writes {
            guard !write.category.isEmpty, !write.recordName.isEmpty,
                  !write.itemIdentifier.isEmpty,
                  metadataBatch.loadedRecordNames.contains(write.recordName) else {
                throw syncItemMetadataStoreError(
                    code: 2,
                    description: "Ein lokaler iCloud-Metadateneintrag ist unvollständig oder nicht vorbereitet."
                )
            }
            latestWriteByRecordName[write.recordName] = write
        }
        let uniqueWrites = latestWriteByRecordName.values.sorted { $0.recordName < $1.recordName }

        // Validate every existing identity before changing the context. A corrupt/colliding
        // row therefore cannot leave a half-mutated outbox transaction behind.
        for write in uniqueWrites {
            guard let existing = metadataBatch.entriesByRecordName[write.recordName] else { continue }
            let snapshot = try syncItemMetadataSnapshot(from: existing)
            guard snapshot.accountRecordName == metadataBatch.accountRecordName,
                  snapshot.category == write.category,
                  snapshot.itemIdentifier == write.itemIdentifier else {
                throw syncItemMetadataStoreError(
                    code: 3,
                    description: "Ein lokaler iCloud-Metadateneintrag hat eine widersprüchliche Identität."
                )
            }
        }

        var snapshots: [ICCloudSyncItemMetadataSnapshot] = []
        snapshots.reserveCapacity(uniqueWrites.count)
        for write in uniqueWrites {
            let entry: NSManagedObject
            if let existing = metadataBatch.entriesByRecordName[write.recordName] {
                entry = existing
            } else {
                entry = NSEntityDescription.insertNewObject(
                    forEntityName: syncItemMetadataEntityName,
                    into: context
                )
                entry.setValue(metadataBatch.accountRecordName, forKey: "accountRecordName")
                entry.setValue(write.category, forKey: "category")
                entry.setValue(write.recordName, forKey: "recordName")
                entry.setValue(write.itemIdentifier, forKey: "itemIdentifier")
                metadataBatch.entriesByRecordName[write.recordName] = entry
            }
            if fields.contains(.localModifiedAt) {
                entry.setValue(write.localModifiedAt, forKey: "localModifiedAt")
            }
            if fields.contains(.localState) {
                entry.setValue(write.localState.map { NSNumber(value: $0) }, forKey: "localState")
            }
            if fields.contains(.payloadHash) {
                entry.setValue(write.payloadHash, forKey: "payloadHash")
            }
            snapshots.append(try syncItemMetadataSnapshot(from: entry))
        }
        return snapshots
    }

    nonisolated static func upsertSyncItemMetadata(
        accountRecordName: String,
        writes: [ICCloudSyncItemMetadataWrite],
        replaceExisting: Bool = true
    ) async throws -> [ICCloudSyncItemMetadataSnapshot] {
        guard !accountRecordName.isEmpty else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale Sync-Metadaten konnte nicht bestimmt werden."
            )
        }
        var latestWriteByRecordName: [String: ICCloudSyncItemMetadataWrite] = [:]
        for write in writes {
            guard !write.category.isEmpty, !write.recordName.isEmpty,
                  !write.itemIdentifier.isEmpty else {
                throw syncItemMetadataStoreError(
                    code: 2,
                    description: "Ein lokaler iCloud-Metadateneintrag ist unvollständig."
                )
            }
            latestWriteByRecordName[write.recordName] = write
        }
        let uniqueWrites = latestWriteByRecordName.values.sorted {
            $0.recordName < $1.recordName
        }
        guard !uniqueWrites.isEmpty else { return [] }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
            )
        }
        if !replaceExisting {
            // Backfill/migration is fill-only. A live user edit can commit after this
            // context fetched but before it saves; the newer store values must win that
            // conflict instead of being replaced by the older page snapshot.
            context.mergePolicy = NSMergePolicy(
                merge: .mergeByPropertyStoreTrumpMergePolicyType
            )
        }

        var persisted: [ICCloudSyncItemMetadataSnapshot] = []
        var index = uniqueWrites.startIndex
        while index < uniqueWrites.endIndex {
            let end = uniqueWrites.index(index,
                                         offsetBy: remoteApplyBatchSize,
                                         limitedBy: uniqueWrites.endIndex) ?? uniqueWrites.endIndex
            let chunk = Array(uniqueWrites[index..<end])
            let snapshots = try await context.perform {
                let recordNames = chunk.map(\.recordName)
                let request = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    recordNames
                )
                request.fetchBatchSize = remoteApplyBatchSize
                var entriesByRecordName: [String: NSManagedObject] = [:]
                for entry in try context.fetch(request) {
                    guard let recordName = entry.value(forKey: "recordName") as? String else {
                        throw syncItemMetadataStoreError(
                            code: 2,
                            description: "Ein lokaler iCloud-Metadateneintrag ist beschädigt."
                        )
                    }
                    entriesByRecordName[recordName] = entry
                }

                var chunkSnapshots: [ICCloudSyncItemMetadataSnapshot] = []
                chunkSnapshots.reserveCapacity(chunk.count)
                for write in chunk {
                    let entry: NSManagedObject
                    if let existing = entriesByRecordName[write.recordName] {
                        entry = existing
                        let storedCategory = existing.value(forKey: "category") as? String
                        let storedIdentifier = existing.value(forKey: "itemIdentifier") as? String
                        guard storedCategory == write.category,
                              storedIdentifier == write.itemIdentifier else {
                            throw syncItemMetadataStoreError(
                                code: 3,
                                description: "Ein lokaler iCloud-Metadateneintrag hat eine widersprüchliche Identität."
                            )
                        }
                    } else {
                        entry = NSEntityDescription.insertNewObject(
                            forEntityName: syncItemMetadataEntityName,
                            into: context
                        )
                        entry.setValue(accountRecordName, forKey: "accountRecordName")
                        entry.setValue(write.category, forKey: "category")
                        entry.setValue(write.recordName, forKey: "recordName")
                        entry.setValue(write.itemIdentifier, forKey: "itemIdentifier")
                        entriesByRecordName[write.recordName] = entry
                    }

                    if replaceExisting {
                        entry.setValue(write.localModifiedAt, forKey: "localModifiedAt")
                    } else if entry.value(forKey: "localModifiedAt") == nil,
                              let localModifiedAt = write.localModifiedAt {
                        entry.setValue(localModifiedAt, forKey: "localModifiedAt")
                    }
                    if replaceExisting {
                        entry.setValue(write.localState.map { NSNumber(value: $0) },
                                       forKey: "localState")
                        entry.setValue(write.payloadHash, forKey: "payloadHash")
                    } else {
                        if entry.value(forKey: "localState") == nil,
                           let localState = write.localState {
                            entry.setValue(NSNumber(value: localState), forKey: "localState")
                        }
                        if entry.value(forKey: "payloadHash") == nil,
                           write.localState != false,
                           let payloadHash = write.payloadHash {
                            entry.setValue(payloadHash, forKey: "payloadHash")
                        }
                    }
                    chunkSnapshots.append(try syncItemMetadataSnapshot(from: entry))
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
                return chunkSnapshots
            }
            persisted.append(contentsOf: snapshots)
            index = end
            if index < uniqueWrites.endIndex {
                await Task.yield()
            }
        }
        return persisted
    }

    nonisolated static func syncItemMetadataByRecordName(
        _ recordNames: Set<String>,
        accountRecordName: String
    ) async throws -> [String: ICCloudSyncItemMetadataSnapshot] {
        guard !accountRecordName.isEmpty else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale Sync-Metadaten konnte nicht bestimmt werden."
            )
        }
        let sortedRecordNames = recordNames.filter { !$0.isEmpty }.sorted()
        guard !sortedRecordNames.isEmpty else { return [:] }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
            )
        }

        var result: [String: ICCloudSyncItemMetadataSnapshot] = [:]
        var index = sortedRecordNames.startIndex
        while index < sortedRecordNames.endIndex {
            let end = sortedRecordNames.index(index,
                                              offsetBy: remoteApplyBatchSize,
                                              limitedBy: sortedRecordNames.endIndex) ?? sortedRecordNames.endIndex
            let chunk = Array(sortedRecordNames[index..<end])
            let snapshots = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    chunk
                )
                request.fetchBatchSize = remoteApplyBatchSize
                let values = try context.fetch(request).map {
                    try syncItemMetadataSnapshot(from: $0)
                }
                context.reset()
                return values
            }
            for snapshot in snapshots {
                result[snapshot.recordName] = snapshot
            }
            index = end
            if index < sortedRecordNames.endIndex {
                await Task.yield()
            }
        }
        return result
    }

    @discardableResult
    nonisolated static func deleteSyncItemMetadata(
        accountRecordName: String? = nil
    ) async throws -> Int {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
            )
        }
        var deletedCount = 0
        while true {
            let deleted = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
                if let accountRecordName {
                    request.predicate = NSPredicate(
                        format: "accountRecordName == %@",
                        accountRecordName
                    )
                }
                request.fetchLimit = remoteApplyBatchSize
                request.fetchBatchSize = remoteApplyBatchSize
                let entries = try context.fetch(request)
                for entry in entries {
                    context.delete(entry)
                }
                if context.hasChanges {
                    try context.save()
                }
                let count = entries.count
                context.reset()
                return count
            }
            deletedCount += deleted
            guard deleted > 0 else { return deletedCount }
            await Task.yield()
        }
    }

    @discardableResult
    nonisolated static func bindSyncItemMetadata(
        from sourceAccountRecordName: String,
        to accountRecordName: String
    ) async throws -> Int {
        guard !sourceAccountRecordName.isEmpty, !accountRecordName.isEmpty else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der iCloud-Account für lokale Sync-Metadaten konnte nicht bestimmt werden."
            )
        }
        guard sourceAccountRecordName != accountRecordName else { return 0 }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
            )
        }
        // Once the verified-account capture gate opens, new edits write directly to the
        // target scope while older pending rows bind in this context. Preserve any target
        // value committed after our fetch; a remaining source row is picked up next loop.
        context.mergePolicy = NSMergePolicy(
            merge: .mergeByPropertyStoreTrumpMergePolicyType
        )

        var boundCount = 0
        while true {
            let bound = try await context.perform {
                let sourceRequest = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
                sourceRequest.predicate = NSPredicate(
                    format: "accountRecordName == %@",
                    sourceAccountRecordName
                )
                sourceRequest.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
                sourceRequest.fetchLimit = remoteApplyBatchSize
                sourceRequest.fetchBatchSize = remoteApplyBatchSize
                let sourceEntries = try context.fetch(sourceRequest)
                guard !sourceEntries.isEmpty else {
                    context.reset()
                    return 0
                }

                let recordNames = try sourceEntries.map { entry -> String in
                    guard let recordName = entry.value(forKey: "recordName") as? String else {
                        throw syncItemMetadataStoreError(
                            code: 2,
                            description: "Ein lokaler iCloud-Metadateneintrag ist beschädigt."
                        )
                    }
                    return recordName
                }
                let targetRequest = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
                targetRequest.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    recordNames
                )
                var targetByRecordName: [String: NSManagedObject] = [:]
                for entry in try context.fetch(targetRequest) {
                    guard let recordName = entry.value(forKey: "recordName") as? String else {
                        throw syncItemMetadataStoreError(
                            code: 2,
                            description: "Ein lokaler iCloud-Metadateneintrag ist beschädigt."
                        )
                    }
                    targetByRecordName[recordName] = entry
                }

                for source in sourceEntries {
                    let sourceSnapshot = try syncItemMetadataSnapshot(from: source)
                    if let target = targetByRecordName[sourceSnapshot.recordName] {
                        let targetSnapshot = try syncItemMetadataSnapshot(from: target)
                        guard targetSnapshot.category == sourceSnapshot.category,
                              targetSnapshot.itemIdentifier == sourceSnapshot.itemIdentifier else {
                            throw syncItemMetadataStoreError(
                                code: 3,
                                description: "Ein lokaler iCloud-Metadateneintrag hat eine widersprüchliche Identität."
                            )
                        }
                        let sourceWins: Bool
                        switch (sourceSnapshot.localModifiedAt, targetSnapshot.localModifiedAt) {
                        case let (sourceDate?, targetDate?):
                            sourceWins = sourceDate.compare(targetDate) != .orderedAscending
                        case (_?, nil), (nil, nil):
                            sourceWins = true
                        case (nil, _?):
                            sourceWins = false
                        }
                        if sourceWins {
                            target.setValue(sourceSnapshot.localModifiedAt, forKey: "localModifiedAt")
                            target.setValue(sourceSnapshot.localState.map { NSNumber(value: $0) },
                                            forKey: "localState")
                            target.setValue(sourceSnapshot.payloadHash, forKey: "payloadHash")
                        }
                        context.delete(source)
                    } else {
                        source.setValue(accountRecordName, forKey: "accountRecordName")
                    }
                }
                if context.hasChanges {
                    try context.save()
                }
                let count = sourceEntries.count
                context.reset()
                return count
            }
            boundCount += bound
            guard bound > 0 else { return boundCount }
            await Task.yield()
        }
    }

    nonisolated static var legacyEpisodeSyncItemMetadataKeys: [String] {
        [episodeLocalModifiedDatesKey]
    }

    nonisolated static var legacySubscriptionSyncItemMetadataKeys: [String] {
        [
            subscriptionRecordURLsKey,
            subscriptionLocalModifiedDatesKey,
            subscriptionLocalStatesKey,
            subscriptionPayloadHashesKey,
        ]
    }

    nonisolated static var allLegacySyncItemMetadataKeys: [String] {
        legacyEpisodeSyncItemMetadataKeys + legacySubscriptionSyncItemMetadataKeys
    }

    nonisolated static func hasLegacyEpisodeSyncItemMetadata() -> Bool {
        legacySyncItemMetadataSourcesExist(keys: legacyEpisodeSyncItemMetadataKeys)
    }

    nonisolated static func hasLegacySubscriptionSyncItemMetadata() -> Bool {
        legacySyncItemMetadataSourcesExist(keys: legacySubscriptionSyncItemMetadataKeys)
    }

    nonisolated static func legacySyncItemMetadataSourcesExist(keys: [String]) -> Bool {
        let defaults = UserDefaults.standard
        return keys.contains { key in
            FileManager.default.fileExists(atPath: syncMetadataFileURL(forKey: key).path)
                || defaults.object(forKey: key) != nil
        }
    }

    nonisolated static func legacySyncItemMetadataWrites() async throws -> (
        writes: [ICCloudSyncItemMetadataWrite],
        sourceKeys: [String]
    )? {
        try await Task.detached(priority: .utility) {
            var sourceKeys: [String] = []

            func readDictionary<Value>(_ key: String, as type: Value.Type) throws -> Value? {
                let fileURL = syncMetadataFileURL(forKey: key)
                let rawValue: Any?
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let data = try Data(contentsOf: fileURL)
                    do {
                        rawValue = try PropertyListSerialization.propertyList(
                            from: data,
                            options: [],
                            format: nil
                        )
                    } catch {
                        throw legacySyncItemMetadataError(underlyingError: error)
                    }
                } else {
                    // The last App-Store build before file-backed metadata can still hold
                    // these dictionaries in UserDefaults. They must be captured before the
                    // generic defaults purge and migrated through the same durable row path.
                    rawValue = UserDefaults.standard.object(forKey: key)
                }
                guard let rawValue else { return nil }
                guard let value = rawValue as? Value else {
                    throw legacySyncItemMetadataError()
                }
                sourceKeys.append(key)
                return value
            }

            let episodeDates = try readDictionary(
                episodeLocalModifiedDatesKey,
                as: [String: TimeInterval].self
            ) ?? [:]
            let subscriptionRecordURLs = try readDictionary(
                subscriptionRecordURLsKey,
                as: [String: String].self
            ) ?? [:]
            let subscriptionDates = try readDictionary(
                subscriptionLocalModifiedDatesKey,
                as: [String: TimeInterval].self
            ) ?? [:]
            let subscriptionStates = try readDictionary(
                subscriptionLocalStatesKey,
                as: [String: Bool].self
            ) ?? [:]
            let subscriptionHashes = try readDictionary(
                subscriptionPayloadHashesKey,
                as: [String: String].self
            ) ?? [:]
            guard !sourceKeys.isEmpty else { return nil }

            var writesByRecordName: [String: ICCloudSyncItemMetadataWrite] = [:]
            for (objectHash, timestamp) in episodeDates {
                guard !objectHash.isEmpty, timestamp.isFinite else {
                    throw legacySyncItemMetadataError()
                }
                let recordName = RecordPrefix.episode + objectHash
                writesByRecordName[recordName] = ICCloudSyncItemMetadataWrite(
                    category: localOutboxEpisodeCategory,
                    recordName: recordName,
                    itemIdentifier: objectHash,
                    localModifiedAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil,
                    localState: nil,
                    payloadHash: nil
                )
            }

            for (recordName, feedURL) in subscriptionRecordURLs {
                guard !recordName.isEmpty, !feedURL.isEmpty else {
                    throw legacySyncItemMetadataError()
                }
                writesByRecordName[recordName] = ICCloudSyncItemMetadataWrite(
                    category: localOutboxSubscriptionCategory,
                    recordName: recordName,
                    itemIdentifier: feedURL,
                    localModifiedAt: nil,
                    localState: nil,
                    payloadHash: nil
                )
            }

            var subscriptionFeedURLs = Set(subscriptionDates.keys)
            subscriptionFeedURLs.formUnion(subscriptionStates.keys)
            subscriptionFeedURLs.formUnion(subscriptionHashes.keys)
            subscriptionFeedURLs.formUnion(subscriptionRecordURLs.values)
            for feedURL in subscriptionFeedURLs {
                guard !feedURL.isEmpty,
                      subscriptionDates[feedURL]?.isFinite != false else {
                    throw legacySyncItemMetadataError()
                }
                let recordName = subscriptionRecordName(forFeedURL: feedURL)
                if let existing = writesByRecordName[recordName],
                   existing.itemIdentifier != feedURL {
                    throw legacySyncItemMetadataError()
                }
                let state = subscriptionStates[feedURL]
                writesByRecordName[recordName] = ICCloudSyncItemMetadataWrite(
                    category: localOutboxSubscriptionCategory,
                    recordName: recordName,
                    itemIdentifier: feedURL,
                    localModifiedAt: subscriptionDates[feedURL].flatMap {
                        $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
                    },
                    localState: state,
                    payloadHash: state == false ? nil : subscriptionHashes[feedURL]
                )
            }

            return (
                writes: writesByRecordName.values.sorted { $0.recordName < $1.recordName },
                sourceKeys: sourceKeys
            )
        }.value
    }

    nonisolated static func removeLegacySyncItemMetadataSources(
        _ sourceKeys: [String]
    ) async throws {
        try await Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            for key in sourceKeys {
                let fileURL = syncMetadataFileURL(forKey: key)
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                defaults.removeObject(forKey: key)
            }
            for key in sourceKeys {
                if FileManager.default.fileExists(atPath: syncMetadataFileURL(forKey: key).path)
                    || defaults.object(forKey: key) != nil {
                    throw syncItemMetadataStoreError(
                        code: 4,
                        description: "Die bisherigen lokalen iCloud-Sync-Metadaten konnten nicht vollständig migriert werden."
                    )
                }
            }
        }.value
    }

    nonisolated static func removeAllLegacySyncItemMetadataSources() async throws {
        try await removeLegacySyncItemMetadataSources(allLegacySyncItemMetadataKeys)
    }

    func migrateLegacySyncItemMetadataIfNeeded(accountRecordName: String) async throws {
        let generation = cloudAccountGeneration
        guard let legacy = try await Self.legacySyncItemMetadataWrites() else { return }
        do {
            _ = try await Self.upsertSyncItemMetadata(
                accountRecordName: accountRecordName,
                writes: legacy.writes,
                replaceExisting: false
            )
        } catch {
            guard Self.isDeterministicSyncItemMetadataMigrationError(error) else {
                throw error
            }
            throw Self.legacySyncItemMetadataError(underlyingError: error)
        }
        guard generation == cloudAccountGeneration,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
        try await Self.removeLegacySyncItemMetadataSources(legacy.sourceKeys)
        guard generation == cloudAccountGeneration,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
    }

    func migrateLegacyKnownRecordSystemFieldsIfNeeded(
        accountRecordName: String
    ) async throws {
        let generation = cloudAccountGeneration
        guard isICloudAccountIdentityVerified,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
        guard let legacy = try await Self.legacyKnownRecordSystemFieldWrites() else { return }
        guard generation == cloudAccountGeneration,
              isICloudAccountIdentityVerified,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
        try await Self.persistKnownRecordSystemFields(
            legacy.records,
            accountRecordName: accountRecordName
        )
        guard generation == cloudAccountGeneration,
              isICloudAccountIdentityVerified,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
        try await Self.removeLegacyKnownRecordSystemFieldFiles(legacy.sourcePaths)
        guard generation == cloudAccountGeneration,
              isICloudAccountIdentityVerified,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
    }

    func subscriptionPayloadHash(for feed: CDFeed) -> String {
        Self.subscriptionPayloadHash(for: feed)
    }

    // Stable fingerprint of the fields that actually go into a synced subscription
    // record (title, rank, parked, credentials, non-internal properties). Excludes
    // refresh-only fields like lastUpdate/etag/contentHash so a feed refresh that only
    // updates those does not look like a change. `nonisolated` so the backfill plan can
    // compute it on its background context.
    nonisolated static func subscriptionPayloadHash(for feed: CDFeed) -> String {
        var components: [String] = [
            feed.title ?? "",
            String(feed.rank),
            feed.parked ? "1" : "0",
            feed.username ?? "",
            feed.password ?? "",
        ]
        var propertyComponents: [String] = []
        for property in feed.properties as? Set<CDFeedProperty> ?? [] {
            guard let key = property.key, !internalFeedPropertyKeys.contains(key) else { continue }
            propertyComponents.append("\(key)\u{1}\(Self.feedPropertyValueType(for: property))\u{1}\(property.boolValue ? 1 : 0)\u{1}\(property.int32Value)\u{1}\(property.doubleValue)\u{1}\(property.stringValue ?? "")")
        }
        components.append(contentsOf: propertyComponents.sorted())
        return Self.sha256Hex(components.joined(separator: "\u{2}"))
    }

    func settingsLocalModifiedDate() -> Date? {
        defaults.object(forKey: Self.settingsLocalModifiedDateKey) as? Date
    }

    func setSettingsLocalModifiedDate(_ date: Date) {
        setSyncMetadata(date, forKey: Self.settingsLocalModifiedDateKey)
    }

    func scrollPositionsLocalModifiedDate() -> Date? {
        defaults.object(forKey: Self.scrollPositionsLocalModifiedDateKey) as? Date
    }

    func setScrollPositionsLocalModifiedDate(_ date: Date) {
        setSyncMetadata(date, forKey: Self.scrollPositionsLocalModifiedDateKey)
    }

    func deviceRecordID(for deviceID: String) -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.device + deviceID, zoneID: zoneID)
    }

    func episodeRecordID(forObjectHash objectHash: String) -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.episode + objectHash, zoneID: zoneID)
    }

    func subscriptionRecordID(forFeedURL feedURL: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.subscriptionRecordName(forFeedURL: feedURL), zoneID: zoneID)
    }

    func subscriptionTombstoneRecordID(forFeedURL feedURL: String) -> CKRecord.ID {
        CKRecord.ID(recordName: Self.subscriptionTombstoneRecordName(forFeedURL: feedURL), zoneID: zoneID)
    }

    func appSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.appSettings, zoneID: zoneID)
    }

    func listScrollPositionsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.listScrollPositions, zoneID: zoneID)
    }

    func subscriptionListSettingsRecordID() -> CKRecord.ID {
        CKRecord.ID(recordName: RecordPrefix.subscriptionListSettings, zoneID: zoneID)
    }

    nonisolated static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func refreshAccountStatus() async {
        if let accountVerificationTask {
            await accountVerificationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAccountStatusRefresh()
            self.accountVerificationTask = nil
        }
        accountVerificationTask = task
        await task.value
    }

    func performAccountStatusRefresh() async {
        await cancelAndAwaitLowPrioritySync()
        if let activeManualSyncTask = manualSyncTask {
            await activeManualSyncTask.value
        }
        if let activeBackgroundSyncTask = backgroundSyncTask {
            await activeBackgroundSyncTask.value
        }
        await awaitFinalDeviceRecordUpdate()
        let transitionToken = await acquireICloudAccountTransition()
        defer { releaseICloudAccountTransition() }
        guard !Task.isCancelled else { return }
        setICloudAccountIdentityVerified(false)
        let generation = cloudAccountGeneration
        do {
            let status = try await container.accountStatus()
            guard generation == cloudAccountGeneration else { return }
            switch status {
            case .available:
                guard try await reconcileAvailableICloudAccount() else { return }
                clearError()
                if hasInitialUploadBackfillWork {
                    setStatus(backfillProgressStatusText())
                } else if !syncInProgress, defaults.string(forKey: Self.lastErrorKey) == nil {
                    setStatus(anySyncEnabled ? NSLocalizedString("Bereit", comment: "") : NSLocalizedString("Aus", comment: ""))
                }
            case .noAccount:
                lastForegroundSyncDate = nil
                if !isICloudAccountSignedOut {
                    setICloudAccountSignedOut(true)
                    resetForICloudAccountTransition(reinitializeEngine: false)
                }
                setBlockingStatus(NSLocalizedString("Kein iCloud-Account verfügbar. Melde dich in den Systemeinstellungen bei iCloud an.", comment: ""))
            case .restricted:
                lastForegroundSyncDate = nil
                setBlockingStatus(NSLocalizedString("InstacastPlus darf iCloud auf diesem Gerät nicht verwenden. Prüfe die iCloud- und Bildschirmzeit-Einstellungen.", comment: ""))
            case .couldNotDetermine:
                lastForegroundSyncDate = nil
                setBlockingStatus(NSLocalizedString("Der iCloud-Status konnte nicht ermittelt werden. Prüfe deine Verbindung und versuche es erneut.", comment: ""))
                scheduleSyncRetryAfterFailure(code: .networkUnavailable, reason: "accountStatus")
            case .temporarilyUnavailable:
                lastForegroundSyncDate = nil
                setBlockingStatus(NSLocalizedString("iCloud ist vorübergehend nicht erreichbar. Die Synchronisation wird automatisch fortgesetzt.", comment: ""))
                scheduleSyncRetryAfterFailure(code: .serviceUnavailable, reason: "accountStatus")
            @unknown default:
                lastForegroundSyncDate = nil
                setBlockingStatus(NSLocalizedString("Der iCloud-Status konnte nicht ermittelt werden. Prüfe deine Verbindung und versuche es erneut.", comment: ""))
                scheduleSyncRetryAfterFailure(code: .networkUnavailable, reason: "accountStatus")
            }
        } catch {
            guard transitionToken == iCloudAccountTransitionToken else { return }
            lastForegroundSyncDate = nil
            setError(error)
            scheduleSyncRetryAfterFailure(error: error, reason: "accountStatus")
        }
    }

    func markSyncCompleted() {
        // A send finishing while the fetch-apply loop is still running must not flip the
        // status to "complete" and wipe the download progress (that was the per-second
        // status flicker). The fetch path calls this again when it actually finishes.
        guard !isApplyingRemoteChange else {
            postStateChanged()
            return
        }
        guard verifyNoExpectedUserDataWasSkippedBeforeCompleting() else { return }
        clearSyncActivity()
        if syncedUserDataInCurrentRun {
            let now = Date()
            setSyncMetadata(now, forKey: Self.lastSyncDateKey)
            var payload = localDevicePayload()
            payload["lastSyncDate"] = now
            updateDeviceCache(with: payload)
            postDevicesChanged()
        }
        clearError()
        resetSyncRetryBackoff()
        deviceRecordShouldStampSyncDate = false
        setSyncMetadata(false, forKey: Self.deviceRecordShouldStampSyncDateKey)
        var completionMetadata = syncDiagnosticsMetadata()
        completionMetadata["requestedCloudInventoryRefresh"] = requestedCloudInventoryRefreshReason != nil
        logSyncEvent("iCloud Sync abgeschlossen", metadata: completionMetadata)
        if hasInitialUploadBackfillWork {
            // The backfill continues page by page — keep showing upload progress instead
            // of flipping to "complete" and back once per page.
            setStatus(backfillProgressStatusText())
            postStateChanged()
            scheduleCurrentEnabledDataForUpload()
        } else {
            setStatus(NSLocalizedString("Synchronisation vollständig", comment: ""))
            postStateChanged()
            runRequestedCloudInventoryRefresh()
            pruneEpisodeLocalModifiedDatesIfNeeded()
        }
        syncedUserDataInCurrentRun = false
    }

    func verifyNoExpectedUserDataWasSkippedBeforeCompleting() -> Bool {
        let pendingEpisodes = pendingInitialUploadBatches.reduce(0) { $0 + $1.episodeRecordNames.count }
        let pendingSubscriptions = pendingInitialUploadBatches.reduce(0) { $0 + $1.subscriptionRecordNames.count }
        if pendingEpisodes > 0 || pendingSubscriptions > 0 {
            blockCompletionAndRequeue(reason: "pendingInitialUploadBatchesNotSaved", metadata: [
                "pendingInitialUploadPages": pendingInitialUploadBatches.count,
                "pendingInitialEpisodeRecords": pendingEpisodes,
                "pendingInitialSubscriptionRecords": pendingSubscriptions,
            ])
            return false
        }
        return true
    }

    func blockCompletionAndRequeue(reason: String, metadata: [String: Any]) {
        clearSyncActivity()
        var details = metadata
        details["reason"] = reason
        details.merge(syncDiagnosticsMetadata()) { current, _ in current }
        logSyncEvent("iCloud Sync Abschluss blockiert", metadata: details)
        setStatus(recoveryProgressStatusText())
        scheduleCurrentEnabledDataForUpload()
        postStateChanged()
    }

    func recoveryProgressStatusText() -> String {
        if hasInitialUploadBackfillWork {
            return backfillProgressStatusText()
        }
        return NSLocalizedString("Prüft, ob alle Daten auf iCloud angekommen sind…", comment: "")
    }

    func backfillProgressStatusText() -> String {
        let counts = syncCounts
        let uploadsEpisodes = episodesSyncEnabled && defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) != nil
        let uploadsSubscriptions = subscriptionsSyncEnabled && defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) != nil
        if uploadsEpisodes, !uploadsSubscriptions, counts.episodesTotal > 0 {
            let format = NSLocalizedString("Lädt Episodenstatus hoch… %ld / %ld", comment: "")
            return String(format: format, counts.episodesSynced, counts.episodesTotal)
        }
        if uploadsSubscriptions, !uploadsEpisodes, counts.subscriptionsTotal > 0 {
            let format = NSLocalizedString("Lädt Abonnements hoch… %ld / %ld", comment: "")
            return String(format: format, counts.subscriptionsSynced, counts.subscriptionsTotal)
        }
        let synced = (uploadsEpisodes ? counts.episodesSynced : 0) + (uploadsSubscriptions ? counts.subscriptionsSynced : 0)
        let total = (uploadsEpisodes ? counts.episodesTotal : 0) + (uploadsSubscriptions ? counts.subscriptionsTotal : 0)
        if total > 0 {
            let format = NSLocalizedString("Lädt Daten hoch… %ld / %ld", comment: "")
            return String(format: format, synced, total)
        }
        return NSLocalizedString("Synchronisation läuft, lädt hoch…", comment: "")
    }

    // Once per session, after a fully completed sync: drop modified-date entries whose
    // episode no longer exists locally (unsubscribed/removed feeds) — the map otherwise
    // grows without bound. If an episode is inserted while the background snapshot is
    // taken, its entry may be dropped once too early; that is benign, the next state
    // change simply re-records it.
    func pruneEpisodeLocalModifiedDatesIfNeeded() {
        guard !didPruneEpisodeLocalModifiedDates, episodesSyncEnabled,
              !hasInitialUploadBackfillWork,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else { return }
        didPruneEpisodeLocalModifiedDates = true
        let generation = cloudAccountGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let existingHashes = await Self.allLocalEpisodeObjectHashes()
            // An empty set means the lookup failed (or the library is empty) — better to
            // skip pruning than to wipe every sync timestamp.
            guard !existingHashes.isEmpty else { return }
            do {
                let result = try await Self.pruneEpisodeSyncItemMetadata(
                    accountRecordName: accountRecordName,
                    existingObjectHashes: existingHashes
                )
                guard generation == self.cloudAccountGeneration,
                      self.defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      result.removed > 0 else { return }
                self.logSyncEvent("Episode-Sync-Metadaten bereinigt", metadata: [
                    "removed": result.removed,
                    "remaining": result.remaining,
                ])
            } catch {
                guard generation == self.cloudAccountGeneration else { return }
                self.handleLocalPersistenceFailure(error)
            }
        }
    }

    nonisolated static func pruneEpisodeSyncItemMetadata(
        accountRecordName: String,
        existingObjectHashes: Set<String>
    ) async throws -> (removed: Int, remaining: Int) {
        guard !accountRecordName.isEmpty,
              let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
            )
        }
        var cursor: String?
        var removed = 0
        while true {
            let currentCursor = cursor
            let result = try await context.perform { () -> (lastRecordName: String?, removed: Int) in
                let request = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
                var predicates: [NSPredicate] = [
                    NSPredicate(format: "accountRecordName == %@", accountRecordName),
                    NSPredicate(format: "category == %@", localOutboxEpisodeCategory),
                ]
                if let currentCursor {
                    predicates.append(NSPredicate(format: "recordName > %@", currentCursor))
                }
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
                request.fetchLimit = remoteApplyBatchSize
                request.fetchBatchSize = remoteApplyBatchSize
                let entries = try context.fetch(request)
                let lastRecordName = entries.last?.value(forKey: "recordName") as? String
                var removedInChunk = 0
                for entry in entries {
                    let snapshot = try syncItemMetadataSnapshot(from: entry)
                    if !existingObjectHashes.contains(snapshot.itemIdentifier) {
                        context.delete(entry)
                        removedInChunk += 1
                    }
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
                return (lastRecordName, removedInChunk)
            }
            removed += result.removed
            guard let lastRecordName = result.lastRecordName else { break }
            cursor = lastRecordName
            await Task.yield()
        }
        let remaining = try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "accountRecordName == %@", accountRecordName),
                NSPredicate(format: "category == %@", localOutboxEpisodeCategory),
            ])
            return try context.count(for: request)
        }
        return (removed, remaining)
    }

    nonisolated static func allLocalEpisodeObjectHashes() async -> Set<String> {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else { return [] }
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Episode")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.propertiesToFetch = ["objectHash"]
            request.predicate = NSPredicate(format: "objectHash != nil")
            let rows = (try? context.fetch(request)) ?? []
            return Set(rows.compactMap { $0["objectHash"] as? String })
        }
    }

    var hasPendingSyncChanges: Bool {
        guard let syncEngine else { return false }
        if !syncEngine.state.pendingDatabaseChanges.isEmpty {
            return true
        }
        let snapshot = Self.syncEngineCallbackSnapshot()
        return syncEngine.state.pendingRecordZoneChanges.contains {
            Self.pendingChangeIsEnabled($0, snapshot: snapshot)
        }
    }

    func syncDiagnosticsMetadata() -> [String: Any] {
        let inventory = cloudInventory
        var metadata: [String: Any] = [
            "pendingDatabaseChanges": syncEngine?.state.pendingDatabaseChanges.count ?? 0,
            "pendingRecordZoneChanges": syncEngine?.state.pendingRecordZoneChanges.count ?? 0,
            "hasInitialUploadBackfillWork": hasInitialUploadBackfillWork,
            "episodeBackfillOffset": (defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
            "subscriptionBackfillOffset": (defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
            "initialSettingsBackfillPending": defaults.bool(forKey: Self.initialSettingsBackfillPendingKey),
            "syncedUserDataInCurrentRun": syncedUserDataInCurrentRun,
            "hasUnresolvedSyncFailures": hasUnresolvedSyncFailures,
            "syncRetryAttempt": syncRetryAttempt,
            "syncRetryScheduled": syncRetryWorkItem != nil,
            "isFetchingCloudInventory": isFetchingCloudInventory,
            "pendingCloudInventoryRefreshReason": pendingCloudInventoryRefreshReason ?? "",
            "cloudInventoryEpisodeStates": inventory?.episodeStates ?? -1,
            "cloudInventorySubscriptions": inventory?.subscriptions ?? -1,
            "cloudInventorySettings": inventory?.settings ?? -1,
        ]
        if let fetchDate = inventory?.fetchDate {
            metadata["cloudInventoryFetchDate"] = fetchDate
        }
        return metadata
    }

    func beginSyncActivity(_ direction: SyncActivityDirection) {
        if syncActivityDirection != direction {
            syncActivityDirection = direction
            syncActivityStartDate = Date()
            syncActivityRecordCount = 0
            syncActivityExpectedCount = 0
        }
    }

    @discardableResult
    func beginSyncCycle() -> Int {
        let generation = cloudAccountGeneration
        activeSyncCycleCounts[generation, default: 0] += 1
        return generation
    }

    func endSyncCycle(_ generation: Int) {
        let remaining = max(0, (activeSyncCycleCounts[generation] ?? 0) - 1)
        if remaining == 0 {
            activeSyncCycleCounts.removeValue(forKey: generation)
        } else {
            activeSyncCycleCounts[generation] = remaining
        }
        postStateChanged()
    }

    func recordSyncActivity(_ count: Int) {
        guard count > 0 else { return }
        syncActivityRecordCount += count
    }

    func clearSyncActivity() {
        syncActivityDirection = nil
        syncActivityStartDate = nil
        syncActivityRecordCount = 0
        syncActivityExpectedCount = 0
        syncActivityKindLabel = nil
    }

    nonisolated static func activityKindLabel(forRecordType recordType: String) -> String? {
        switch recordType {
        case RecordKind.episodeState:
            return NSLocalizedString("Episodes", comment: "")
        case RecordKind.subscription, RecordKind.subscriptionTombstone:
            return NSLocalizedString("Subscriptions", comment: "")
        case RecordKind.appSettings, RecordKind.listScrollPositions:
            return NSLocalizedString("Settings", comment: "")
        default:
            return nil
        }
    }

    // "Lädt herunter… 6/51" when the total is known (fetch events report it up front),
    // otherwise a throughput estimate ("12/s").
    func syncActivityStatusText() -> String? {
        guard let direction = syncActivityDirection else { return nil }
        let base: String
        switch direction {
        case .up:
            base = NSLocalizedString("Synchronisation läuft, lädt hoch…", comment: "")
        case .down:
            base = NSLocalizedString("Synchronisation läuft, lädt herunter…", comment: "")
        case .verifying:
            base = NSLocalizedString("Prüft hochgeladene Daten…", comment: "")
        }
        if syncActivityExpectedCount > 0 {
            if let kind = syncActivityKindLabel {
                return String(format: NSLocalizedString("%@ %ld/%ld %@", comment: ""), base, syncActivityRecordCount, syncActivityExpectedCount, kind)
            }
            return String(format: NSLocalizedString("%@ %ld/%ld", comment: ""), base, syncActivityRecordCount, syncActivityExpectedCount)
        }
        if let start = syncActivityStartDate, syncActivityRecordCount > 0 {
            let elapsed = max(Date().timeIntervalSince(start), 0.001)
            let rate = Int((Double(syncActivityRecordCount) / elapsed).rounded())
            if rate > 0 {
                return String(format: NSLocalizedString("%@ %ld/s", comment: ""), base, rate)
            }
        }
        // An activity that hasn't moved a single record (e.g. the empty fetch pass of
        // every sync run) shows nothing — flashing "lädt herunter…" although iCloud
        // was empty confused more than it informed.
        return nil
    }

    func markSyncCompletedIfFinished(allowActiveSyncCycle: Bool = false) {
        let isOnlyActiveCycle = allowActiveSyncCycle
            ? activeSyncCycleCount == 1
            : activeSyncCycleCount == 0
        guard isOnlyActiveCycle else {
            postStateChanged()
            return
        }
        guard !hasUnresolvedSyncFailures else {
            postStateChanged()
            return
        }
        guard !hasPendingInitialSettingsChoice else {
            clearSyncActivity()
            setStatus(NSLocalizedString("Choose which iCloud settings should be used.", comment: ""))
            postStateChanged()
            return
        }
        guard !hasPendingSyncChanges else {
            postStateChanged()
            return
        }
        markSyncCompleted()
    }

    func setStatus(_ status: String) {
        clearError()
        setSyncMetadata(status, forKey: Self.lastStatusKey)
    }

    func setBlockingStatus(_ status: String) {
        hasUnresolvedSyncFailures = true
        clearSyncActivity()
        setSyncMetadata(status, forKey: Self.lastErrorKey)
        postStateChanged()
    }

    func setError(_ error: Error) {
        clearSyncActivity()
        deviceRecordShouldStampSyncDate = false
        setSyncMetadata(false, forKey: Self.deviceRecordShouldStampSyncDateKey)
        syncedUserDataInCurrentRun = false
        let status = displayStatus(for: error)
        let nsError = error as NSError
        var metadata = cloudKitErrorMetadata(error)
        metadata["domain"] = nsError.domain
        metadata["code"] = nsError.code
        metadata["status"] = status
        metadata.merge(syncDiagnosticsMetadata()) { current, _ in current }
        logSyncEvent("iCloud Sync Fehler", metadata: metadata)
        setSyncMetadata(status, forKey: Self.lastErrorKey)
        postStateChanged()
    }

    func cloudKitErrorMetadata(_ error: Error) -> [String: Any] {
        let nsError = error as NSError
        var metadata: [String: Any] = [
            "domain": nsError.domain,
            "code": nsError.code,
            "description": nsError.localizedDescription,
        ]
        if let ckError = error as? CKError {
            metadata["ckCode"] = ckError.code.rawValue
            if let retryAfterSeconds = ckError.retryAfterSeconds {
                metadata["retryAfterSeconds"] = Int(retryAfterSeconds.rounded(.up))
            }
            if let partialErrors = ckError.partialErrorsByItemID, !partialErrors.isEmpty {
                metadata["partialErrorCount"] = partialErrors.count
            }
        }
        return metadata
    }

    func displayStatus(for error: Error) -> String {
        if Self.isDeterministicLegacySyncItemMetadataError(error) {
            return (error as NSError).localizedDescription
        }
        if (error as NSError).domain == "ICiCloudSyncLocalPersistence" {
            return NSLocalizedString("Die synchronisierten Änderungen konnten auf diesem Gerät nicht lokal gespeichert werden. Prüfe den freien Speicherplatz und versuche es erneut.", comment: "")
        }
        if (error as NSError).domain == "ICiCloudSyncLocalRead" {
            return NSLocalizedString("Die lokalen Daten konnten nicht für iCloud gelesen werden. Die Synchronisation wird automatisch erneut versucht.", comment: "")
        }
        if let ckError = error as? CKError {
            if ckError.code == .partialFailure,
               let nestedError = ckError.partialErrorsByItemID?.values.compactMap({ $0 as? CKError }).first {
                return displayStatus(for: nestedError)
            }
            switch ckError.code {
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
                return NSLocalizedString("iCloud ist vorübergehend nicht erreichbar. Die Synchronisation wird automatisch fortgesetzt.", comment: "")
            case .notAuthenticated:
                return NSLocalizedString("Kein iCloud-Account verfügbar. Melde dich in den Systemeinstellungen bei iCloud an.", comment: "")
            case .permissionFailure:
                return NSLocalizedString("InstacastPlus darf iCloud auf diesem Gerät nicht verwenden. Prüfe die iCloud- und Bildschirmzeit-Einstellungen.", comment: "")
            case .quotaExceeded:
                return NSLocalizedString("Dein iCloud-Speicher ist voll. Gib Speicher frei und starte die Synchronisation erneut.", comment: "")
            case .limitExceeded:
                return NSLocalizedString("iCloud hat zu viele Änderungen auf einmal abgelehnt. Die Synchronisation wird automatisch erneut versucht.", comment: "")
            default:
                if Self.isTransientCloudKitError(ckError) {
                    return NSLocalizedString("iCloud hat die Synchronisation unterbrochen. Sie wird automatisch fortgesetzt.", comment: "")
                }
            }
        }

        let description = (error as NSError).localizedDescription.lowercased()
        if description.contains("request contains") && description.contains("maximum number") {
            return NSLocalizedString("iCloud hat zu viele Änderungen auf einmal abgelehnt. Die Synchronisation wird automatisch erneut versucht.", comment: "")
        }
        return NSLocalizedString("iCloud konnte die Synchronisation nicht abschließen. Tippe auf „Jetzt synchronisieren“, um es erneut zu versuchen.", comment: "")
    }

    func clearError() {
        setSyncMetadata(nil, forKey: Self.lastErrorKey)
    }

    nonisolated static func isFileBackedSyncMetadataKey(_ key: String) -> Bool {
        fileBackedSyncMetadataKeys.contains(key)
    }

    nonisolated static func syncMetadataDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = baseURL.appendingPathComponent(syncMetadataDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var excludedURL = directoryURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedURL.setResourceValues(resourceValues)
        return directoryURL
    }

    nonisolated static func syncMetadataFileURL(forKey key: String) -> URL {
        syncMetadataDirectoryURL().appendingPathComponent(key).appendingPathExtension("plist")
    }

    nonisolated static func legacyKnownRecordSystemFieldsDirectoryURL() -> URL {
        syncMetadataDirectoryURL().appendingPathComponent(
            legacyKnownRecordSystemFieldsDirectoryName,
            isDirectory: true
        )
    }

    nonisolated static func legacyKnownRecordSystemFieldWrites()
        async throws -> ICCloudLegacyKnownRecordSystemFieldsBatch? {
        try await Task.detached(priority: .utility) {
            let directoryURL = legacyKnownRecordSystemFieldsDirectoryURL()
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
                return nil
            }
            guard isDirectory.boolValue else {
                throw legacySyncItemMetadataError()
            }
            let directoryEntries = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for entryURL in directoryEntries {
                let values = try entryURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true, entryURL.pathExtension == "record" else {
                    throw legacySyncItemMetadataError()
                }
            }
            let sourceURLs = directoryEntries.sorted { $0.path < $1.path }
            guard !sourceURLs.isEmpty else { return nil }

            var records: [CKRecord] = []
            var sourcePaths: [String] = []
            var recordNames = Set<String>()
            records.reserveCapacity(sourceURLs.count)
            sourcePaths.reserveCapacity(sourceURLs.count)
            for sourceURL in sourceURLs {
                let data = try Data(contentsOf: sourceURL)
                let record: CKRecord
                do {
                    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
                    unarchiver.requiresSecureCoding = true
                    defer { unarchiver.finishDecoding() }
                    guard let decodedRecord = CKRecord(coder: unarchiver) else {
                        throw legacySyncItemMetadataError()
                    }
                    record = decodedRecord
                } catch let error as NSError where error.domain == legacySyncItemMetadataErrorDomain {
                    throw error
                } catch {
                    throw legacySyncItemMetadataError(underlyingError: error)
                }
                let recordName = record.recordID.recordName
                guard !recordName.isEmpty,
                      sourceURL.deletingPathExtension().lastPathComponent == sha256Hex(recordName),
                      recordNames.insert(recordName).inserted else {
                    throw legacySyncItemMetadataError()
                }
                records.append(record)
                sourcePaths.append(sourceURL.path)
            }
            return ICCloudLegacyKnownRecordSystemFieldsBatch(
                records: records,
                sourcePaths: sourcePaths
            )
        }.value
    }

    nonisolated static func removeLegacyKnownRecordSystemFieldFiles(
        _ expectedSourcePaths: [String]
    ) async throws {
        try await Task.detached(priority: .utility) {
            guard !expectedSourcePaths.isEmpty else { return }
            let directoryURL = legacyKnownRecordSystemFieldsDirectoryURL()
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            let currentSourcePaths = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).map(\.path).sorted()
            guard currentSourcePaths == expectedSourcePaths.sorted() else {
                throw knownRecordSystemFieldsStoreError(
                    code: 3,
                    description: "Die bisherigen lokalen CloudKit-Systemfelder haben sich während der Migration geändert."
                )
            }
            try fileManager.removeItem(at: directoryURL)
            if fileManager.fileExists(atPath: directoryURL.path) {
                throw knownRecordSystemFieldsStoreError(
                    code: 4,
                    description: "Die bisherigen lokalen CloudKit-Systemfelder konnten nicht vollständig migriert werden."
                )
            }
        }.value
    }

    nonisolated static func removeAllLegacyKnownRecordSystemFieldFiles() async throws {
        try await Task.detached(priority: .utility) {
            let directoryURL = legacyKnownRecordSystemFieldsDirectoryURL()
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: directoryURL.path) else { return }
            try fileManager.removeItem(at: directoryURL)
        }.value
    }

    @objc nonisolated static func purgeLegacyDefaultsBackedSyncMetadata() {
        let defaults = UserDefaults.standard
        // These keys now live in files; removing only their obsolete defaults copies is
        // safe on every launch. Initial backfill cursors and the settings fetch gate still
        // live in UserDefaults and are active resumable state, so they must survive launch.
        for key in fileBackedSyncMetadataKeys {
            defaults.removeObject(forKey: key)
        }
        removeSyncMetadataValue(forKey: knownRecordsKey)
    }

    nonisolated static func syncMetadataValue(forKey key: String) -> Any? {
        if key == knownRecordsKey {
            return nil
        }
        if isFileBackedSyncMetadataKey(key) {
            let url = syncMetadataFileURL(forKey: key)
            if let data = try? Data(contentsOf: url),
               let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
                return value
            }
            return nil
        }
        return UserDefaults.standard.object(forKey: key)
    }

    nonisolated static func writeSyncMetadataValue(_ value: Any, forKey key: String) throws -> Int {
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        try data.write(to: syncMetadataFileURL(forKey: key), options: .atomic)
        return data.count
    }

    nonisolated static func removeSyncMetadataValue(forKey key: String) {
        try? FileManager.default.removeItem(at: syncMetadataFileURL(forKey: key))
    }

    nonisolated static func syncMetadataSummary(for value: Any?) -> [String: String] {
        guard let value else { return ["valueType": "nil"] }

        var summary: [String: String] = ["valueType": String(describing: type(of: value))]
        if let data = value as? Data {
            summary["valueBytes"] = "\(data.count)"
        } else if let data = value as? NSData {
            summary["valueBytes"] = "\(data.length)"
        } else if let dictionary = value as? NSDictionary {
            summary["entryCount"] = "\(dictionary.count)"
        } else if let array = value as? NSArray {
            summary["entryCount"] = "\(array.count)"
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
            summary["plistBytes"] = "\(data.count)"
        }
        return summary
    }

    nonisolated static func syncMetadataStorageSnapshot(reason: String) -> [String: String] {
        var metadata: [String: String] = [
            "reason": reason,
            "isMainThread": Thread.isMainThread ? "1" : "0",
            "threadID": "\(pthread_mach_thread_np(pthread_self()))",
        ]

        let fileManager = FileManager.default
        for key in fileBackedSyncMetadataKeys.sorted() {
            let fileURL = syncMetadataFileURL(forKey: key)
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let fileSize = attributes[.size] as? NSNumber {
                metadata["file.\(key).bytes"] = "\(fileSize.intValue)"
            } else {
                metadata["file.\(key).bytes"] = "0"
            }
        }

        if let context = DatabaseManager.shared()?.newBackgroundContext() {
            let knownRecordCount = context.performAndWait {
                let request = NSFetchRequest<NSManagedObject>(entityName: knownRecordSystemFieldsEntityName)
                request.includesSubentities = false
                return (try? context.count(for: request)) ?? -1
            }
            metadata["knownRecords.rowCount"] = "\(knownRecordCount)"
        }
        let legacyDirectory = legacyKnownRecordSystemFieldsDirectoryURL()
        let legacyFiles = (try? fileManager.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        metadata["knownRecords.legacyFileCount"] = "\(legacyFiles.count)"

        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var encodedSizes: [(key: String, bytes: Int)] = []
        for (key, value) in domain {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else { continue }
            encodedSizes.append((key: key, bytes: data.count))
            if fileBackedSyncMetadataKeys.contains(key) || nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key) || key.hasPrefix("ICiCloudSync") {
                metadata["defaults.\(key).bytes"] = "\(data.count)"
            }
        }

        metadata["defaults.keyCount"] = "\(domain.count)"
        metadata["defaults.totalEncodedBytes"] = "\(encodedSizes.reduce(0) { $0 + $1.bytes })"
        for (index, entry) in encodedSizes.sorted(by: { $0.bytes > $1.bytes }).prefix(12).enumerated() {
            metadata["defaults.top\(index + 1)"] = "\(entry.key):\(entry.bytes)"
        }
        return metadata
    }

    func logSyncMetadataDiagnostic(operation: String, key: String, storage: String, bytes: Int?, value: Any?, error: Error? = nil) {
        var metadata = Self.syncMetadataSummary(for: value)
        metadata["operation"] = operation
        metadata["key"] = key
        metadata["storage"] = storage
        metadata["isMainThread"] = Thread.isMainThread ? "1" : "0"
        metadata["threadID"] = "\(pthread_mach_thread_np(pthread_self()))"
        if let bytes {
            metadata["bytes"] = "\(bytes)"
        }
        if let error {
            metadata["error"] = String(describing: error)
        }
        ICDiagnosticLogger.shared.logEvent("icloud-sync-metadata",
                                           message: "iCloud-Sync-Metadaten \(operation)",
                                           metadata: metadata as NSDictionary)
    }

    func setSyncMetadata(_ value: Any?, forKey key: String) {
        // No per-write logging here: metadata writes are far too frequent to log each one
        // (this once flooded the diagnostics log to 26 MB). Only genuine write failures are
        // logged, which are the actionable cases.
        isWritingSyncMetadata = true
        if Self.isFileBackedSyncMetadataKey(key) {
            if let value {
                do {
                    _ = try Self.writeSyncMetadataValue(value, forKey: key)
                    defaults.removeObject(forKey: key)
                } catch {
                    logSyncMetadataDiagnostic(operation: "write-failed", key: key, storage: "file", bytes: nil, value: value, error: error)
                }
            } else {
                Self.removeSyncMetadataValue(forKey: key)
                defaults.removeObject(forKey: key)
            }
        } else if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        isWritingSyncMetadata = false
    }

    func postStateChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncStateDidChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncStateDidChange, object: self)
            }
        }
    }

    func postDevicesChanged() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncDevicesDidChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name.ICiCloudSyncDevicesDidChange, object: self)
            }
        }
    }
}

private protocol OptionalProtocol {
    var isNil: Bool { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
}
