//
//  ICiCloudSyncManager+RemoteApply.swift
//  Instacast
//
//  Fetched-event handling and applying remote records to the local model.
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Foundation
import UIKit

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    struct EpisodeClockUpdate {
        let objectHash: String
        let date: Date
    }

    struct PendingSubscriptionChange {
        let feedURL: String
        let recordName: String
        let payload: [String: Any]
        let snapshots: [ICCloudPendingSubscriptionStateSnapshot]
        let isTombstone: Bool
        let isLegacyDeletion: Bool
    }

    struct FetchedModificationBatchResult {
        let records: [CKRecord]
        let appliedEpisodeStates: [ICCloudPendingEpisodeStateSnapshot]
    }

    struct LocalOutboxResolutionCommit {
        let revisionsToDelete: [String: String]
        let revisionsToAcknowledge: [String: String]
        let revisionsToRearm: [String: String]
        let completedRecordNames: Set<String>

        static let empty = LocalOutboxResolutionCommit(
            revisionsToDelete: [:],
            revisionsToAcknowledge: [:],
            revisionsToRearm: [:],
            completedRecordNames: []
        )
    }

    enum RemoteOutboxDecision {
        case applyRemote(discardedLocalMutation: Bool)
        case keepLocal
    }

    func pendingEpisodeStateWrites(
        in batch: ArraySlice<CKDatabase.RecordZoneChange.Modification>
    ) throws -> [ICCloudPendingEpisodeStateWrite] {
        try batch.compactMap { modification in
            let record = modification.record
            guard record.recordType == RecordKind.episodeState,
                  let payload = payloadDictionary(from: record) else { return nil }
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .binary,
                options: 0
            )
            return ICCloudPendingEpisodeStateWrite(recordName: record.recordID.recordName,
                                                   payloadData: data)
        }
    }

    func pendingSubscriptionStateWrites(
        in batch: ArraySlice<CKDatabase.RecordZoneChange.Modification>
    ) throws -> [ICCloudPendingSubscriptionStateWrite] {
        try batch.compactMap { modification in
            let record = modification.record
            guard record.recordType == RecordKind.subscription
                    || record.recordType == RecordKind.subscriptionTombstone
                    || record.recordType == RecordKind.subscriptionListSettings,
                  let payload = payloadDictionary(from: record) else { return nil }
            let data = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .binary,
                options: 0
            )
            return ICCloudPendingSubscriptionStateWrite(
                recordName: record.recordID.recordName,
                payloadData: data
            )
        }
    }

    func pendingSubscriptionDeletionStateWrites(
        in batch: ArraySlice<CKDatabase.RecordZoneChange.Deletion>,
        metadataBatch: ICCloudSyncItemMetadataContextBatch
    ) throws -> [ICCloudPendingSubscriptionStateWrite] {
        try batch.compactMap { deletion in
            guard deletion.recordType == RecordKind.subscription else { return nil }
            let recordName = deletion.recordID.recordName
            guard let metadata = try Self.syncItemMetadataSnapshot(
                forRecordName: recordName,
                metadataBatch: metadataBatch
            ) else { return nil }
            guard metadata.category == Self.localOutboxSubscriptionCategory,
                  Self.subscriptionRecordName(forFeedURL: metadata.itemIdentifier) == recordName else {
                throw Self.syncItemMetadataStoreError(
                    code: 3,
                    description: "Ein gelöschtes iCloud-Abonnement hat eine widersprüchliche Identität."
                )
            }
            let data = try PropertyListSerialization.data(
                fromPropertyList: [
                    "feedURL": metadata.itemIdentifier,
                    "legacyPhysicalDelete": true,
                ],
                format: .binary,
                options: 0
            )
            return ICCloudPendingSubscriptionStateWrite(
                recordName: recordName,
                payloadData: data
            )
        }
    }

    nonisolated static func stagePendingEpisodeStates(
        accountRecordName: String,
        writes: [ICCloudPendingEpisodeStateWrite],
        replaceExisting: Bool = true
    ) async throws -> [ICCloudPendingEpisodeStateSnapshot] {
        guard !writes.isEmpty else { return [] }
        guard !accountRecordName.isEmpty,
              let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingEpisodeStateStoreError(code: 1,
                                                description: "Der lokale iCloud-Episodenstatusspeicher konnte nicht geöffnet werden.")
        }

        var latestDataByRecordName: [String: Data] = [:]
        for write in writes where !write.recordName.isEmpty {
            latestDataByRecordName[write.recordName] = write.payloadData
        }
        let uniqueWrites = latestDataByRecordName
            .map { ICCloudPendingEpisodeStateWrite(recordName: $0.key, payloadData: $0.value) }
            .sorted { $0.recordName < $1.recordName }
        var persisted: [ICCloudPendingEpisodeStateSnapshot] = []
        var index = uniqueWrites.startIndex
        while index < uniqueWrites.endIndex {
            let end = uniqueWrites.index(index,
                                         offsetBy: remoteApplyBatchSize,
                                         limitedBy: uniqueWrites.endIndex) ?? uniqueWrites.endIndex
            let chunk = Array(uniqueWrites[index..<end])
            let chunkSnapshots = try await context.perform {
                let recordNames = chunk.map(\.recordName)
                let request = NSFetchRequest<NSManagedObject>(entityName: pendingEpisodeStateEntityName)
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    recordNames
                )
                let existing = try context.fetch(request)
                var entriesByRecordName = Dictionary(uniqueKeysWithValues: existing.compactMap { entry -> (String, NSManagedObject)? in
                    guard let recordName = entry.value(forKey: "recordName") as? String else { return nil }
                    return (recordName, entry)
                })
                var snapshots: [ICCloudPendingEpisodeStateSnapshot] = []
                snapshots.reserveCapacity(chunk.count)
                for write in chunk {
                    let entry: NSManagedObject
                    if let existingEntry = entriesByRecordName[write.recordName] {
                        entry = existingEntry
                        if replaceExisting {
                            entry.setValue(write.payloadData, forKey: "payloadData")
                        }
                    } else {
                        entry = NSEntityDescription.insertNewObject(
                            forEntityName: pendingEpisodeStateEntityName,
                            into: context
                        )
                        entry.setValue(accountRecordName, forKey: "accountRecordName")
                        entry.setValue(write.recordName, forKey: "recordName")
                        entry.setValue(write.payloadData, forKey: "payloadData")
                        entriesByRecordName[write.recordName] = entry
                    }
                    guard let payloadData = entry.value(forKey: "payloadData") as? Data else {
                        throw pendingEpisodeStateStoreError(
                            code: 2,
                            description: "Ein lokaler iCloud-Episodenstatus ist beschädigt."
                        )
                    }
                    snapshots.append(ICCloudPendingEpisodeStateSnapshot(
                        accountRecordName: accountRecordName,
                        recordName: write.recordName,
                        payloadData: payloadData
                    ))
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
                return snapshots
            }
            persisted.append(contentsOf: chunkSnapshots)
            index = end
            if index < uniqueWrites.endIndex {
                await Task.yield()
            }
        }
        return persisted
    }

    nonisolated static func pendingEpisodeStateBatch(
        accountRecordName: String,
        afterRecordName: String?,
        limit: Int = remoteApplyBatchSize
    ) async throws -> [ICCloudPendingEpisodeStateSnapshot] {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingEpisodeStateStoreError(code: 1,
                                                description: "Der lokale iCloud-Episodenstatusspeicher konnte nicht geöffnet werden.")
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: pendingEpisodeStateEntityName)
            var predicates = [NSPredicate(format: "accountRecordName == %@", accountRecordName)]
            if let afterRecordName {
                predicates.append(NSPredicate(format: "recordName > %@", afterRecordName))
            }
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
            request.fetchLimit = max(1, min(limit, remoteApplyBatchSize))
            request.fetchBatchSize = remoteApplyBatchSize
            return try context.fetch(request).map { entry in
                guard let storedAccountRecordName = entry.value(forKey: "accountRecordName") as? String,
                      let recordName = entry.value(forKey: "recordName") as? String,
                      let payloadData = entry.value(forKey: "payloadData") as? Data else {
                    throw pendingEpisodeStateStoreError(
                        code: 2,
                        description: "Ein lokaler iCloud-Episodenstatus ist beschädigt."
                    )
                }
                return ICCloudPendingEpisodeStateSnapshot(accountRecordName: storedAccountRecordName,
                                                          recordName: recordName,
                                                          payloadData: payloadData)
            }
        }
    }

    nonisolated static func pendingEpisodeStateCount(accountRecordName: String) async throws -> Int {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingEpisodeStateStoreError(code: 1,
                                                description: "Der lokale iCloud-Episodenstatusspeicher konnte nicht geöffnet werden.")
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: pendingEpisodeStateEntityName)
            request.predicate = NSPredicate(format: "accountRecordName == %@", accountRecordName)
            return try context.count(for: request)
        }
    }

    @discardableResult
    nonisolated static func removePendingEpisodeStates(
        _ snapshots: [ICCloudPendingEpisodeStateSnapshot]
    ) async throws -> Int {
        guard !snapshots.isEmpty else { return 0 }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingEpisodeStateStoreError(code: 1,
                                                description: "Der lokale iCloud-Episodenstatusspeicher konnte nicht geöffnet werden.")
        }
        var removedCount = 0
        var index = snapshots.startIndex
        while index < snapshots.endIndex {
            let end = snapshots.index(index,
                                      offsetBy: remoteApplyBatchSize,
                                      limitedBy: snapshots.endIndex) ?? snapshots.endIndex
            let chunk = Array(snapshots[index..<end])
            let removedInChunk = try await context.perform {
                let accountRecordNames = Set(chunk.map(\.accountRecordName))
                let recordNames = Set(chunk.map(\.recordName))
                let request = NSFetchRequest<NSManagedObject>(entityName: pendingEpisodeStateEntityName)
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "accountRecordName IN %@", Array(accountRecordNames)),
                    NSPredicate(format: "recordName IN %@", Array(recordNames)),
                ])
                let expectedDataByIdentity = Dictionary(uniqueKeysWithValues: chunk.map {
                    ("\($0.accountRecordName)\u{1}\($0.recordName)", $0.payloadData)
                })
                var removed = 0
                for entry in try context.fetch(request) {
                    guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
                          let recordName = entry.value(forKey: "recordName") as? String,
                          let payloadData = entry.value(forKey: "payloadData") as? Data,
                          expectedDataByIdentity["\(accountRecordName)\u{1}\(recordName)"] == payloadData else {
                        continue
                    }
                    context.delete(entry)
                    removed += 1
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
                return removed
            }
            removedCount += removedInChunk
            index = end
            if index < snapshots.endIndex {
                await Task.yield()
            }
        }
        return removedCount
    }

    nonisolated static func deleteAllPendingEpisodeStates(
        accountRecordName: String? = nil
    ) async throws {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingEpisodeStateStoreError(code: 1,
                                                description: "Der lokale iCloud-Episodenstatusspeicher konnte nicht geöffnet werden.")
        }
        while true {
            let deleted = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: pendingEpisodeStateEntityName)
                if let accountRecordName {
                    request.predicate = NSPredicate(format: "accountRecordName == %@", accountRecordName)
                }
                request.fetchLimit = remoteApplyBatchSize
                let entries = try context.fetch(request)
                for entry in entries { context.delete(entry) }
                if context.hasChanges {
                    try context.save()
                }
                let count = entries.count
                context.reset()
                return count
            }
            guard deleted > 0 else { return }
            await Task.yield()
        }
    }

    nonisolated static func pendingEpisodeStateStoreError(
        code: Int,
        description: String
    ) -> NSError {
        NSError(domain: "ICiCloudSyncPendingEpisodeState",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    func migrateLegacyPendingEpisodeStatesIfNeeded(accountRecordName: String) async throws {
        let generation = cloudAccountGeneration
        let legacyWrites = try await Self.legacyPendingEpisodeStateWrites()
        guard let legacyWrites else { return }
        _ = try await Self.stagePendingEpisodeStates(accountRecordName: accountRecordName,
                                                     writes: legacyWrites,
                                                     replaceExisting: false)
        guard generation == cloudAccountGeneration,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
        // Deleting the legacy file is the migration commit marker. If any read/upsert fails,
        // it stays in place and the next account-verified run retries idempotently.
        Self.removeSyncMetadataValue(forKey: Self.pendingEpisodeStatesKey)
    }

    nonisolated static func legacyPendingEpisodeStateWrites() async throws -> [ICCloudPendingEpisodeStateWrite]? {
        try await Task.detached(priority: .utility) {
            let fileURL = syncMetadataFileURL(forKey: pendingEpisodeStatesKey)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            let data = try Data(contentsOf: fileURL)
            guard let payloads = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: [String: Any]] else {
                throw pendingEpisodeStateStoreError(
                    code: 2,
                    description: "Der bisherige lokale iCloud-Episodenstatusspeicher ist beschädigt."
                )
            }
            return try payloads.map { recordName, payload in
                let payloadData = try PropertyListSerialization.data(
                    fromPropertyList: payload,
                    format: .binary,
                    options: 0
                )
                return ICCloudPendingEpisodeStateWrite(recordName: recordName,
                                                       payloadData: payloadData)
            }
        }.value
    }

    nonisolated static func stagePendingSubscriptionStates(
        accountRecordName: String,
        writes: [ICCloudPendingSubscriptionStateWrite],
        replaceExisting: Bool = true
    ) async throws -> [ICCloudPendingSubscriptionStateSnapshot] {
        guard !writes.isEmpty else { return [] }
        guard !accountRecordName.isEmpty,
              let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingSubscriptionStateStoreError(
                code: 1,
                description: "Der lokale iCloud-Abonnementspeicher konnte nicht geöffnet werden."
            )
        }
        if !replaceExisting {
            context.mergePolicy = NSMergePolicy(
                merge: .mergeByPropertyStoreTrumpMergePolicyType
            )
        }

        var latestDataByRecordName: [String: Data] = [:]
        for write in writes where !write.recordName.isEmpty {
            latestDataByRecordName[write.recordName] = write.payloadData
        }
        let uniqueWrites = latestDataByRecordName
            .map { ICCloudPendingSubscriptionStateWrite(recordName: $0.key, payloadData: $0.value) }
            .sorted { $0.recordName < $1.recordName }
        var persisted: [ICCloudPendingSubscriptionStateSnapshot] = []
        var index = uniqueWrites.startIndex
        while index < uniqueWrites.endIndex {
            let end = uniqueWrites.index(
                index,
                offsetBy: remoteApplyBatchSize,
                limitedBy: uniqueWrites.endIndex
            ) ?? uniqueWrites.endIndex
            let chunk = Array(uniqueWrites[index..<end])
            let chunkSnapshots = try await context.perform {
                let recordNames = chunk.map(\.recordName)
                let request = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
                request.predicate = NSPredicate(
                    format: "accountRecordName == %@ AND recordName IN %@",
                    accountRecordName,
                    recordNames
                )
                request.fetchBatchSize = remoteApplyBatchSize
                var entriesByRecordName: [String: NSManagedObject] = [:]
                for entry in try context.fetch(request) {
                    guard let recordName = entry.value(forKey: "recordName") as? String else {
                        throw pendingSubscriptionStateStoreError(
                            code: 2,
                            description: "Ein lokales iCloud-Abonnement ist beschädigt."
                        )
                    }
                    entriesByRecordName[recordName] = entry
                }

                var snapshots: [ICCloudPendingSubscriptionStateSnapshot] = []
                snapshots.reserveCapacity(chunk.count)
                for write in chunk {
                    let entry: NSManagedObject
                    if let existing = entriesByRecordName[write.recordName] {
                        entry = existing
                        if replaceExisting {
                            entry.setValue(write.payloadData, forKey: "payloadData")
                        }
                    } else {
                        entry = NSEntityDescription.insertNewObject(
                            forEntityName: pendingSubscriptionStateEntityName,
                            into: context
                        )
                        entry.setValue(accountRecordName, forKey: "accountRecordName")
                        entry.setValue(write.recordName, forKey: "recordName")
                        entry.setValue(write.payloadData, forKey: "payloadData")
                        entriesByRecordName[write.recordName] = entry
                    }
                    guard let payloadData = entry.value(forKey: "payloadData") as? Data else {
                        throw pendingSubscriptionStateStoreError(
                            code: 2,
                            description: "Ein lokales iCloud-Abonnement ist beschädigt."
                        )
                    }
                    snapshots.append(ICCloudPendingSubscriptionStateSnapshot(
                        accountRecordName: accountRecordName,
                        recordName: write.recordName,
                        payloadData: payloadData
                    ))
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
                return snapshots
            }
            persisted.append(contentsOf: chunkSnapshots)
            index = end
            if index < uniqueWrites.endIndex {
                await Task.yield()
            }
        }
        return persisted
    }

    nonisolated static func pendingSubscriptionStateBatch(
        accountRecordName: String,
        afterRecordName: String?,
        limit: Int = remoteApplyBatchSize
    ) async throws -> ICCloudPendingSubscriptionStatePage {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingSubscriptionStateStoreError(
                code: 1,
                description: "Der lokale iCloud-Abonnementspeicher konnte nicht geöffnet werden."
            )
        }
        return try await context.perform {
            let seedRequest = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
            var predicates = [
                NSPredicate(format: "accountRecordName == %@", accountRecordName),
                NSPredicate(format: "recordName != %@", RecordPrefix.subscriptionListSettings),
            ]
            if let afterRecordName {
                predicates.append(NSPredicate(format: "recordName > %@", afterRecordName))
            }
            seedRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            seedRequest.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
            seedRequest.fetchLimit = max(1, min(limit, remoteApplyBatchSize))
            seedRequest.fetchBatchSize = remoteApplyBatchSize
            let seeds = try context.fetch(seedRequest)
            let seedRecordNames = Set(try seeds.map { entry -> String in
                guard let recordName = entry.value(forKey: "recordName") as? String else {
                    throw pendingSubscriptionStateStoreError(
                        code: 2,
                        description: "Ein lokales iCloud-Abonnement ist beschädigt."
                    )
                }
                return recordName
            })
            guard let nextRecordName = seeds.last?.value(forKey: "recordName") as? String else {
                context.reset()
                return ICCloudPendingSubscriptionStatePage(snapshots: [], nextRecordName: nil)
            }

            let pairedRecordNames = seedRecordNames.reduce(into: Set<String>()) { result, recordName in
                result.formUnion(subscriptionOutboxRecordNames(forCloudRecordName: recordName))
            }
            let pairRequest = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
            pairRequest.predicate = NSPredicate(
                format: "accountRecordName == %@ AND recordName IN %@",
                accountRecordName,
                Array(pairedRecordNames)
            )
            pairRequest.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
            pairRequest.fetchBatchSize = remoteApplyBatchSize
            let allSnapshots = try context.fetch(pairRequest).map { entry in
                guard let storedAccountRecordName = entry.value(forKey: "accountRecordName") as? String,
                      let recordName = entry.value(forKey: "recordName") as? String,
                      let payloadData = entry.value(forKey: "payloadData") as? Data else {
                    throw pendingSubscriptionStateStoreError(
                        code: 2,
                        description: "Ein lokales iCloud-Abonnement ist beschädigt."
                    )
                }
                return ICCloudPendingSubscriptionStateSnapshot(
                    accountRecordName: storedAccountRecordName,
                    recordName: recordName,
                    payloadData: payloadData
                )
            }

            var snapshotsByGroup: [String: [ICCloudPendingSubscriptionStateSnapshot]] = [:]
            for snapshot in allSnapshots {
                let groupKey = subscriptionOutboxRecordNames(
                    forCloudRecordName: snapshot.recordName
                ).sorted().joined(separator: "\u{1}")
                snapshotsByGroup[groupKey, default: []].append(snapshot)
            }
            let eligibleSnapshots = snapshotsByGroup.values.flatMap { snapshots -> [ICCloudPendingSubscriptionStateSnapshot] in
                guard let firstRecordName = snapshots.map(\.recordName).min(),
                      seedRecordNames.contains(firstRecordName) else { return [] }
                return snapshots
            }.sorted { $0.recordName < $1.recordName }
            context.reset()
            return ICCloudPendingSubscriptionStatePage(
                snapshots: eligibleSnapshots,
                nextRecordName: nextRecordName
            )
        }
    }

    nonisolated static func pendingSubscriptionState(
        accountRecordName: String,
        recordName: String
    ) async throws -> ICCloudPendingSubscriptionStateSnapshot? {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingSubscriptionStateStoreError(
                code: 1,
                description: "Der lokale iCloud-Abonnementspeicher konnte nicht geöffnet werden."
            )
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
            request.predicate = NSPredicate(
                format: "accountRecordName == %@ AND recordName == %@",
                accountRecordName,
                recordName
            )
            request.fetchLimit = 1
            guard let entry = try context.fetch(request).first else { return nil }
            guard let payloadData = entry.value(forKey: "payloadData") as? Data else {
                throw pendingSubscriptionStateStoreError(
                    code: 2,
                    description: "Ein lokales iCloud-Abonnement ist beschädigt."
                )
            }
            return ICCloudPendingSubscriptionStateSnapshot(
                accountRecordName: accountRecordName,
                recordName: recordName,
                payloadData: payloadData
            )
        }
    }

    nonisolated static func pendingSubscriptionStateCount(
        accountRecordName: String
    ) async throws -> Int {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingSubscriptionStateStoreError(
                code: 1,
                description: "Der lokale iCloud-Abonnementspeicher konnte nicht geöffnet werden."
            )
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
            request.predicate = NSPredicate(format: "accountRecordName == %@", accountRecordName)
            return try context.count(for: request)
        }
    }

    @discardableResult
    nonisolated static func removePendingSubscriptionStates(
        _ snapshots: [ICCloudPendingSubscriptionStateSnapshot]
    ) async throws -> Int {
        guard !snapshots.isEmpty else { return 0 }
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingSubscriptionStateStoreError(
                code: 1,
                description: "Der lokale iCloud-Abonnementspeicher konnte nicht geöffnet werden."
            )
        }
        var removedCount = 0
        var index = snapshots.startIndex
        while index < snapshots.endIndex {
            let end = snapshots.index(
                index,
                offsetBy: remoteApplyBatchSize,
                limitedBy: snapshots.endIndex
            ) ?? snapshots.endIndex
            let chunk = Array(snapshots[index..<end])
            let removedInChunk = try await context.perform {
                let accountRecordNames = Set(chunk.map(\.accountRecordName))
                let recordNames = Set(chunk.map(\.recordName))
                let request = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "accountRecordName IN %@", Array(accountRecordNames)),
                    NSPredicate(format: "recordName IN %@", Array(recordNames)),
                ])
                let expectedDataByIdentity = Dictionary(uniqueKeysWithValues: chunk.map {
                    ("\($0.accountRecordName)\u{1}\($0.recordName)", $0.payloadData)
                })
                var removed = 0
                for entry in try context.fetch(request) {
                    guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
                          let recordName = entry.value(forKey: "recordName") as? String,
                          let payloadData = entry.value(forKey: "payloadData") as? Data,
                          expectedDataByIdentity["\(accountRecordName)\u{1}\(recordName)"] == payloadData else {
                        continue
                    }
                    context.delete(entry)
                    removed += 1
                }
                if context.hasChanges {
                    try context.save()
                }
                context.reset()
                return removed
            }
            removedCount += removedInChunk
            index = end
            if index < snapshots.endIndex {
                await Task.yield()
            }
        }
        return removedCount
    }

    nonisolated static func deleteAllPendingSubscriptionStates(
        accountRecordName: String? = nil
    ) async throws {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            throw pendingSubscriptionStateStoreError(
                code: 1,
                description: "Der lokale iCloud-Abonnementspeicher konnte nicht geöffnet werden."
            )
        }
        while true {
            let deleted = try await context.perform {
                let request = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
                if let accountRecordName {
                    request.predicate = NSPredicate(format: "accountRecordName == %@", accountRecordName)
                }
                request.fetchLimit = remoteApplyBatchSize
                request.fetchBatchSize = remoteApplyBatchSize
                let entries = try context.fetch(request)
                for entry in entries { context.delete(entry) }
                if context.hasChanges {
                    try context.save()
                }
                let count = entries.count
                context.reset()
                return count
            }
            guard deleted > 0 else { return }
            await Task.yield()
        }
    }

    nonisolated static func pendingSubscriptionStateStoreError(
        code: Int,
        description: String
    ) -> NSError {
        NSError(
            domain: "ICiCloudSyncPendingSubscriptionState",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    func migrateLegacyPendingSubscriptionStatesIfNeeded(
        accountRecordName: String
    ) async throws {
        let generation = cloudAccountGeneration
        let legacyWrites = try await Self.legacyPendingSubscriptionStateWrites()
        guard let legacyWrites else { return }
        _ = try await Self.stagePendingSubscriptionStates(
            accountRecordName: accountRecordName,
            writes: legacyWrites,
            replaceExisting: false
        )
        guard generation == cloudAccountGeneration,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            throw CancellationError()
        }
        Self.removeSyncMetadataValue(forKey: Self.pendingSubscriptionPayloadsKey)
    }

    nonisolated static func legacyPendingSubscriptionStateWrites() async throws -> [ICCloudPendingSubscriptionStateWrite]? {
        try await Task.detached(priority: .utility) {
            let fileURL = syncMetadataFileURL(forKey: pendingSubscriptionPayloadsKey)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            let data = try Data(contentsOf: fileURL)
            guard let payloads = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: [String: Any]] else {
                throw pendingSubscriptionStateStoreError(
                    code: 2,
                    description: "Der bisherige lokale iCloud-Abonnementspeicher ist beschädigt."
                )
            }
            return try payloads.map { recordName, payload in
                guard !recordName.isEmpty else {
                    throw pendingSubscriptionStateStoreError(
                        code: 2,
                        description: "Der bisherige lokale iCloud-Abonnementspeicher ist beschädigt."
                    )
                }
                let payloadData = try PropertyListSerialization.data(
                    fromPropertyList: payload,
                    format: .binary,
                    options: 0
                )
                return ICCloudPendingSubscriptionStateWrite(
                    recordName: recordName,
                    payloadData: payloadData
                )
            }
        }.value
    }

    func acquireICloudAccountTransition() async -> Int {
        if isICloudAccountTransitionRunning {
            await withCheckedContinuation { continuation in
                iCloudAccountTransitionWaiters.append(continuation)
            }
        } else {
            isICloudAccountTransitionRunning = true
        }
        iCloudAccountTransitionToken &+= 1
        return iCloudAccountTransitionToken
    }

    func releaseICloudAccountTransition() {
        guard !iCloudAccountTransitionWaiters.isEmpty else {
            isICloudAccountTransitionRunning = false
            return
        }
        iCloudAccountTransitionWaiters.removeFirst().resume()
    }

    func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange,
                             syncEngine: CKSyncEngine) async {
        let transitionToken = await acquireICloudAccountTransition()
        defer { releaseICloudAccountTransition() }
        guard !Task.isCancelled else { return }
        guard syncEngine === self.syncEngine else { return }
        clearError()

        switch event.changeType {
        case .signIn:
            setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
            do {
                guard try await reconcileAvailableICloudAccount() else { return }
                setStatus(NSLocalizedString("iCloud angemeldet.", comment: ""))
            } catch {
                guard transitionToken == iCloudAccountTransitionToken else { return }
                setError(error)
                scheduleSyncRetryAfterFailure(error: error, reason: "accountIdentity")
            }
        case .signOut:
            ensurePendingLocalOutboxScope()
            setICloudAccountSignedOut(true)
            resetForICloudAccountTransition(reinitializeEngine: false)
            setBlockingStatus(NSLocalizedString("Kein iCloud-Account verfügbar. Melde dich in den Systemeinstellungen bei iCloud an.", comment: ""))
        case .switchAccounts:
            do {
                try await beginICloudAccountSwitch()
            } catch {
                guard transitionToken == iCloudAccountTransitionToken else { return }
                setError(error)
                scheduleSyncRetryAfterFailure(error: error, reason: "accountIdentity")
                return
            }
            setStatus(NSLocalizedString("iCloud Account gewechselt.", comment: ""))
            do {
                _ = try await reconcileAvailableICloudAccount()
            } catch {
                guard transitionToken == iCloudAccountTransitionToken else { return }
                setError(error)
                scheduleSyncRetryAfterFailure(error: error, reason: "accountIdentity")
            }
        @unknown default:
            do {
                try await beginICloudAccountSwitch()
            } catch {
                guard transitionToken == iCloudAccountTransitionToken else { return }
                setError(error)
                scheduleSyncRetryAfterFailure(error: error, reason: "accountIdentity")
                return
            }
            setStatus(NSLocalizedString("iCloud Account geändert.", comment: ""))
            do {
                _ = try await reconcileAvailableICloudAccount()
            } catch {
                guard transitionToken == iCloudAccountTransitionToken else { return }
                setError(error)
                scheduleSyncRetryAfterFailure(error: error, reason: "accountIdentity")
            }
        }
    }

    @discardableResult
    func reconcileAvailableICloudAccount() async throws -> Bool {
        let lookupGeneration = cloudAccountGeneration
        let currentAccountUserRecordName = try await container.userRecordID().recordName
        guard lookupGeneration == cloudAccountGeneration else { return false }

        let previousAccountUserRecordName = defaults.string(forKey: Self.accountUserRecordNameKey)
        let isSameAccount = previousAccountUserRecordName == currentAccountUserRecordName
            && previousAccountUserRecordName != nil
        let accountChangedWhileAppWasInactive = previousAccountUserRecordName != nil && !isSameAccount
        let accountResetRequired = isICloudAccountResetRequired
        let shouldResetPendingRemoteStates = accountResetRequired
            || accountChangedWhileAppWasInactive
            || (isICloudAccountSignedOut && !isSameAccount)

        // A same-account sign-out rebuilds the engine below. Move an intermediate-build
        // plist into account-scoped rows first, because the generic metadata reset removes
        // that legacy file while the durable rows intentionally survive the rebuild.
        if isSameAccount, !accountResetRequired {
            try await migrateLegacyPendingSubscriptionStatesIfNeeded(
                accountRecordName: currentAccountUserRecordName
            )
            guard lookupGeneration == cloudAccountGeneration else { return false }
        }

        if accountResetRequired || accountChangedWhileAppWasInactive {
            if let previousAccountUserRecordName {
                _ = try await Self.deleteSyncItemMetadata(
                    accountRecordName: previousAccountUserRecordName
                )
                _ = try await Self.deleteKnownRecordSystemFields(
                    accountRecordName: previousAccountUserRecordName
                )
                guard lookupGeneration == cloudAccountGeneration else { return false }
            }
            try await Self.removeAllLegacySyncItemMetadataSources()
            try await Self.removeAllLegacyKnownRecordSystemFieldFiles()
            guard lookupGeneration == cloudAccountGeneration else { return false }
        } else if isICloudAccountSignedOut, isSameAccount {
            _ = try await Self.deleteKnownRecordSystemFields(
                accountRecordName: currentAccountUserRecordName
            )
            guard lookupGeneration == cloudAccountGeneration else { return false }
        }

        if accountResetRequired || isICloudAccountSignedOut || accountChangedWhileAppWasInactive {
            // When the app launched with every category off, the old serialized engine
            // was intentionally not created. Reload it only after CloudKit has identified
            // the account, so same-account offline changes can be transferred safely.
            let transferPendingChanges = !accountResetRequired && isICloudAccountSignedOut && isSameAccount
            if transferPendingChanges {
                initializeSyncEngineIfNeeded()
            }
            setICloudAccountSignedOut(false)
            resetForICloudAccountTransition(reinitializeEngine: true,
                                             transferPendingChanges: transferPendingChanges)
        }
        if shouldResetPendingRemoteStates {
            let pendingResetGeneration = cloudAccountGeneration
            try await Self.deleteAllPendingEpisodeStates()
            try await Self.deleteAllPendingSubscriptionStates()
            guard pendingResetGeneration == cloudAccountGeneration else { return false }
        }
        defaults.set(currentAccountUserRecordName, forKey: Self.accountUserRecordNameKey)
        let bindingGeneration = cloudAccountGeneration
        // CloudKit has now identified the account, but remote callbacks stay closed until
        // pending rows are bound. New local edits can safely target this verified account
        // directly while the background bind runs, so they cannot race into its source scope.
        syncEngineCallbackGate.beginVerifiedAccountCapture(currentAccountUserRecordName,
                                                            generation: bindingGeneration)
        if let pendingScope = currentPendingLocalOutboxScope() {
            try await bindPendingAccountLocalOutboxEntries(to: currentAccountUserRecordName,
                                                            pendingScope: pendingScope)
            guard bindingGeneration == cloudAccountGeneration else { return false }
            _ = try await Self.bindSyncItemMetadata(
                from: pendingScope,
                to: currentAccountUserRecordName
            )
            guard bindingGeneration == cloudAccountGeneration,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == currentAccountUserRecordName else { return false }
            if currentPendingLocalOutboxScope() == pendingScope {
                defaults.removeObject(forKey: Self.localOutboxPendingScopeKey)
            }
        }
        if defaults.bool(forKey: Self.localOutboxAwaitingAccountSwitchKey) {
            defaults.removeObject(forKey: Self.localOutboxAwaitingAccountSwitchKey)
        }
        if !defaults.bool(forKey: Self.localOutboxHasVerifiedAccountKey) {
            try await bindUnboundLocalOutboxEntries(to: currentAccountUserRecordName)
            guard bindingGeneration == cloudAccountGeneration else { return false }
            _ = try await Self.bindSyncItemMetadata(
                from: Self.localOutboxUnboundAccountRecordName,
                to: currentAccountUserRecordName
            )
            guard bindingGeneration == cloudAccountGeneration,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == currentAccountUserRecordName else { return false }
            defaults.set(true, forKey: Self.localOutboxHasVerifiedAccountKey)
        }
        try await migrateLegacyPendingEpisodeStatesIfNeeded(
            accountRecordName: currentAccountUserRecordName
        )
        guard bindingGeneration == cloudAccountGeneration else { return false }
        try await migrateLegacyPendingSubscriptionStatesIfNeeded(
            accountRecordName: currentAccountUserRecordName
        )
        guard bindingGeneration == cloudAccountGeneration else { return false }
        try await migrateLegacySyncItemMetadataIfNeeded(
            accountRecordName: currentAccountUserRecordName
        )
        guard bindingGeneration == cloudAccountGeneration,
              defaults.string(forKey: Self.accountUserRecordNameKey) == currentAccountUserRecordName else { return false }
        if accountResetRequired {
            clearICloudAccountResetRequired()
        }
        let wasVerified = isICloudAccountIdentityVerified
        setICloudAccountIdentityVerified(true)
        do {
            try await migrateLegacyKnownRecordSystemFieldsIfNeeded(
                accountRecordName: currentAccountUserRecordName
            )
        } catch {
            setICloudAccountIdentityVerified(false)
            throw error
        }
        guard bindingGeneration == cloudAccountGeneration,
              isICloudAccountIdentityVerified,
              defaults.string(forKey: Self.accountUserRecordNameKey) == currentAccountUserRecordName else {
            return false
        }
        if !wasVerified {
            if anySyncEnabled {
                if await drainLocalOutbox() {
                    scheduleCurrentEnabledDataForUpload()
                    scheduleApplyPendingPayloads()
                }
            }
        }
        resumePendingFinalDeviceRecordUpdateIfNeeded()
        return true
    }

    var isICloudAccountResetRequired: Bool {
        (Self.syncMetadataValue(forKey: Self.accountResetRequiredKey) as? NSNumber)?.boolValue == true
    }

    func persistICloudAccountResetRequired() throws {
        _ = try Self.writeSyncMetadataValue(true, forKey: Self.accountResetRequiredKey)
        defaults.removeObject(forKey: Self.accountResetRequiredKey)
    }

    func clearICloudAccountResetRequired() {
        Self.removeSyncMetadataValue(forKey: Self.accountResetRequiredKey)
        defaults.removeObject(forKey: Self.accountResetRequiredKey)
    }

    func discardStaleICloudAccountEngineStateIfNeeded() {
        guard isICloudAccountResetRequired else { return }
        syncEngine = nil
        updateSyncEngineCallbackGate()
        setSyncMetadata(nil, forKey: Self.engineStateKey)
        Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
    }

    func beginICloudAccountSwitch() async throws {
        let previousAccountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey)
        setICloudAccountIdentityVerified(false)
        ensurePendingLocalOutboxScope()
        setICloudAccountSignedOut(false)
        defaults.set(true, forKey: Self.localOutboxAwaitingAccountSwitchKey)
        try persistICloudAccountResetRequired()
        // Close/cancel every old-account producer before the bounded background cleanup.
        // Local edits made while cleanup suspends stay in the same durable pending scope
        // that may already contain cold-start edits captured before this account event.
        resetForICloudAccountTransition(reinitializeEngine: true, transferPendingChanges: false)
        let transitionGeneration = cloudAccountGeneration
        if let previousAccountRecordName {
            _ = try await Self.deleteSyncItemMetadata(
                accountRecordName: previousAccountRecordName
            )
            _ = try await Self.deleteKnownRecordSystemFields(
                accountRecordName: previousAccountRecordName
            )
            guard transitionGeneration == cloudAccountGeneration else { throw CancellationError() }
        }
        try await Self.removeAllLegacySyncItemMetadataSources()
        try await Self.removeAllLegacyKnownRecordSystemFieldFiles()
        guard transitionGeneration == cloudAccountGeneration else { throw CancellationError() }
        defaults.removeObject(forKey: Self.accountUserRecordNameKey)
    }

    func setICloudAccountIdentityVerified(_ verified: Bool) {
        if !verified {
            ensurePendingLocalOutboxScope()
        }
        guard isICloudAccountIdentityVerified != verified else { return }
        isICloudAccountIdentityVerified = verified
        updateSyncEngineCallbackGate()
    }

    func setICloudAccountSignedOut(_ signedOut: Bool) {
        isICloudAccountSignedOut = signedOut
        defaults.set(signedOut, forKey: Self.accountSignedOutKey)
        if signedOut {
            isICloudAccountIdentityVerified = false
            updateSyncEngineCallbackGate()
        }
    }

    func resetForICloudAccountTransition(reinitializeEngine: Bool,
                                         transferPendingChanges: Bool = false) {
        cancelInitialQueueTask()
        cancelLowPrioritySyncTask()
        manualSyncTask?.cancel()
        backgroundSyncTask?.cancel()
        cancelFinalDeviceRecordUpdate()
        resetSyncRetryBackoff()
        guard reinitializeEngine else {
            applyPendingDebounceWorkItem?.cancel()
            applyPendingDebounceWorkItem = nil
            cloudAccountGeneration &+= 1
            updateSyncEngineCallbackGate()
            isFetchingCloudInventory = false
            pendingCloudInventoryRefreshReason = nil
            defaults.removeObject(forKey: Self.cloudInventoryKey)
            defaults.removeObject(forKey: Self.lastSyncDateKey)
            setSyncMetadata([String: [String: Any]](), forKey: Self.deviceCacheKey)
            pendingInitialUploadBatches.removeAll()
            hasUnresolvedSyncFailures = false
            isApplyingRemoteChange = false
            isPerformingManualSync = false
            syncedUserDataInCurrentRun = false
            clearSyncActivity()
            resetInitialBackfillCursorsForEnabledOptions()
            postDevicesChanged()
            return
        }

        let transferableChanges = transferPendingChanges ? transferablePendingUserChanges() : []
        syncEngine = nil
        updateSyncEngineCallbackGate()
        resetAllLocalSyncMetadata()
        resetInitialBackfillCursorsForEnabledOptions()
        initializeSyncEngineIfNeeded()
        if !transferableChanges.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: transferableChanges)
        }
        scheduleCurrentEnabledDataForUpload()
        postDevicesChanged()
    }

    func transferablePendingUserChanges() -> [CKSyncEngine.PendingRecordZoneChange] {
        guard let syncEngine else { return [] }
        return syncEngine.state.pendingRecordZoneChanges.filter { change in
            let recordName: String
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                recordName = recordID.recordName
            @unknown default:
                return false
            }
            return recordName.hasPrefix(RecordPrefix.episode)
                || recordName.hasPrefix(RecordPrefix.subscription)
                || recordName.hasPrefix(RecordPrefix.subscriptionTombstone)
        }
    }

    func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) async {
        for deletion in event.deletions where deletion.zoneID == zoneID {
            guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
                handleLocalPersistenceFailure(Self.knownRecordSystemFieldsStoreError(
                    code: 1,
                    description: "Der iCloud-Account für gelöschte CloudKit-Systemfelder konnte nicht bestimmt werden."
                ))
                return
            }
            let generation = cloudAccountGeneration
            do {
                _ = try await Self.deleteKnownRecordSystemFields(
                    accountRecordName: accountRecordName
                )
                try await Self.removeAllLegacyKnownRecordSystemFieldFiles()
            } catch {
                guard generation == cloudAccountGeneration else { return }
                handleLocalPersistenceFailure(error)
                return
            }
            guard generation == cloudAccountGeneration,
                  isICloudAccountIdentityVerified,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
                return
            }
            Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
            setSyncMetadata([String: [String: Any]](), forKey: Self.deviceCacheKey)
            scheduleCurrentEnabledDataForUpload()
        }
    }

    func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
        let generation = cloudAccountGeneration
        guard !event.modifications.isEmpty || !event.deletions.isEmpty else { return }
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else {
            handleLocalPersistenceFailure(Self.knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der iCloud-Account für empfangene CloudKit-Systemfelder konnte nicht bestimmt werden."
            ))
            return
        }

        let orderedRecords = orderedModifications(event.modifications)

        if event.modifications.contains(where: { isUserDataRecordID($0.record.recordID) })
            || event.deletions.contains(where: { isUserDataRecordID($0.recordID) }) {
            syncedUserDataInCurrentRun = true
        }

        beginSyncActivity(fetchedActivityDirection(for: orderedRecords.map(\.record)))

        // Per-category progress for the status line ("Lädt herunter… 31/51 Abonnements").
        // orderedModifications groups the records by type, so the label switches once per
        // category instead of flickering.
        var expectedByLabel: [String: Int] = [:]
        for modification in event.modifications where isUserDataRecordID(modification.record.recordID) {
            if let label = Self.activityKindLabel(forRecordType: modification.record.recordType) {
                expectedByLabel[label, default: 0] += 1
            }
        }

        defer {
            if generation == cloudAccountGeneration {
                remoteAppliedObjectIDs.removeAll()
                postStateChanged()
                postDevicesChanged()
            }
        }

        // CloudKit exposes modifications and deletions as separate arrays without a
        // cross-array order. Stage deletions first inside one callback: if the record
        // still exists, its modification below replaces the inverse delete in the
        // durable pending store. Destructive subscription work waits for didFetchChanges.
        var deletionIndex = event.deletions.startIndex
        while deletionIndex < event.deletions.endIndex {
            let end = event.deletions.index(deletionIndex,
                                            offsetBy: Self.remoteApplyBatchSize,
                                            limitedBy: event.deletions.endIndex) ?? event.deletions.endIndex
            let batch = event.deletions[deletionIndex..<end]
            do {
                try await Self.removeKnownRecordSystemFields(
                    batch.map(\.recordID),
                    accountRecordName: accountRecordName
                )
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      !Task.isCancelled,
                      let context = databaseManager.objectContext else {
                    throw Self.syncItemMetadataStoreError(
                        code: 1,
                        description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
                    )
                }
                let recordNames = Set(batch.compactMap { deletion -> String? in
                    deletion.recordType == RecordKind.subscription
                        || deletion.recordType == RecordKind.subscriptionTombstone
                        ? deletion.recordID.recordName
                        : nil
                })
                let metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
                    accountRecordName: accountRecordName,
                    recordNames: recordNames,
                    context: context
                )
                let subscriptionWrites = try pendingSubscriptionDeletionStateWrites(
                    in: batch,
                    metadataBatch: metadataBatch
                )
                if !subscriptionWrites.isEmpty {
                    markPendingSubscriptionFetchIncomplete()
                    _ = try await Self.stagePendingSubscriptionStates(
                        accountRecordName: accountRecordName,
                        writes: subscriptionWrites
                    )
                }
                let outboxRecordNames = recordNames.reduce(into: Set<String>()) { result, recordName in
                    result.formUnion(Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName))
                }
                let outboxEntries = try await Self.localOutboxEntries(
                    accountRecordName: accountRecordName,
                    recordNames: outboxRecordNames
                )
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      !Task.isCancelled else {
                    return
                }
                mergeLocalOutboxSnapshotsIntoCache(outboxEntries)
                let didFlush = try performSynchronousRemoteApplyBatch {
                    _ = try processFetchedDeletionBatch(
                        batch,
                        metadataBatch: metadataBatch
                    )
                }
                guard didFlush else { return }
            } catch {
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                      !Task.isCancelled else { return }
                handleLocalPersistenceFailure(error)
                return
            }
            await Task.yield()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
            deletionIndex = end
        }

        var modificationCountsByType: [String: Int] = [:]
        var modificationIndex = orderedRecords.startIndex
        while modificationIndex < orderedRecords.endIndex {
            let end = orderedRecords.index(modificationIndex,
                                           offsetBy: Self.remoteApplyBatchSize,
                                           limitedBy: orderedRecords.endIndex) ?? orderedRecords.endIndex
            let batch = orderedRecords[modificationIndex..<end]
            let stagedEpisodeStates: [ICCloudPendingEpisodeStateSnapshot]
            do {
                try await Self.persistKnownRecordSystemFields(
                    batch.map(\.record),
                    accountRecordName: accountRecordName
                )
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      !Task.isCancelled else {
                    return
                }
                let episodeWrites = try pendingEpisodeStateWrites(in: batch)
                let subscriptionWrites = try pendingSubscriptionStateWrites(in: batch)
                if episodeWrites.isEmpty {
                    stagedEpisodeStates = []
                } else {
                    stagedEpisodeStates = try await Self.stagePendingEpisodeStates(
                        accountRecordName: accountRecordName,
                        writes: episodeWrites
                    )
                }
                if !subscriptionWrites.isEmpty {
                    markPendingSubscriptionFetchIncomplete()
                    _ = try await Self.stagePendingSubscriptionStates(
                        accountRecordName: accountRecordName,
                        writes: subscriptionWrites
                    )
                }
                let outboxRecordNames = batch.reduce(into: Set<String>()) { result, modification in
                    let record = modification.record
                    if record.recordType == RecordKind.episodeState {
                        result.insert(record.recordID.recordName)
                    } else if record.recordType == RecordKind.subscription
                                || record.recordType == RecordKind.subscriptionTombstone {
                        result.formUnion(Self.subscriptionOutboxRecordNames(
                            forCloudRecordName: record.recordID.recordName
                        ))
                    }
                }
                let outboxEntries = try await Self.localOutboxEntries(
                    accountRecordName: accountRecordName,
                    recordNames: outboxRecordNames
                )
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      !Task.isCancelled else { return }
                mergeLocalOutboxSnapshotsIntoCache(outboxEntries)
            } catch {
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                      !Task.isCancelled else { return }
                handleLocalPersistenceFailure(error)
                return
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
            let result: FetchedModificationBatchResult
            do {
                var appliedResult: FetchedModificationBatchResult?
                let didFlush = try performSynchronousRemoteApplyBatch {
                    appliedResult = try processFetchedModificationBatch(
                        batch,
                        stagedEpisodeStates: stagedEpisodeStates,
                        expectedByLabel: expectedByLabel,
                        modificationCountsByType: &modificationCountsByType
                    )
                }
                guard didFlush, let appliedResult else { return }
                result = appliedResult
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            do {
                _ = try await Self.removePendingEpisodeStates(result.appliedEpisodeStates)
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            postStateChanged()
            await Task.yield()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
            modificationIndex = end
        }

        logSyncEvent("Remote-Änderungen verarbeitet", metadata: [
            "modifications": event.modifications.count,
            "deletions": event.deletions.count,
            "byType": modificationCountsByType.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","),
        ])

        // Replay a received manual sort order onto the feed ranks now that all
        // subscription records of this batch are applied.
        guard await applySubscriptionListSortIfNeeded() else { return }
        markSyncCompletedIfFinished()
        // Newly applied subscriptions are stubs — load their episodes one by one.
        hydrateStubFeedsIfNeeded()
    }

    func performSynchronousRemoteApplyBatch(
        _ mutations: () throws -> Void
    ) rethrows -> Bool {
        let wasApplyingRemoteChange = isApplyingRemoteChange
        isApplyingRemoteChange = true
        defer {
            isApplyingRemoteChange = wasApplyingRemoteChange
        }
        try mutations()
        return flushRemoteApplyBatchBeforeYield()
    }

    func flushRemoteApplyBatchBeforeYield() -> Bool {
        // Commit each bounded remote batch while origin suppression is still active. Core
        // Data then delivers/processes its notification before UI work can run at the yield,
        // so remote objects cannot be journaled as fresh local outbox revisions.
        let outboxResolution: LocalOutboxResolutionCommit
        do {
            outboxResolution = try deleteResolvedLocalOutboxEntries()
        } catch {
            handleLocalPersistenceFailure(error)
            return false
        }
        if let error = databaseManager.saveReturningError() {
            handleLocalPersistenceFailure(error)
            return false
        }
        consumeResolvedLocalOutboxEntries(outboxResolution)
        remoteAppliedObjectIDs.removeAll()
        return true
    }

    func handleLocalPersistenceFailure(_ error: Error) {
        hasUnresolvedSyncFailures = true
        requiresSyncEngineStateRollbackAfterPersistenceFailure = true
        localOutboxSnapshotCache = [:]
        remoteAppliedObjectIDs.removeAll()
        let persistenceError = NSError(
            domain: "ICiCloudSyncLocalPersistence",
            code: (error as NSError).code,
            userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString(
                    "Die synchronisierten Änderungen konnten auf diesem Gerät nicht lokal gespeichert werden. Prüfe den freien Speicherplatz und versuche es erneut.",
                    comment: ""
                ),
                NSUnderlyingErrorKey: error,
            ]
        )
        setError(persistenceError)
        scheduleSyncRetryAfterFailure(code: nil, reason: "localCoreDataSave")
    }

    func processFetchedModificationBatch(
        _ batch: ArraySlice<CKDatabase.RecordZoneChange.Modification>,
        stagedEpisodeStates: [ICCloudPendingEpisodeStateSnapshot],
        expectedByLabel: [String: Int],
        modificationCountsByType: inout [String: Int]
    ) throws -> FetchedModificationBatchResult {
        guard let context = databaseManager.objectContext,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
            throw Self.syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
            )
        }
        let episodeRecordNames = Set(batch.compactMap { modification -> String? in
            modification.record.recordType == RecordKind.episodeState
                ? modification.record.recordID.recordName
                : nil
        })
        var metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
            accountRecordName: accountRecordName,
            recordNames: episodeRecordNames,
            context: context
        )
        let resolvedEpisodes = resolvedEpisodesForRemoteBatch(batch)
        let episodeIdentityWrites = try batch.compactMap { modification -> ICCloudSyncItemMetadataWrite? in
            guard modification.record.recordType == RecordKind.episodeState,
                  let payload = payloadDictionary(from: modification.record),
                  let objectHash = payload["objectHash"] as? String,
                  resolvedEpisodes[objectHash] != nil else { return nil }
            return try Self.episodeSyncItemMetadataIdentityWrite(
                recordName: modification.record.recordID.recordName,
                objectHash: objectHash
            )
        }
        try Self.upsertSyncItemMetadata(
            episodeIdentityWrites,
            updating: [],
            metadataBatch: &metadataBatch,
            context: context
        )
        var episodeMetadataWrites: [String: ICCloudSyncItemMetadataWrite] = [:]
        var appliedEpisodeRecordNames = Set<String>()
        var records: [CKRecord] = []
        records.reserveCapacity(batch.count)

        for modification in batch {
            let record = modification.record
            records.append(record)
            modificationCountsByType[record.recordType, default: 0] += 1
            if isUserDataRecordID(record.recordID) {
                let label = Self.activityKindLabel(forRecordType: record.recordType)
                if label != syncActivityKindLabel {
                    syncActivityKindLabel = label
                    syncActivityRecordCount = 0
                    syncActivityExpectedCount = label.flatMap { expectedByLabel[$0] } ?? 0
                }
            }

            if record.recordType == RecordKind.episodeState,
               let payload = payloadDictionary(from: record) {
                // CKSyncEngine can persist a newer change token even if our following
                // Core Data save fails. Stage every payload first so disk-full/app-kill
                // recovery can replay it; successful batches remove their staged rows.
                if episodesSyncEnabled {
                    let objectHash = payload["objectHash"] as? String
                    if let resolvedEpisode = objectHash.flatMap({ resolvedEpisodes[$0] }) {
                        let localMetadata = try Self.syncItemMetadataSnapshot(
                            forRecordName: record.recordID.recordName,
                            metadataBatch: metadataBatch
                        )
                        if let update = applyRemoteEpisodeState(
                            payload,
                            recordName: record.recordID.recordName,
                            localModifiedAt: localMetadata?.localModifiedAt,
                            resolvedEpisode: resolvedEpisode,
                            lookupEpisodeIfNeeded: false
                        ) {
                            episodeMetadataWrites[record.recordID.recordName] = ICCloudSyncItemMetadataWrite(
                                category: Self.localOutboxEpisodeCategory,
                                recordName: record.recordID.recordName,
                                itemIdentifier: update.objectHash,
                                localModifiedAt: update.date,
                                localState: nil,
                                payloadHash: nil
                            )
                        }
                        appliedEpisodeRecordNames.insert(record.recordID.recordName)
                    }
                }
            } else if record.recordType != RecordKind.subscription
                        && record.recordType != RecordKind.subscriptionTombstone
                        && record.recordType != RecordKind.subscriptionListSettings {
                applyRemoteNonEpisodeRecord(record)
            }

            if isUserDataRecordID(record.recordID) {
                recordSyncActivity(1)
            }
        }
        try Self.upsertSyncItemMetadata(
            Array(episodeMetadataWrites.values),
            metadataBatch: &metadataBatch,
            context: context
        )
        let appliedEpisodeStates = stagedEpisodeStates.filter {
            appliedEpisodeRecordNames.contains($0.recordName)
        }
        return FetchedModificationBatchResult(records: records,
                                              appliedEpisodeStates: appliedEpisodeStates)
    }

    func resolvedEpisodesForRemoteBatch(
        _ batch: ArraySlice<CKDatabase.RecordZoneChange.Modification>
    ) -> [String: CDEpisode] {
        guard episodesSyncEnabled, let context = databaseManager.objectContext else { return [:] }
        let objectHashes = batch.compactMap { modification -> String? in
            guard modification.record.recordType == RecordKind.episodeState else { return nil }
            return payloadDictionary(from: modification.record)?["objectHash"] as? String
        }
        guard !objectHashes.isEmpty else { return [:] }
        let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
        request.predicate = NSPredicate(format: "objectHash IN %@", objectHashes)
        request.includesSubentities = false
        let episodes = (try? context.fetch(request)) ?? []
        return deterministicallyResolvedEpisodesByObjectHash(episodes)
    }

    func deterministicallyResolvedEpisodesByObjectHash(
        _ episodes: [CDEpisode]
    ) -> [String: CDEpisode] {
        var resolved: [String: CDEpisode] = [:]
        for episode in episodes {
            guard let objectHash = episode.objectHash, !objectHash.isEmpty else { continue }
            guard let current = resolved[objectHash] else {
                resolved[objectHash] = episode
                continue
            }
            let currentIdentity = current.objectID.uriRepresentation().absoluteString
            let candidateIdentity = episode.objectID.uriRepresentation().absoluteString
            if candidateIdentity < currentIdentity {
                resolved[objectHash] = episode
            }
        }
        return resolved
    }

    func processFetchedDeletionBatch(
        _ batch: ArraySlice<CKDatabase.RecordZoneChange.Deletion>,
        metadataBatch: ICCloudSyncItemMetadataContextBatch
    ) throws -> [CKRecord.ID] {
        for deletion in batch {
            try applyRemoteDeletion(deletion, metadataBatch: metadataBatch)
        }
        return batch.map(\.recordID)
    }

    func fetchedActivityDirection(for records: [CKRecord]) -> SyncActivityDirection {
        let userDataRecords = records.filter { isUserDataRecordID($0.recordID) }
        guard !userDataRecords.isEmpty else { return .down }
        let containsOtherDeviceData = userDataRecords.contains { record in
            guard let payload = payloadDictionary(from: record),
                  let sourceDeviceID = payload["deviceID"] as? String else {
                return true
            }
            return sourceDeviceID != deviceID
        }
        return containsOtherDeviceData ? .down : .verifying
    }

    // Apply subscriptions last and in the user's list order (rank): the per-feed network
    // subscribe makes that phase slow, so the visible top of the list should fill in
    // first. Everything else (device records, episode states) keeps its original order.
    func orderedModifications(_ modifications: [CKDatabase.RecordZoneChange.Modification]) -> [CKDatabase.RecordZoneChange.Modification] {
        guard modifications.contains(where: {
            $0.record.recordType == RecordKind.subscription
                || $0.record.recordType == RecordKind.subscriptionTombstone
        }) else {
            return modifications
        }
        var others: [CKDatabase.RecordZoneChange.Modification] = []
        var subscriptions: [(modification: CKDatabase.RecordZoneChange.Modification, date: Date, rank: Int)] = []
        var subscriptionListSettings: [CKDatabase.RecordZoneChange.Modification] = []
        for modification in modifications {
            if modification.record.recordType == RecordKind.subscription
                || modification.record.recordType == RecordKind.subscriptionTombstone {
                let payload = payloadDictionary(from: modification.record)
                let rank = (payload?["rank"] as? NSNumber)?.intValue ?? Int.max
                let date = payload?["updatedAt"] as? Date ?? .distantPast
                subscriptions.append((modification, date, rank))
            } else if modification.record.recordType == RecordKind.subscriptionListSettings {
                subscriptionListSettings.append(modification)
            } else {
                others.append(modification)
            }
        }
        let sortedSubscriptions = subscriptions.enumerated()
            .sorted { ($0.element.date, $0.element.rank, $0.offset) < ($1.element.date, $1.element.rank, $1.offset) }
            .map { $0.element.modification }
        return others + sortedSubscriptions + subscriptionListSettings
    }

    func handleSentDatabaseChanges(_ event: CKSyncEngine.Event.SentDatabaseChanges) {
        var hasFailedDatabaseChanges = false

        for failedSave in event.failedZoneSaves {
            hasFailedDatabaseChanges = true
            handleCloudKitSendError(failedSave.error)
        }

        for (_, error) in event.failedZoneDeletes {
            hasFailedDatabaseChanges = true
            handleCloudKitSendError(error)
        }

        if hasFailedDatabaseChanges {
            hasUnresolvedSyncFailures = true
            postStateChanged()
            // A failed zone save is the classic first-enable failure (the custom zone
            // doesn't exist yet) — without a retry the sync stalls right there.
            scheduleSyncRetryAfterFailure(code: nil, reason: "failedDatabaseChanges")
        } else if !hasUnresolvedSyncFailures {
            markSyncCompletedIfFinished()
        }
    }

    func deviceRecordAcknowledgementMatchesCurrentSyncOptions(_ payload: [String: Any]) -> Bool {
        guard let episodesEnabled = payload["episodesEnabled"] as? Bool,
              let subscriptionsEnabled = payload["subscriptionsEnabled"] as? Bool,
              let settingsEnabled = payload["settingsEnabled"] as? Bool else {
            return false
        }
        return episodesEnabled == episodesSyncEnabled
            && subscriptionsEnabled == subscriptionsSyncEnabled
            && settingsEnabled == settingsSyncEnabled
    }

    func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges, syncEngine: CKSyncEngine) async {
        let generation = cloudAccountGeneration
        if event.savedRecords.contains(where: { isUserDataRecordID($0.recordID) })
            || event.deletedRecordIDs.contains(where: { isUserDataRecordID($0) }) {
            syncedUserDataInCurrentRun = true
        }

        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else {
            handleLocalPersistenceFailure(Self.knownRecordSystemFieldsStoreError(
                code: 1,
                description: "Der iCloud-Account für bestätigte CloudKit-Systemfelder konnte nicht bestimmt werden."
            ))
            return
        }
        let conflictServerRecords = event.failedRecordSaves.compactMap { failedSave -> CKRecord? in
            guard failedSave.error.code == .serverRecordChanged else { return nil }
            return failedSave.error.serverRecord
        }
        let recordIDsWithoutServerState = event.failedRecordSaves.compactMap { failedSave -> CKRecord.ID? in
            switch failedSave.error.code {
            case .zoneNotFound, .unknownItem:
                return failedSave.record.recordID
            default:
                return nil
            }
        } + event.failedRecordDeletes.compactMap { recordID, error -> CKRecord.ID? in
            switch error.code {
            case .zoneNotFound, .unknownItem:
                return recordID
            default:
                return nil
            }
        }

        // A backfill page can acknowledge hundreds of records. Archive their CloudKit
        // system fields as one utility-priority batch before advancing either durable
        // acknowledgement; otherwise a crash can leave an acknowledged record without
        // the change tag needed for its next save.
        do {
            try await Self.persistKnownRecordSystemFields(
                event.savedRecords + conflictServerRecords,
                accountRecordName: accountRecordName
            )
            try await Self.removeKnownRecordSystemFields(
                event.deletedRecordIDs + recordIDsWithoutServerState,
                accountRecordName: accountRecordName
            )
        } catch {
            guard generation == cloudAccountGeneration,
                  syncEngine === self.syncEngine else { return }
            handleLocalPersistenceFailure(error)
            return
        }
        guard generation == cloudAccountGeneration,
              syncEngine === self.syncEngine,
              isICloudAccountIdentityVerified,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }

        let acknowledgedInitialEpisodeRecords = initialEpisodeRecordsAwaitingAcknowledgedClock(
            in: event.savedRecords
        )
        do {
            try await persistAcknowledgedInitialEpisodeClocks(acknowledgedInitialEpisodeRecords)
        } catch {
            guard generation == cloudAccountGeneration,
                  syncEngine === self.syncEngine else { return }
            let recordsToRetry = initialEpisodeRecordsAwaitingAcknowledgedClock(
                in: acknowledgedInitialEpisodeRecords
            )
            if !recordsToRetry.isEmpty {
                var pendingKeys = pendingRecordZoneChangeKeys()
                addPendingSaves(
                    recordsToRetry.map(\.recordID),
                    pendingKeys: &pendingKeys,
                    stampDeviceRecordForUserData: false
                )
            }
            handleLocalPersistenceFailure(error)
            return
        }
        guard generation == cloudAccountGeneration,
              syncEngine === self.syncEngine else { return }

        for record in event.savedRecords {
            if record.recordType == RecordKind.device, let payload = payloadDictionary(from: record) {
                updateDeviceCache(with: payload)
                if record.recordID == deviceRecordID(for: deviceID) {
                    if deviceRecordAcknowledgementMatchesCurrentSyncOptions(payload) {
                        clearPendingFinalDeviceRecordUpdateIntent()
                        requiresImmediateFinalDeviceRecordResend = false
                    } else if hasPendingFinalDeviceRecordUpdate {
                        // The user changed the switches while this older payload was in
                        // flight. Its pending key is free again now: queue the current
                        // payload here, then let the outer send loop send it only after
                        // this CKSyncEngine callback has returned.
                        queueDeviceRecord(scheduleSync: false)
                        requiresImmediateFinalDeviceRecordResend = true
                    }
                }
            }
        }
        do {
            try acknowledgeLocalOutboxRecords(event.savedRecords)
        } catch {
            guard generation == cloudAccountGeneration,
                  syncEngine === self.syncEngine else { return }
            handleLocalPersistenceFailure(error)
            return
        }
        recordInitialUploadRecordsSaved(event.savedRecords.map { $0.recordID })

        var acknowledgedDeleteRevisions: [String: String] = [:]
        var resolvedInitialUploadDeleteRecordIDs = event.deletedRecordIDs
        for recordID in event.deletedRecordIDs {
            if let revision = syncEngineCallbackGate.pendingDeleteAttempt(for: recordID.recordName,
                                                                           syncEngine: syncEngine) {
                acknowledgedDeleteRevisions[recordID.recordName] = revision
            }
        }

        var retryRecords: [CKSyncEngine.PendingRecordZoneChange] = []
        var retryZones: [CKSyncEngine.PendingDatabaseChange] = []
        var hasFailedRecordChanges = false
        var lastFailureCode: CKError.Code?

        for failedSave in event.failedRecordSaves {
            if !(await handleFailedRecordSave(failedSave, retryRecords: &retryRecords, retryZones: &retryZones)) {
                hasFailedRecordChanges = true
                lastFailureCode = failedSave.error.code
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
        }

        for (recordID, error) in event.failedRecordDeletes {
            let sentRevision = syncEngineCallbackGate.pendingDeleteAttempt(for: recordID.recordName,
                                                                            syncEngine: syncEngine)
            if handleFailedRecordDelete(recordID: recordID, error: error) {
                resolvedInitialUploadDeleteRecordIDs.append(recordID)
                if let sentRevision {
                    acknowledgedDeleteRevisions[recordID.recordName] = sentRevision
                }
            } else {
                hasFailedRecordChanges = true
                lastFailureCode = error.code
            }
        }

        if !retryZones.isEmpty {
            syncEngine.state.add(pendingDatabaseChanges: retryZones)
        }
        if !retryRecords.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: retryRecords)
        }
        do {
            try acknowledgeLocalOutboxDeletes(acknowledgedDeleteRevisions)
        } catch {
            guard generation == cloudAccountGeneration,
                  syncEngine === self.syncEngine else { return }
            handleLocalPersistenceFailure(error)
            return
        }
        syncEngineCallbackGate.acknowledgeDeleteAttempts(
            acknowledgedDeleteRevisions,
            generation: generation,
            for: syncEngine
        )
        recordInitialUploadRecordsResolved(resolvedInitialUploadDeleteRecordIDs)

        beginSyncActivity(.up)
        recordSyncActivity(event.savedRecords.filter { isUserDataRecordID($0.recordID) }.count
                           + event.deletedRecordIDs.filter { isUserDataRecordID($0) }.count)

        if hasFailedRecordChanges {
            hasUnresolvedSyncFailures = true
            postStateChanged()
            // Covers both real failures and the re-queued conflict/zone repairs above —
            // nothing else triggers the next send attempt.
            scheduleSyncRetryAfterFailure(code: lastFailureCode, reason: "failedRecordSends")
        } else if !hasUnresolvedSyncFailures {
            await queueNextInitialUploadPageDuringActiveSend()
            markSyncCompletedIfFinished()
        }
    }

    func acknowledgeLocalOutboxRecords(_ records: [CKRecord]) throws {
        var revisionsByRecordName: [String: String] = [:]
        for record in records {
            guard let payload = payloadDictionary(from: record),
                  let revision = payload[Self.localMutationRevisionPayloadKey] as? String,
                  !revision.isEmpty else { continue }
            revisionsByRecordName[record.recordID.recordName] = revision
        }
        try acknowledgeLocalOutboxOperations(revisionsByRecordName,
                                             expectedOperation: Self.localOutboxSaveOperation)
    }

    func acknowledgeLocalOutboxDeletes(_ revisionsByRecordName: [String: String]) throws {
        try acknowledgeLocalOutboxOperations(revisionsByRecordName,
                                             expectedOperation: Self.localOutboxDeleteOperation)
    }

    func acknowledgeLocalOutboxOperations(_ revisionsByRecordName: [String: String],
                                           expectedOperation: String) throws {
        guard !revisionsByRecordName.isEmpty else { return }
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              let context = databaseManager.objectContext else {
            throw Self.localOutboxStoreError(
                code: 1,
                description: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."
            )
        }
        let expandedRecordNames = revisionsByRecordName.keys.reduce(into: Set<String>()) { result, recordName in
            result.formUnion(Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName))
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
        request.predicate = NSPredicate(format: "accountRecordName == %@ AND recordName IN %@",
                                        accountRecordName, Array(expandedRecordNames))
        let entries = try context.fetch(request)
        var entriesByRecordName: [String: NSManagedObject] = [:]
        for entry in entries {
            guard let recordName = entry.value(forKey: "recordName") as? String else {
                throw Self.localOutboxStoreError(
                    code: 2,
                    description: "Ein lokaler iCloud-Outbox-Eintrag hat keine gültige Identität."
                )
            }
            entriesByRecordName[recordName] = entry
        }
        var completedRecordNames = Set<String>()
        var mustRequeueNewerRevision = false
        for (recordName, sentRevision) in revisionsByRecordName {
            guard let entry = entriesByRecordName[recordName] else { continue }
            guard let currentRevision = entry.value(forKey: "revision") as? String else {
                throw Self.localOutboxStoreError(
                    code: 2,
                    description: "Ein lokaler iCloud-Outbox-Eintrag hat keine gültige Revision."
                )
            }
            if currentRevision == sentRevision,
               entry.value(forKey: "operation") as? String == expectedOperation {
                completedRecordNames.insert(recordName)
                if entry.value(forKey: "category") as? String == Self.localOutboxSubscriptionCategory {
                    entry.setValue(true, forKey: "acknowledged")
                    if let snapshot = localOutboxSnapshotCache[recordName], snapshot.revision == sentRevision {
                        localOutboxSnapshotCache[recordName] = snapshot.replacingAcknowledged(true)
                    }
                } else {
                    context.delete(entry)
                    entriesByRecordName.removeValue(forKey: recordName)
                    localOutboxSnapshotCache.removeValue(forKey: recordName)
                }
            } else {
                mustRequeueNewerRevision = true
            }
        }

        for recordName in revisionsByRecordName.keys {
            let pair = Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName)
            guard pair.count == 2 else { continue }
            let pairEntries = pair.compactMap { entriesByRecordName[$0] }
            guard pairEntries.count == 2,
                  Set(pairEntries.compactMap { $0.value(forKey: "revision") as? String }).count == 1,
                  pairEntries.allSatisfy({ ($0.value(forKey: "acknowledged") as? Bool) == true }) else { continue }
            for pairEntry in pairEntries {
                if let pairRecordName = pairEntry.value(forKey: "recordName") as? String {
                    completedRecordNames.insert(pairRecordName)
                    entriesByRecordName.removeValue(forKey: pairRecordName)
                    localOutboxSnapshotCache.removeValue(forKey: pairRecordName)
                }
                context.delete(pairEntry)
            }
        }

        if context.hasChanges {
            if let error = databaseManager.saveReturningError() {
                throw error
            }
        }
        if !completedRecordNames.isEmpty {
            removePendingRecordChanges(recordNames: completedRecordNames)
        }
        if mustRequeueNewerRevision {
            scheduleLocalOutboxDrain()
        }
    }

    func remoteOutboxDecision(payload: [String: Any], recordName: String) -> RemoteOutboxDecision {
        let candidateRecordNames = Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName)
        let entries = candidateRecordNames.compactMap { localOutboxSnapshotCache[$0] }.filter {
            $0.accountRecordName == defaults.string(forKey: Self.accountUserRecordNameKey)
        }
        guard let entry = entries.max(by: { first, second in
            if first.changedAt != second.changedAt { return first.changedAt < second.changedAt }
            return first.operation == Self.localOutboxDeleteOperation
                && second.operation == Self.localOutboxSaveOperation
        }) else {
            return .applyRemote(discardedLocalMutation: false)
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        let remoteRevision = payload[Self.localMutationRevisionPayloadKey] as? String
        if remoteRevision == entry.revision {
            // A fetched save confirms only that exact half of a paired subscription intent;
            // its inverse physical delete remains durable until its own acknowledgement.
            if let exactEntry = localOutboxSnapshotCache[recordName],
               exactEntry.revision == entry.revision,
               exactEntry.operation == Self.localOutboxSaveOperation {
                localOutboxSnapshotCache[recordName] = exactEntry.replacingAcknowledged(true)
                localOutboxRevisionsToAcknowledge[recordName] = exactEntry.revision
            }
            return .applyRemote(discardedLocalMutation: false)
        }
        if remoteDate.compare(entry.changedAt) == .orderedDescending {
            for candidate in entries where candidate.revision == entry.revision {
                localOutboxSnapshotCache.removeValue(forKey: candidate.recordName)
                localOutboxRevisionsToDelete[candidate.recordName] = candidate.revision
            }
            return .applyRemote(discardedLocalMutation: true)
        }
        if let exactEntry = localOutboxSnapshotCache[recordName],
           exactEntry.revision == entry.revision,
           exactEntry.acknowledged {
            // Seeing a conflicting physical record proves that this half is no longer
            // satisfied, even if CloudKit acknowledged it earlier. Re-arm the exact
            // save/delete operation before draining the durable pair again.
            localOutboxSnapshotCache[recordName] = exactEntry.replacingAcknowledged(false)
            localOutboxRevisionsToAcknowledge.removeValue(forKey: recordName)
            localOutboxRevisionsToRearm[recordName] = exactEntry.revision
        }
        scheduleLocalOutboxDrain()
        return .keepLocal
    }

    func localSubscriptionOutboxIntent(for recordName: String) -> ICCloudSyncOutboxSnapshot? {
        let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey)
        return Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName)
            .compactMap { localOutboxSnapshotCache[$0] }
            .filter { $0.accountRecordName == accountRecordName }
            .max { first, second in
                if first.changedAt != second.changedAt { return first.changedAt < second.changedAt }
                return first.operation == Self.localOutboxDeleteOperation
                    && second.operation == Self.localOutboxSaveOperation
            }
    }

    func hasCompleteLocalSubscriptionOutboxPair(for recordName: String) -> Bool {
        let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey)
        let entries = Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName)
            .compactMap { localOutboxSnapshotCache[$0] }
            .filter { $0.accountRecordName == accountRecordName }
        return entries.count == 2 && Set(entries.map(\.revision)).count == 1
    }

    func deleteResolvedLocalOutboxEntries() throws -> LocalOutboxResolutionCommit {
        guard !localOutboxRevisionsToDelete.isEmpty
                || !localOutboxRevisionsToAcknowledge.isEmpty
                || !localOutboxRevisionsToRearm.isEmpty else { return .empty }
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              let context = databaseManager.objectContext else {
            throw Self.localOutboxStoreError(
                code: 1,
                description: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."
            )
        }
        let revisionsToDelete = localOutboxRevisionsToDelete
        let revisionsToAcknowledge = localOutboxRevisionsToAcknowledge
        let revisionsToRearm = localOutboxRevisionsToRearm
        let requestedRecordNames = Set(revisionsToDelete.keys)
            .union(revisionsToAcknowledge.keys)
            .union(revisionsToRearm.keys)
        let expandedRecordNames = requestedRecordNames.reduce(into: Set<String>()) { result, recordName in
            result.formUnion(Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName))
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
        request.predicate = NSPredicate(format: "accountRecordName == %@ AND recordName IN %@",
                                        accountRecordName, Array(expandedRecordNames))
        let entries = try context.fetch(request)
        var entriesByRecordName: [String: NSManagedObject] = [:]
        for entry in entries {
            guard let recordName = entry.value(forKey: "recordName") as? String else {
                throw Self.localOutboxStoreError(
                    code: 2,
                    description: "Ein lokaler iCloud-Outbox-Eintrag hat keine gültige Identität."
                )
            }
            entriesByRecordName[recordName] = entry
        }
        var completedRecordNames = Set<String>()
        for entry in entries {
            guard let recordName = entry.value(forKey: "recordName") as? String,
                  let currentRevision = entry.value(forKey: "revision") as? String else {
                throw Self.localOutboxStoreError(
                    code: 2,
                    description: "Ein lokaler iCloud-Outbox-Eintrag hat keine gültige Revision."
                )
            }
            if revisionsToDelete[recordName] == currentRevision {
                context.delete(entry)
                completedRecordNames.insert(recordName)
                entriesByRecordName.removeValue(forKey: recordName)
                localOutboxSnapshotCache.removeValue(forKey: recordName)
            } else if revisionsToRearm[recordName] == currentRevision {
                entry.setValue(false, forKey: "acknowledged")
            } else if revisionsToAcknowledge[recordName] == currentRevision {
                if entry.value(forKey: "category") as? String == Self.localOutboxSubscriptionCategory {
                    entry.setValue(true, forKey: "acknowledged")
                } else {
                    context.delete(entry)
                    completedRecordNames.insert(recordName)
                    entriesByRecordName.removeValue(forKey: recordName)
                    localOutboxSnapshotCache.removeValue(forKey: recordName)
                }
            }
        }
        for recordName in requestedRecordNames {
            let pair = Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName)
            let pairEntries = pair.compactMap { entriesByRecordName[$0] }
            guard pairEntries.count == 2,
                  Set(pairEntries.compactMap { $0.value(forKey: "revision") as? String }).count == 1,
                  pairEntries.allSatisfy({ ($0.value(forKey: "acknowledged") as? Bool) == true }) else { continue }
            for pairEntry in pairEntries {
                if let pairRecordName = pairEntry.value(forKey: "recordName") as? String {
                    completedRecordNames.insert(pairRecordName)
                    localOutboxSnapshotCache.removeValue(forKey: pairRecordName)
                    entriesByRecordName.removeValue(forKey: pairRecordName)
                }
                context.delete(pairEntry)
            }
        }
        return LocalOutboxResolutionCommit(
            revisionsToDelete: revisionsToDelete,
            revisionsToAcknowledge: revisionsToAcknowledge,
            revisionsToRearm: revisionsToRearm,
            completedRecordNames: completedRecordNames
        )
    }

    func consumeResolvedLocalOutboxEntries(_ commit: LocalOutboxResolutionCommit) {
        for (recordName, revision) in commit.revisionsToDelete
        where localOutboxRevisionsToDelete[recordName] == revision {
            localOutboxRevisionsToDelete.removeValue(forKey: recordName)
        }
        for (recordName, revision) in commit.revisionsToAcknowledge
        where localOutboxRevisionsToAcknowledge[recordName] == revision {
            localOutboxRevisionsToAcknowledge.removeValue(forKey: recordName)
        }
        for (recordName, revision) in commit.revisionsToRearm
        where localOutboxRevisionsToRearm[recordName] == revision {
            localOutboxRevisionsToRearm.removeValue(forKey: recordName)
        }
        if !commit.completedRecordNames.isEmpty {
            removePendingRecordChanges(recordNames: commit.completedRecordNames)
        }
    }

    func handleFailedRecordSave(_ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
                                        retryRecords: inout [CKSyncEngine.PendingRecordZoneChange],
                                        retryZones: inout [CKSyncEngine.PendingDatabaseChange]) async -> Bool {
        let generation = cloudAccountGeneration
        let recordID = failedSave.record.recordID
        switch failedSave.error.code {
        case .serverRecordChanged:
            if let serverRecord = failedSave.error.serverRecord {
                guard await applyRemoteRecord(serverRecord) else { return false }
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return true }
                let isSubscriptionConflictRecord = serverRecord.recordType == RecordKind.subscription
                    || serverRecord.recordType == RecordKind.subscriptionTombstone
                    || serverRecord.recordType == RecordKind.subscriptionListSettings
                if isSubscriptionConflictRecord {
                    // A conflict contains only one physical half of the logical feed state.
                    // Keep the local operation and its initial-page checkpoint queued. The
                    // durable incomplete-fetch gate blocks the retry until a full fetch has
                    // resolved active record and tombstone together. Only the later successful
                    // save may advance the cursor; otherwise a kill before CKSyncEngine's next
                    // state serialization could skip this feed permanently.
                    retryRecords.append(.saveRecord(recordID))
                    return true
                }

                let sentRevision = payloadDictionary(from: failedSave.record)?[Self.localMutationRevisionPayloadKey] as? String
                let currentEntry = localOutboxSnapshotCache[recordID.recordName]
                let sentSaveWasResolved = currentEntry == nil
                    || (currentEntry?.revision == sentRevision && currentEntry?.acknowledged == true)
                if sentRevision != nil, sentSaveWasResolved {
                    // The server won LWW (or echoed this exact revision). Persist the
                    // applied state and resolved outbox, and do not resurrect the loser.
                    let outboxResolution: LocalOutboxResolutionCommit
                    do {
                        outboxResolution = try deleteResolvedLocalOutboxEntries()
                    } catch {
                        handleLocalPersistenceFailure(error)
                        return false
                    }
                    if let error = databaseManager.saveReturningError() {
                        handleLocalPersistenceFailure(error)
                        return false
                    }
                    consumeResolvedLocalOutboxEntries(outboxResolution)
                    recordInitialUploadRecordsSaved([recordID])
                    return true
                }
                retryRecords.append(.saveRecord(recordID))
            } else {
                setError(failedSave.error)
            }
            return false
        case .zoneNotFound:
            retryZones.append(.saveZone(CKRecordZone(zoneID: recordID.zoneID)))
            retryRecords.append(.saveRecord(recordID))
            return false
        case .unknownItem:
            retryRecords.append(.saveRecord(recordID))
            return false
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            handleCloudKitSendError(failedSave.error)
            return false
        default:
            setError(failedSave.error)
            return false
        }
    }

    func handleFailedRecordDelete(recordID: CKRecord.ID, error: CKError) -> Bool {
        switch error.code {
        case .unknownItem, .zoneNotFound:
            return true
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            handleCloudKitSendError(error)
            return false
        default:
            setError(error)
            return false
        }
    }

    func handleCloudKitSendError(_ error: CKError) {
        switch error.code {
        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited:
            setError(error)
        default:
            setError(error)
        }
    }

    func applyRemoteNonEpisodeRecord(_ record: CKRecord) {
        guard let payload = payloadDictionary(from: record) else { return }
        switch record.recordType {
        case RecordKind.device:
            updateDeviceCache(with: payload)
        case RecordKind.appSettings:
            if settingsSyncEnabled { applyRemoteAppSettings(payload) }
        case RecordKind.listScrollPositions:
            if episodesSyncEnabled { applyRemoteListScrollPositions(payload) }
        default:
            break
        }
    }

    @discardableResult
    func applyRemoteRecord(_ record: CKRecord) async -> Bool {
        guard let payload = payloadDictionary(from: record) else { return true }
        let generation = cloudAccountGeneration
        var stagedEpisodeStates: [ICCloudPendingEpisodeStateSnapshot] = []
        if record.recordType == RecordKind.episodeState {
            do {
                guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
                    throw Self.pendingEpisodeStateStoreError(
                        code: 1,
                        description: NSLocalizedString(
                            "Der iCloud-Account für empfangene Episodenstatus konnte nicht bestimmt werden.",
                            comment: ""
                        )
                    )
                }
                let payloadData = try PropertyListSerialization.data(
                    fromPropertyList: payload,
                    format: .binary,
                    options: 0
                )
                stagedEpisodeStates = try await Self.stagePendingEpisodeStates(
                    accountRecordName: accountRecordName,
                    writes: [ICCloudPendingEpisodeStateWrite(
                        recordName: record.recordID.recordName,
                        payloadData: payloadData
                    )]
                )
            } catch {
                handleLocalPersistenceFailure(error)
                return false
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return false }
        } else if record.recordType == RecordKind.subscription
                    || record.recordType == RecordKind.subscriptionTombstone
                    || record.recordType == RecordKind.subscriptionListSettings {
            do {
                guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
                    throw Self.pendingSubscriptionStateStoreError(
                        code: 1,
                        description: NSLocalizedString(
                            "Der iCloud-Account für empfangene Abonnements konnte nicht bestimmt werden.",
                            comment: ""
                        )
                    )
                }
                let payloadData = try PropertyListSerialization.data(
                    fromPropertyList: payload,
                    format: .binary,
                    options: 0
                )
                markPendingSubscriptionFetchIncomplete()
                _ = try await Self.stagePendingSubscriptionStates(
                    accountRecordName: accountRecordName,
                    writes: [ICCloudPendingSubscriptionStateWrite(
                        recordName: record.recordID.recordName,
                        payloadData: payloadData
                    )]
                )
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
                    return false
                }
            } catch {
                handleLocalPersistenceFailure(error)
                return false
            }
        }
        var appliedEpisodeRecordNames = Set<String>()
        do {
            let didFlush = try performSynchronousRemoteApplyBatch {
                switch record.recordType {
                case RecordKind.device:
                    updateDeviceCache(with: payload)

                case RecordKind.episodeState:
                    guard episodesSyncEnabled else { break }
                    guard let context = databaseManager.objectContext,
                          let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
                        throw Self.syncItemMetadataStoreError(
                            code: 1,
                            description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
                        )
                    }
                    var metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
                        accountRecordName: accountRecordName,
                        recordNames: [record.recordID.recordName],
                        context: context
                    )
                    let resolvedEpisode = episode(for: payload)
                    if let episode = resolvedEpisode,
                       let objectHash = payload["objectHash"] as? String {
                        let identityWrite = try Self.episodeSyncItemMetadataIdentityWrite(
                            recordName: record.recordID.recordName,
                            objectHash: objectHash
                        )
                        try Self.upsertSyncItemMetadata(
                            [identityWrite],
                            updating: [],
                            metadataBatch: &metadataBatch,
                            context: context
                        )
                        let localMetadata = try Self.syncItemMetadataSnapshot(
                            forRecordName: record.recordID.recordName,
                            metadataBatch: metadataBatch
                        )
                        if let update = applyRemoteEpisodeState(
                            payload,
                            recordName: record.recordID.recordName,
                            localModifiedAt: localMetadata?.localModifiedAt,
                            resolvedEpisode: episode,
                            lookupEpisodeIfNeeded: false
                        ) {
                            try Self.upsertSyncItemMetadata(
                                [ICCloudSyncItemMetadataWrite(
                                    category: Self.localOutboxEpisodeCategory,
                                    recordName: record.recordID.recordName,
                                    itemIdentifier: update.objectHash,
                                    localModifiedAt: update.date,
                                    localState: nil,
                                    payloadHash: nil
                                )],
                                metadataBatch: &metadataBatch,
                                context: context
                            )
                        }
                        appliedEpisodeRecordNames.insert(record.recordID.recordName)
                    }

                case RecordKind.subscription, RecordKind.subscriptionTombstone:
                    break

                case RecordKind.appSettings:
                    if settingsSyncEnabled {
                        applyRemoteAppSettings(payload)
                    }

                case RecordKind.listScrollPositions:
                    if episodesSyncEnabled {
                        applyRemoteListScrollPositions(payload)
                    }

                case RecordKind.subscriptionListSettings:
                    break

                default:
                    break
                }
            }
            guard didFlush else { return false }
        } catch {
            handleLocalPersistenceFailure(error)
            return false
        }
        // serverRecordChanged enters this method outside the fetch loop. Commit before
        // dropping origin suppression; raw episode/subscription payloads remain staged if
        // the save fails and are replayed by the normal pending path.
        let appliedEpisodeStates = stagedEpisodeStates.filter {
            appliedEpisodeRecordNames.contains($0.recordName)
        }
        do {
            _ = try await Self.removePendingEpisodeStates(appliedEpisodeStates)
        } catch {
            handleLocalPersistenceFailure(error)
            return false
        }
        return true
    }

    @discardableResult
    func applyRemoteSubscriptionListSettings(_ payload: [String: Any]) -> Bool {
        let remoteSortMode = (payload["sortMode"] as? String) ?? ""
        let remoteManualOrder = (payload["manualOrder"] as? [String]) ?? []
        let remoteEpisodeLists = (payload["episodeLists"] as? [[String: Any]]) ?? []
        let hasRemoteEpisodeLists = !remoteEpisodeLists.isEmpty
        let hasRemoteMainMenuListUIDs = payload.keys.contains("mainMenuListUIDs")
        // An EMPTY record (published by a pre-fix build on a freshly installed device)
        // must not win last-writer-wins against a real local state: ignore it entirely —
        // applying it would re-stamp localModifiedDate/baseline and silence this device
        // forever — and push the real local state back up instead.
        guard !remoteSortMode.isEmpty || !remoteManualOrder.isEmpty || hasRemoteEpisodeLists || hasRemoteMainMenuListUIDs else {
            if Self.hasLocalSubscriptionListSettings() {
                addPendingSave(subscriptionListSettingsRecordID())
            }
            return true
        }
        // A record WITHOUT a manual order must never displace a local manual-order
        // state, regardless of its timestamp: it carries strictly less information
        // (sort-mode-only devices, e.g. one where the user tried the sort menu while
        // "Manual" was still missing) and would flip the active mode on the device
        // that owns the real order. If the record also carries episode-list settings,
        // merge those and push the richer local sort state back up afterwards.
        var shouldApplySortSettings = true
        var shouldRepairSortSettings = false
        if remoteManualOrder.isEmpty,
           defaults.string(forKey: FeedListSortMode) == "manual",
           databaseManager.hasManualFeedOrder() {
            guard hasRemoteEpisodeLists || hasRemoteMainMenuListUIDs else {
                addPendingSave(subscriptionListSettingsRecordID())
                return true
            }
            shouldApplySortSettings = false
            shouldRepairSortSettings = true
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = defaults.object(forKey: Self.subscriptionListSettingsLocalModifiedDateKey) as? Date,
           localDate.compare(remoteDate) == .orderedDescending {
            // Only defend the local state if one actually exists — a pre-fix build may
            // have stamped localModifiedDate on a device that has nothing to defend.
            if Self.hasLocalSubscriptionListSettings() {
                addPendingSave(subscriptionListSettingsRecordID())
                return true
            }
        }
        if shouldApplySortSettings, !remoteSortMode.isEmpty {
            defaults.set(remoteSortMode, forKey: FeedListSortMode)
        }
        if shouldApplySortSettings, !remoteManualOrder.isEmpty {
            defaults.set(remoteManualOrder, forKey: Self.manualFeedOrderDefaultsKey)
        }
        let resolvedEpisodeListFeeds = hasRemoteEpisodeLists ? applyRemoteEpisodeLists(remoteEpisodeLists) : true
        if hasRemoteMainMenuListUIDs {
            let mainMenuListUIDs = (payload["mainMenuListUIDs"] as? [String]) ?? []
            _ = applyRemoteMainMenuListUIDs(mainMenuListUIDs)
        }
        guard resolvedEpisodeListFeeds else {
            return false
        }
        setSyncMetadata(shouldRepairSortSettings ? Date() : remoteDate, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
        // Re-baseline so applying the payload doesn't read as a local change and echo back.
        setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
        // The actual reordering happens once at the end of the apply batch, after all
        // subscription records (and their stub feeds) of this fetch exist.
        if shouldApplySortSettings {
            needsSubscriptionListSortApply = true
        }
        if shouldRepairSortSettings {
            addPendingSave(subscriptionListSettingsRecordID())
        }
        return true
    }

    // Writing the defaults alone changes nothing visible: the feed list orders by the
    // feeds' rank values. Replay the synced manual order onto the ranks once the apply
    // batch is done — that also makes "Manual" appear (and be checked) in the sort menu.
    func applySubscriptionListSortIfNeeded() async -> Bool {
        guard needsSubscriptionListSortApply else { return true }
        needsSubscriptionListSortApply = false
        guard defaults.string(forKey: FeedListSortMode) == "manual",
              databaseManager.hasManualFeedOrder() else { return true }
        guard let context = databaseManager.objectContext,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
            handleLocalPersistenceFailure(Self.syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
            ))
            needsSubscriptionListSortApply = true
            return false
        }

        // Build the target order linearly. The old Objective-C restore nested every saved
        // URL over every feed (O(n²)) and saved all ranks in one main-context transaction.
        let feeds = (databaseManager.feeds as? [CDFeed]) ?? []
        let savedURLs = defaults.array(forKey: Self.manualFeedOrderDefaultsKey) as? [String] ?? []
        var feedByURL: [String: CDFeed] = [:]
        for feed in feeds {
            if let feedURL = feed.sourceURL?.absoluteString,
               feedByURL[feedURL] == nil {
                feedByURL[feedURL] = feed
            }
        }
        var orderedFeeds: [CDFeed] = []
        orderedFeeds.reserveCapacity(feeds.count)
        var includedObjectIDs = Set<NSManagedObjectID>()
        for feedURL in savedURLs {
            guard let feed = feedByURL[feedURL],
                  includedObjectIDs.insert(feed.objectID).inserted else { continue }
            orderedFeeds.append(feed)
        }
        for feed in feeds where includedObjectIDs.insert(feed.objectID).inserted {
            orderedFeeds.append(feed)
        }

        let generation = cloudAccountGeneration
        var index = orderedFeeds.startIndex
        while index < orderedFeeds.endIndex {
            let end = orderedFeeds.index(
                index,
                offsetBy: Self.remoteApplyBatchSize,
                limitedBy: orderedFeeds.endIndex
            ) ?? orderedFeeds.endIndex
            let chunk = Array(orderedFeeds[index..<end])
            let recordNames = Set(chunk.compactMap { feed -> String? in
                guard feed.subscribed,
                      let feedURL = feed.sourceURL?.absoluteString else { return nil }
                return Self.subscriptionRecordName(forFeedURL: feedURL)
            })
            do {
                let didFlush = try performSynchronousRemoteApplyBatch {
                    var metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
                        accountRecordName: accountRecordName,
                        recordNames: recordNames,
                        context: context
                    )
                    var hashWrites: [ICCloudSyncItemMetadataWrite] = []
                    hashWrites.reserveCapacity(recordNames.count)
                    for (offset, feed) in chunk.enumerated() {
                        let rank = Int32(index + offset)
                        if feed.rank != rank {
                            feed.rank = rank
                            remoteAppliedObjectIDs.insert(feed.objectID)
                        }
                        guard feed.subscribed,
                              let feedURL = feed.sourceURL?.absoluteString else { continue }
                        hashWrites.append(ICCloudSyncItemMetadataWrite(
                            category: Self.localOutboxSubscriptionCategory,
                            recordName: Self.subscriptionRecordName(forFeedURL: feedURL),
                            itemIdentifier: feedURL,
                            localModifiedAt: nil,
                            localState: nil,
                            payloadHash: subscriptionPayloadHash(for: feed)
                        ))
                    }
                    try Self.upsertSyncItemMetadata(
                        hashWrites,
                        updating: [.payloadHash],
                        metadataBatch: &metadataBatch,
                        context: context
                    )
                }
                guard didFlush else {
                    needsSubscriptionListSortApply = true
                    return false
                }
            } catch {
                handleLocalPersistenceFailure(error)
                needsSubscriptionListSortApply = true
                return false
            }
            index = end
            if index < orderedFeeds.endIndex {
                await Task.yield()
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified,
                      subscriptionsSyncEnabled,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
                    return false
                }
            }
        }
        logSyncEvent("Synchronisierte Sortierreihenfolge angewendet")
        return true
    }

    func applyRemoteEpisodeLists(_ payloads: [[String: Any]]) -> Bool {
        guard !payloads.isEmpty, let context = databaseManager.objectContext else { return true }
        let uids = payloads.compactMap { $0["uid"] as? String }.filter { !$0.isEmpty }
        guard !uids.isEmpty else { return true }

        let request = NSFetchRequest<CDEpisodeList>(entityName: "EpisodeList")
        request.predicate = NSPredicate(format: "uid IN %@", uids)
        request.includesSubentities = false
        let existingLists = (try? context.fetch(request)) ?? []
        var listsByUID: [String: CDEpisodeList] = [:]
        for list in existingLists {
            if let uid = list.uid {
                listsByUID[uid] = list
            }
        }

        let allIncludedFeedURLs = Set(payloads.flatMap { ($0["includedFeedURLs"] as? [String]) ?? [] })
        var feedsByURL: [String: CDFeed] = [:]
        if !allIncludedFeedURLs.isEmpty {
            let feedRequest = NSFetchRequest<CDFeed>(entityName: "Feed")
            feedRequest.predicate = NSPredicate(format: "sourceURL_ IN %@", Array(allIncludedFeedURLs))
            feedRequest.includesSubentities = false
            let feeds = (try? context.fetch(feedRequest)) ?? []
            for feed in feeds {
                if let urlString = feed.value(forKey: "sourceURL_") as? String {
                    feedsByURL[urlString] = feed
                }
            }
        }

        var missingFeedURLs = Set<String>()
        var didMutateAnyList = false
        for payload in payloads {
            guard let uid = payload["uid"] as? String, !uid.isEmpty else { continue }
            let list: CDEpisodeList
            if let existingList = listsByUID[uid] {
                list = existingList
            } else if let newList = NSEntityDescription.insertNewObject(forEntityName: "EpisodeList", into: context) as? CDEpisodeList {
                list = newList
                listsByUID[uid] = newList
            } else {
                continue
            }
            let result = applyRemoteEpisodeListPayload(payload, to: list, feedsByURL: feedsByURL)
            missingFeedURLs.formUnion(result.missingFeedURLs)
            didMutateAnyList = didMutateAnyList || result.didMutate
        }

        if !missingFeedURLs.isEmpty {
            logSyncEvent("Listen-Einstellungen warten auf Abos", metadata: [
                "missingFeedURLCount": missingFeedURLs.count,
            ])
            return false
        }
        if didMutateAnyList {
            NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
        }
        return true
    }

    func applyRemoteEpisodeListPayload(_ payload: [String: Any], to list: CDEpisodeList, feedsByURL: [String: CDFeed]) -> (missingFeedURLs: Set<String>, didMutate: Bool) {
        var didMutate = false
        var missingFeedURLs = Set<String>()

        if let uid = payload["uid"] as? String, list.uid != uid {
            list.uid = uid
            didMutate = true
        }
        if let name = payload["name"] as? String, list.name != name {
            list.name = name
            didMutate = true
        }
        if let icon = payload["icon"] as? String, list.icon != icon {
            list.icon = icon
            didMutate = true
        }
        if let rank = Self.int32Value(payload["rank"]), list.rank != rank {
            list.rank = rank
            didMutate = true
        }
        if let queryValue = payload["query"] as? String {
            let query = queryValue.isEmpty ? nil : queryValue
            if list.query != query {
                list.query = query
                didMutate = true
            }
        }
        if let audio = Self.boolValue(payload["audio"]), list.audio != audio {
            list.audio = audio
            didMutate = true
        }
        if let video = Self.boolValue(payload["video"]), list.video != video {
            list.video = video
            didMutate = true
        }
        if let downloaded = Self.boolValue(payload["downloaded"]), list.downloaded != downloaded {
            list.downloaded = downloaded
            didMutate = true
        }
        if let downloading = Self.boolValue(payload["downloading"]), list.downloading != downloading {
            list.downloading = downloading
            didMutate = true
        }
        if let notDownloaded = Self.boolValue(payload["notDownloaded"]), list.notDownloaded != notDownloaded {
            list.notDownloaded = notDownloaded
            didMutate = true
        }
        if let unplayed = Self.boolValue(payload["unplayed"]), list.unplayed != unplayed {
            list.unplayed = unplayed
            didMutate = true
        }
        if let unfinished = Self.boolValue(payload["unfinished"]), list.unfinished != unfinished {
            list.unfinished = unfinished
            didMutate = true
        }
        if let played = Self.boolValue(payload["played"]), list.played != played {
            list.played = played
            didMutate = true
        }
        if let starred = Self.boolValue(payload["starred"]), list.starred != starred {
            list.starred = starred
            didMutate = true
        }
        if let notStarred = Self.boolValue(payload["notStarred"]), list.notStarred != notStarred {
            list.notStarred = notStarred
            didMutate = true
        }
        if let orderBy = payload["orderBy"] as? String, list.orderBy != orderBy {
            list.orderBy = orderBy
            didMutate = true
        }
        if let descending = Self.boolValue(payload["descending"]), list.descending != descending {
            list.descending = descending
            didMutate = true
        }
        if let groupByPodcast = Self.boolValue(payload["groupByPodcast"]), list.groupByPodcast != groupByPodcast {
            list.groupByPodcast = groupByPodcast
            didMutate = true
        }
        if let continuousPlayback = Self.boolValue(payload["continuousPlayback"]), list.continuousPlayback != continuousPlayback {
            list.continuousPlayback = continuousPlayback
            didMutate = true
        }

        if let includedFeedURLs = payload["includedFeedURLs"] as? [String] {
            let includedFeedURLSet = Set(includedFeedURLs)
            var feeds: [CDFeed] = []
            for urlString in includedFeedURLSet {
                if let feed = feedsByURL[urlString] {
                    feeds.append(feed)
                } else {
                    missingFeedURLs.insert(urlString)
                }
            }
            if missingFeedURLs.isEmpty {
                let currentFeedURLs = Set(((list.includedFeeds as? Set<CDFeed>) ?? []).compactMap { $0.sourceURL?.absoluteString })
                if currentFeedURLs != includedFeedURLSet {
                    let includedFeeds = Set(feeds)
                    list.includedFeeds = includedFeeds
                    didMutate = true
                }
            }
        }

        if didMutate {
            remoteAppliedObjectIDs.insert(list.objectID)
            list.invalidateCaches()
        }
        return (missingFeedURLs, didMutate)
    }

    func applyRemoteMainMenuListUIDs(_ mainMenuListUIDs: [String]) -> Bool {
        let currentUIDs = defaults.array(forKey: "MainMenuListUIDs") as? [String] ?? []
        guard currentUIDs != mainMenuListUIDs else { return false }
        defaults.set(mainMenuListUIDs, forKey: "MainMenuListUIDs")
        NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
        return true
    }

    func subscriptionSyncItemMetadata(
        for feedURL: String,
        metadataBatch: ICCloudSyncItemMetadataContextBatch
    ) throws -> ICCloudSyncItemMetadataSnapshot? {
        try Self.syncItemMetadataSnapshot(
            forRecordName: Self.subscriptionRecordName(forFeedURL: feedURL),
            metadataBatch: metadataBatch
        )
    }

    func ensureSubscriptionSyncItemMetadataMapping(
        feedURL: String,
        recordName: String,
        metadataBatch: inout ICCloudSyncItemMetadataContextBatch
    ) throws {
        let activeRecordName = Self.subscriptionRecordName(forFeedURL: feedURL)
        let tombstoneRecordName = Self.subscriptionTombstoneRecordName(forFeedURL: feedURL)
        guard recordName == activeRecordName || recordName == tombstoneRecordName else {
            throw Self.syncItemMetadataStoreError(
                code: 3,
                description: "Ein empfangenes iCloud-Abo hat eine widersprüchliche Identität."
            )
        }
        let context = metadataBatch.context
        try Self.upsertSyncItemMetadata(
            [ICCloudSyncItemMetadataWrite(
                category: Self.localOutboxSubscriptionCategory,
                recordName: recordName,
                itemIdentifier: feedURL,
                localModifiedAt: nil,
                localState: nil,
                payloadHash: nil
            )],
            updating: [],
            metadataBatch: &metadataBatch,
            context: context
        )
    }

    func updateSubscriptionSyncItemMetadata(
        feedURL: String,
        localModifiedAt: Date?,
        localState: Bool?,
        payloadHash: String?,
        updating fields: ICCloudSyncItemMetadataUpdateFields = .all,
        metadataBatch: inout ICCloudSyncItemMetadataContextBatch
    ) throws {
        let context = metadataBatch.context
        try Self.upsertSyncItemMetadata(
            [ICCloudSyncItemMetadataWrite(
                category: Self.localOutboxSubscriptionCategory,
                recordName: Self.subscriptionRecordName(forFeedURL: feedURL),
                itemIdentifier: feedURL,
                localModifiedAt: localModifiedAt,
                localState: localState,
                payloadHash: payloadHash
            )],
            updating: fields,
            metadataBatch: &metadataBatch,
            context: context
        )
    }

    func applyRemoteDeletion(
        _ deletion: CKDatabase.RecordZoneChange.Deletion,
        metadataBatch: ICCloudSyncItemMetadataContextBatch
    ) throws {
        if deletion.recordType == RecordKind.device {
            let deletedDeviceID = String(deletion.recordID.recordName.dropFirst(RecordPrefix.device.count))
            removeDeviceFromCache(deletedDeviceID)
            if deletedDeviceID == deviceID {
                // Another device removed THIS one (it cannot tell which entry is the
                // live install) — re-announce ourselves so the lists stay truthful.
                queueDeviceRecord()
            }
            return
        }
        if deletion.recordType == RecordKind.subscription
            || deletion.recordType == RecordKind.subscriptionTombstone {
            if observeRemoteSubscriptionDeletionAgainstOutbox(recordName: deletion.recordID.recordName) {
                return
            }
        }
        if deletion.recordType == RecordKind.subscriptionTombstone {
            // Resubscribing deletes the tombstone record. That is cloud bookkeeping only;
            // it must never unsubscribe the local feed.
            return
        }
        if deletion.recordType == RecordKind.subscription && subscriptionsSyncEnabled {
            let recordName = deletion.recordID.recordName
            // Deletions are only propagated "live": the catch-up fetch right after
            // (re-)enabling subscription sync may carry deletions from while sync was
            // off — applying those would surprise-delete local subscriptions.
            guard !defaults.bool(forKey: Self.suppressSubscriptionDeletionsKey) else {
                logSyncEvent("Abo-Löschung unterdrückt (Nachhol-Fetch nach Aktivierung)", metadata: [
                    "recordName": recordName,
                ])
                return
            }
        }
    }

    func isPendingLegacySubscriptionDeletion(_ payload: [String: Any]) -> Bool {
        (payload["legacyPhysicalDelete"] as? Bool) == true
    }

    @discardableResult
    func applyPendingLegacySubscriptionDeletion(_ payload: [String: Any],
                                                recordName: String,
                                                metadataBatch: inout ICCloudSyncItemMetadataContextBatch) throws -> Bool {
        guard let feedURL = payload["feedURL"] as? String, !feedURL.isEmpty else { return true }
        try ensureSubscriptionSyncItemMetadataMapping(
            feedURL: feedURL,
            recordName: recordName,
            metadataBatch: &metadataBatch
        )
        if defaults.bool(forKey: Self.suppressSubscriptionDeletionsKey) {
            logSyncEvent("Abo-Löschung unterdrückt (Nachhol-Fetch nach Aktivierung)", metadata: [
                "recordName": recordName,
            ])
            return true
        }
        // A local edit can be committed after the delete was fetched but before the
        // complete fetch resolves it. Re-check the durable pair immediately before the
        // destructive cleanup and re-arm it instead of overwriting the user's edit.
        if observeRemoteSubscriptionDeletionAgainstOutbox(recordName: recordName) {
            return true
        }
        let localMetadata = try subscriptionSyncItemMetadata(
            for: feedURL,
            metadataBatch: metadataBatch
        )
        try updateSubscriptionSyncItemMetadata(
            feedURL: feedURL,
            localModifiedAt: localMetadata?.localModifiedAt,
            localState: false,
            payloadHash: nil,
            updating: [.localState, .payloadHash],
            metadataBatch: &metadataBatch
        )
        if let url = URL(string: feedURL),
           let feed = databaseManager.feed(withSourceURL: url) {
            remoteAppliedObjectIDs.insert(feed.objectID)
            subscriptionManager.unsubscribeFeed(feed)
        }
        // A released client deletion has no logical timestamp. The row update above keeps
        // the last clock so an older timestamped save cannot resurrect it.
        return true
    }

    func observeRemoteSubscriptionDeletionAgainstOutbox(recordName: String) -> Bool {
        guard localSubscriptionOutboxIntent(for: recordName) != nil else { return false }
        if let exactEntry = localOutboxSnapshotCache[recordName] {
            if exactEntry.operation == Self.localOutboxDeleteOperation {
                localOutboxSnapshotCache[recordName] = exactEntry.replacingAcknowledged(true)
                localOutboxRevisionsToAcknowledge[recordName] = exactEntry.revision
            } else {
                // A released client removed a record that this logical intent requires.
                // Re-arm an already-confirmed save and publish the full pair again.
                localOutboxSnapshotCache[recordName] = exactEntry.replacingAcknowledged(false)
                localOutboxRevisionsToRearm[recordName] = exactEntry.revision
                scheduleLocalOutboxDrain()
            }
        } else {
            scheduleLocalOutboxDrain()
        }
        logSyncEvent("Abo-Löschung gegen lokale Outbox abgeglichen", metadata: [
            "recordName": recordName,
        ])
        return true
    }

    @discardableResult
    func applyRemoteEpisodeState(_ payload: [String: Any], recordName: String,
                                 localModifiedAt: Date?,
                                 resolvedEpisode: CDEpisode? = nil,
                                 lookupEpisodeIfNeeded: Bool = true) -> EpisodeClockUpdate? {
        guard let objectHash = payload["objectHash"] as? String, !objectHash.isEmpty else { return nil }
        let discardedLocalMutation: Bool
        switch remoteOutboxDecision(payload: payload, recordName: recordName) {
        case .keepLocal:
            return nil
        case .applyRemote(let discarded):
            discardedLocalMutation = discarded
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if !discardedLocalMutation,
           let localDate = localModifiedAt,
           localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(episodeRecordID(forObjectHash: objectHash))
            return nil
        }

        let episode = resolvedEpisode ?? (lookupEpisodeIfNeeded ? episode(for: payload) : nil)
        guard let episode else { return nil }

        var played = (payload["played"] as? Bool) ?? false
        var starred = (payload["starred"] as? Bool) ?? false
        var position = max(0, (payload["position"] as? NSNumber)?.int32Value ?? Int32((payload["position"] as? Int) ?? 0))

        // First reconciliation: an episode WITHOUT a sync date has never been part of
        // the sync dialog — its local state is an independent stand, not an outdated
        // one. Merge by content instead of timestamp (user decision 12.06.): heard
        // beats unheard, the farther playback position wins, favorite beats
        // non-favorite. Once the episode has a sync date, deliberate live edits win
        // by recency again (otherwise nothing could ever be reset to unheard).
        var localWon = false
        if localModifiedAt == nil {
            if episode.consumed && !played {
                played = true
                localWon = true
            }
            if !played && episode.position > position {
                position = episode.position
                localWon = true
            }
            if episode.starred && !starred {
                starred = true
                localWon = true
            }
        }

        var didMutate = false
        if episode.consumed != played {
            episode.consumed = played
            didMutate = true
        }
        if episode.starred != starred {
            episode.starred = starred
            didMutate = true
        }
        if !played && episode.position != position {
            episode.position = position
            didMutate = true
        }
        if played && episode.position != 0 {
            episode.position = 0
            didMutate = true
        }
        if didMutate {
            remoteAppliedObjectIDs.insert(episode.objectID)
        }

        if localWon {
            // The merge kept local state the cloud doesn't have — push the merged
            // result back up with a fresh date so the other devices adopt it (their
            // copy already has a sync date, so plain recency applies there).
            let date = Date()
            addPendingSave(episodeRecordID(forObjectHash: objectHash))
            return EpisodeClockUpdate(objectHash: objectHash, date: date)
        } else {
            return EpisodeClockUpdate(objectHash: objectHash, date: remoteDate)
        }
    }

    func episode(for payload: [String: Any]) -> CDEpisode? {
        if let objectHash = payload["objectHash"] as? String,
           let episode = deterministicallyResolvedEpisode(forObjectHash: objectHash) {
            return episode
        }

        guard let guid = payload["guid"] as? String, !guid.isEmpty else { return nil }
        if let feedURLString = payload["feedURL"] as? String,
           let url = URL(string: feedURLString),
           let feed = databaseManager.feed(withSourceURL: url) {
            for episode in feed.episodes as? Set<CDEpisode> ?? [] where episode.guid == guid {
                return episode
            }
        }

        return databaseManager.episode(withGuid: guid)
    }

    func deterministicallyResolvedEpisode(forObjectHash objectHash: String) -> CDEpisode? {
        guard !objectHash.isEmpty, let context = databaseManager.objectContext else { return nil }
        let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
        request.predicate = NSPredicate(format: "objectHash == %@", objectHash)
        request.includesSubentities = false
        let episodes = (try? context.fetch(request)) ?? []
        return deterministicallyResolvedEpisodesByObjectHash(episodes)[objectHash]
    }

    func applyPendingEpisodeStates() async {
        // The pending store survives a category toggle (the engine's change token means
        // already-fetched records are never re-delivered), but it must only be APPLIED
        // while the category is on — like applyRemoteRecord.
        guard episodesSyncEnabled, !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else { return }
        let generation = cloudAccountGeneration
        let initialCount: Int
        do {
            initialCount = try await Self.pendingEpisodeStateCount(accountRecordName: accountRecordName)
        } catch {
            handleLocalPersistenceFailure(error)
            return
        }
        guard initialCount > 0 else { return }

        var cursor: String?
        while true {
            let snapshots: [ICCloudPendingEpisodeStateSnapshot]
            do {
                snapshots = try await Self.pendingEpisodeStateBatch(
                    accountRecordName: accountRecordName,
                    afterRecordName: cursor
                )
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            guard !snapshots.isEmpty else { break }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  episodesSyncEnabled, !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }

            let batch: [(ICCloudPendingEpisodeStateSnapshot, [String: Any])]
            do {
                batch = try snapshots.map { ($0, try $0.payloadDictionary()) }
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            let chunkRecordNames = Set(snapshots.map(\.recordName))
            let entries: [ICCloudSyncOutboxSnapshot]
            do {
                entries = try await Self.localOutboxEntries(
                    accountRecordName: accountRecordName,
                    recordNames: chunkRecordNames
                )
            } catch {
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                      episodesSyncEnabled, !isICloudAccountSignedOut,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      !Task.isCancelled else { return }
                handleLocalPersistenceFailure(error)
                return
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  episodesSyncEnabled, !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return }
            mergeLocalOutboxSnapshotsIntoCache(entries)

            let objectHashes = Set(batch.compactMap { $0.1["objectHash"] as? String })
            var episodesByHash: [String: CDEpisode] = [:]
            guard let context = databaseManager.objectContext else {
                handleLocalPersistenceFailure(Self.syncItemMetadataStoreError(
                    code: 1,
                    description: "Der lokale iCloud-Metadatenspeicher konnte nicht geöffnet werden."
                ))
                return
            }
            if !objectHashes.isEmpty {
                let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
                request.predicate = NSPredicate(format: "objectHash IN %@", Array(objectHashes))
                request.includesSubentities = false
                let episodes = (try? context.fetch(request)) ?? []
                episodesByHash = deterministicallyResolvedEpisodesByObjectHash(episodes)
            }

            var metadataBatch: ICCloudSyncItemMetadataContextBatch
            do {
                metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
                    accountRecordName: accountRecordName,
                    recordNames: chunkRecordNames,
                    context: context
                )
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }

            var metadataWrites: [String: ICCloudSyncItemMetadataWrite] = [:]
            var appliedSnapshots: [ICCloudPendingEpisodeStateSnapshot] = []
            do {
                let didFlush = try performSynchronousRemoteApplyBatch {
                    let identityWrites = try batch.compactMap { snapshot, payload -> ICCloudSyncItemMetadataWrite? in
                        guard let objectHash = payload["objectHash"] as? String,
                              episodesByHash[objectHash] != nil else { return nil }
                        return try Self.episodeSyncItemMetadataIdentityWrite(
                            recordName: snapshot.recordName,
                            objectHash: objectHash
                        )
                    }
                    try Self.upsertSyncItemMetadata(
                        identityWrites,
                        updating: [],
                        metadataBatch: &metadataBatch,
                        context: context
                    )
                    for (snapshot, payload) in batch {
                        guard let objectHash = payload["objectHash"] as? String,
                              let episode = episodesByHash[objectHash] else { continue }
                        let localMetadata = try Self.syncItemMetadataSnapshot(
                            forRecordName: snapshot.recordName,
                            metadataBatch: metadataBatch
                        )
                        if let update = applyRemoteEpisodeState(
                            payload,
                            recordName: snapshot.recordName,
                            localModifiedAt: localMetadata?.localModifiedAt,
                            resolvedEpisode: episode,
                            lookupEpisodeIfNeeded: false
                        ) {
                            metadataWrites[snapshot.recordName] = ICCloudSyncItemMetadataWrite(
                                category: Self.localOutboxEpisodeCategory,
                                recordName: snapshot.recordName,
                                itemIdentifier: update.objectHash,
                                localModifiedAt: update.date,
                                localState: nil,
                                payloadHash: nil
                            )
                        }
                        appliedSnapshots.append(snapshot)
                    }
                    try Self.upsertSyncItemMetadata(
                        Array(metadataWrites.values),
                        metadataBatch: &metadataBatch,
                        context: context
                    )
                }
                guard didFlush else { return }
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            do {
                // Delete only the exact payload version that was just applied. A newer
                // CloudKit value staged during the await remains for the next replay.
                _ = try await Self.removePendingEpisodeStates(appliedSnapshots)
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }

            cursor = snapshots.last?.recordName
            await Task.yield()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  episodesSyncEnabled, !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }
        }

        let remainingCount: Int
        do {
            remainingCount = try await Self.pendingEpisodeStateCount(accountRecordName: accountRecordName)
        } catch {
            handleLocalPersistenceFailure(error)
            return
        }
        logSyncEvent("Wartende Episoden-Status verarbeitet", metadata: [
            "applied": initialCount - remainingCount,
            "remaining": remainingCount,
        ])
    }

    @discardableResult
    func applyRemoteSubscription(
        _ payload: [String: Any],
        recordName: String,
        metadataBatch: inout ICCloudSyncItemMetadataContextBatch
    ) throws -> Bool {
        guard let feedURL = payload["feedURL"] as? String, !feedURL.isEmpty else { return true }
        try ensureSubscriptionSyncItemMetadataMapping(
            feedURL: feedURL,
            recordName: recordName,
            metadataBatch: &metadataBatch
        )
        if (payload["deleted"] as? Bool) ?? false {
            // Reads tombstones written by an unreleased transitional build. New writes use
            // ICSubscriptionTombstone so released clients never mistake them for active feeds.
            let applied = try applyRemoteSubscriptionTombstone(
                payload,
                recordName: recordName,
                metadataBatch: &metadataBatch
            )
            if applied, !hasCompleteLocalSubscriptionOutboxPair(for: recordName) {
                let localMetadata = try subscriptionSyncItemMetadata(
                    for: feedURL,
                    metadataBatch: metadataBatch
                )
                let state = localMetadata?.localState ?? false
                let date = localMetadata?.localModifiedAt
                    ?? (payload["updatedAt"] as? Date)
                    ?? Date(timeIntervalSince1970: 0)
                if restoreDurableSubscriptionOutboxIntent(feedURL: feedURL,
                                                          subscribed: state,
                                                          changedAt: date,
                                                          metadataBatch: &metadataBatch) {
                    scheduleLocalOutboxDrain()
                }
            }
            return applied
        }

        let discardedLocalMutation: Bool
        switch remoteOutboxDecision(payload: payload, recordName: recordName) {
        case .keepLocal:
            return true
        case .applyRemote(let discarded):
            discardedLocalMutation = discarded
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        let localMetadata = try subscriptionSyncItemMetadata(
            for: feedURL,
            metadataBatch: metadataBatch
        )
        if !discardedLocalMutation,
           let localDate = localMetadata?.localModifiedAt,
           localDate.compare(remoteDate) == .orderedDescending {
            logSyncEvent("Remote-Abo übersprungen (lokal neuer)", metadata: ["feedURL": feedURL])
            let subscribed = localMetadata?.localState
                ?? (URL(string: feedURL).flatMap { databaseManager.feed(withSourceURL: $0) }?.subscribed ?? false)
            if restoreDurableSubscriptionOutboxIntent(feedURL: feedURL,
                                                      subscribed: subscribed,
                                                      changedAt: localDate,
                                                      metadataBatch: &metadataBatch) {
                scheduleLocalOutboxDrain()
            }
            return true
        }

        guard let feed = subscribedFeed(for: feedURL, title: payload["title"] as? String) else {
            return false
        }

        applySubscriptionPayload(payload, to: feed)
        // Record the applied state's fingerprint so the next local objects-did-change pass
        // (or feed refresh) doesn't mistake the applied payload for a local edit and echo
        // it back up with a fresh updatedAt.
        try updateSubscriptionSyncItemMetadata(
            feedURL: feedURL,
            localModifiedAt: remoteDate,
            localState: true,
            payloadHash: subscriptionPayloadHash(for: feed),
            metadataBatch: &metadataBatch
        )
        return true
    }

    @discardableResult
    func applyRemoteSubscriptionTombstone(
        _ payload: [String: Any],
        recordName: String,
        metadataBatch: inout ICCloudSyncItemMetadataContextBatch
    ) throws -> Bool {
        guard let feedURL = payload["feedURL"] as? String, !feedURL.isEmpty else { return true }
        try ensureSubscriptionSyncItemMetadataMapping(
            feedURL: feedURL,
            recordName: recordName,
            metadataBatch: &metadataBatch
        )
        let localMetadata = try subscriptionSyncItemMetadata(
            for: feedURL,
            metadataBatch: metadataBatch
        )

        if defaults.bool(forKey: Self.suppressSubscriptionDeletionsKey),
           let url = URL(string: feedURL),
           let localFeed = databaseManager.feed(withSourceURL: url), localFeed.subscribed {
            let localDate = localMetadata?.localModifiedAt ?? Date()
            if restoreDurableSubscriptionOutboxIntent(feedURL: feedURL,
                                                      subscribed: true,
                                                      changedAt: localDate,
                                                      metadataBatch: &metadataBatch) {
                scheduleLocalOutboxDrain()
            }
            logSyncEvent("Abo-Tombstone unterdrückt (Nachhol-Fetch nach Aktivierung)", metadata: [
                "feedURL": feedURL,
            ])
            return true
        }

        let discardedLocalMutation: Bool
        switch remoteOutboxDecision(payload: payload, recordName: recordName) {
        case .keepLocal:
            return true
        case .applyRemote(let discarded):
            discardedLocalMutation = discarded
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if !discardedLocalMutation,
           let localDate = localMetadata?.localModifiedAt,
           localDate.compare(remoteDate) == .orderedDescending {
            let subscribed = localMetadata?.localState
                ?? (URL(string: feedURL).flatMap { databaseManager.feed(withSourceURL: $0) }?.subscribed ?? false)
            if restoreDurableSubscriptionOutboxIntent(feedURL: feedURL,
                                                      subscribed: subscribed,
                                                      changedAt: localDate,
                                                      metadataBatch: &metadataBatch) {
                scheduleLocalOutboxDrain()
            }
            return true
        }

        // SubscriptionManager saves immediately. Put the winning clock/state/hash in the
        // same context first so that save commits the remote unsubscribe atomically.
        try updateSubscriptionSyncItemMetadata(
            feedURL: feedURL,
            localModifiedAt: remoteDate,
            localState: false,
            payloadHash: nil,
            metadataBatch: &metadataBatch
        )
        if let url = URL(string: feedURL),
           let feed = databaseManager.feed(withSourceURL: url), feed.subscribed {
            remoteAppliedObjectIDs.insert(feed.objectID)
            // SubscriptionManager persists the complete cleanup. Resolve a losing outbox
            // in that same transaction so an app kill cannot resurrect it.
            let outboxResolution = try deleteResolvedLocalOutboxEntries()
            subscriptionManager.unsubscribeFeed(feed)
            if let error = databaseManager.saveReturningError() {
                throw error
            }
            consumeResolvedLocalOutboxEntries(outboxResolution)
        }
        return true
    }

    func subscribedFeed(for feedURL: String, title: String?) -> CDFeed? {
        guard let url = URL(string: feedURL) else { return nil }
        if let feed = databaseManager.feed(withSourceURL: url) {
            if !feed.subscribed {
                feed.subscribed = true
                // `subscribed` is a sync-relevant key — record the remote-driven mutation
                // so the observer doesn't echo it back as a local edit.
                remoteAppliedObjectIDs.insert(feed.objectID)
            }
            return feed
        }

        // Phase 1 of the two-phase apply: create a lightweight local STUB — no network,
        // no episodes. The whole list shows up immediately (in rank order) and the UI
        // stays responsive no matter how many subscriptions arrive. Episodes are loaded
        // one feed at a time by the low-priority hydration queue (phase 2), which derives
        // its work from the data (lastUpdate == nil) and therefore survives app kills.
        guard let stub = ICFeed.feed() as? ICFeed else { return nil }
        stub.sourceURL = url
        stub.title = (title?.isEmpty == false) ? title : feedURL
        guard let feed = subscriptionManager.subscribeParserFeed(stub, autodownload: false, options: .subscribeOptionDontManageRanking) else {
            logSyncEvent("Remote-Abo-Stub konnte nicht angelegt werden", metadata: ["feedURL": feedURL])
            return nil
        }
        remoteAppliedObjectIDs.insert(feed.objectID)
        return feed
    }

    // Equality-checked like applyRemoteEpisodeState: only real differences are written, so an
    // apply that changes nothing leaves no dirty objects (no objects-did-change pass, no save
    // churn, no echo upload).
    func applySubscriptionPayload(_ payload: [String: Any], to feed: CDFeed) {
        var didMutate = false
        if let title = payload["title"] as? String, !title.isEmpty, feed.title == nil {
            feed.title = title
            didMutate = true
        }
        if let rank = (payload["rank"] as? NSNumber)?.int32Value, feed.rank != rank {
            feed.rank = rank
            didMutate = true
        }
        if let parked = payload["parked"] as? Bool, feed.parked != parked {
            feed.parked = parked
            didMutate = true
        }
        if let username = payload["username"] as? String, !username.isEmpty, feed.username != username {
            feed.username = username
            didMutate = true
        }
        if let password = payload["password"] as? String, !password.isEmpty, feed.password != password {
            feed.password = password
            didMutate = true
        }

        if let properties = payload["properties"] as? [[String: Any]] {
            for property in properties {
                if applyFeedPropertyPayload(property, to: feed) {
                    didMutate = true
                }
            }
        }
        if didMutate {
            remoteAppliedObjectIDs.insert(feed.objectID)
        }
    }

    // Replicates all four CDFeedProperty value fields instead of guessing a single type.
    // CDFeedProperty carries no type marker; the old UserDefaults-based heuristic failed for
    // uid-prefixed double keys (the auto-skip periods/offsets) and applied them as bool —
    // silent value loss on the receiving device. The payload has always carried all four
    // fields; `valueType` is still uploaded so older app versions keep working.
    func applyFeedPropertyPayload(_ property: [String: Any], to feed: CDFeed) -> Bool {
        guard let rawKey = property["key"] as? String, !rawKey.isEmpty else { return false }
        // Map a uid-relative marker key back to this device's own feed uid (see stableFeedPropertyKey).
        let key = Self.localFeedPropertyKey(rawKey, feedUID: feed.uid)
        guard let cdProperty = feed.property(forKey: key, insertOnDemand: true) else { return false }

        var didMutate = cdProperty.isInserted
        let boolValue = (property["boolValue"] as? NSNumber)?.boolValue ?? false
        let int32Value = (property["int32Value"] as? NSNumber)?.int32Value ?? 0
        let doubleValue = (property["doubleValue"] as? NSNumber)?.doubleValue ?? 0
        let stringValue = property["stringValue"] as? String
        if cdProperty.boolValue != boolValue {
            cdProperty.boolValue = boolValue
            didMutate = true
        }
        if cdProperty.int32Value != int32Value {
            cdProperty.int32Value = int32Value
            didMutate = true
        }
        if cdProperty.doubleValue != doubleValue {
            cdProperty.doubleValue = doubleValue
            didMutate = true
        }
        if cdProperty.stringValue != stringValue {
            cdProperty.stringValue = stringValue
            didMutate = true
        }
        if didMutate {
            remoteAppliedObjectIDs.insert(cdProperty.objectID)
        }
        return didMutate
    }

    var pendingSubscriptionFetchIsComplete: Bool {
        (Self.syncMetadataValue(forKey: Self.pendingSubscriptionFetchCompleteKey) as? NSNumber)?.boolValue == true
    }

    var hasIncompletePendingSubscriptionFetch: Bool {
        subscriptionsSyncEnabled
            && !pendingSubscriptionFetchIsComplete
    }

    func markPendingSubscriptionFetchIncomplete() {
        setSyncMetadata(false, forKey: Self.pendingSubscriptionFetchCompleteKey)
    }

    func markPendingSubscriptionFetchComplete() {
        setSyncMetadata(true, forKey: Self.pendingSubscriptionFetchCompleteKey)
    }

    func resolvedPendingSubscriptionChanges(
        _ snapshots: [ICCloudPendingSubscriptionStateSnapshot]
    ) throws -> [PendingSubscriptionChange] {
        var candidatesByFeedURL: [String: [PendingSubscriptionChange]] = [:]
        for snapshot in snapshots where snapshot.recordName != RecordPrefix.subscriptionListSettings {
            let recordName = snapshot.recordName
            let payload = try snapshot.payloadDictionary()
            let feedURL = (payload["feedURL"] as? String) ?? ""
            let isLegacyDeletion = isPendingLegacySubscriptionDeletion(payload)
            let isTombstone = isLegacyDeletion
                || ((payload["deleted"] as? Bool) == true)
                || recordName.hasPrefix(RecordPrefix.subscriptionTombstone)
            let groupKey = feedURL.isEmpty ? "__invalid__\(recordName)" : feedURL
            candidatesByFeedURL[groupKey, default: []].append(PendingSubscriptionChange(
                feedURL: feedURL,
                recordName: recordName,
                payload: payload,
                snapshots: [snapshot],
                isTombstone: isTombstone,
                isLegacyDeletion: isLegacyDeletion
            ))
        }

        let winners = candidatesByFeedURL.compactMap { _, candidates -> PendingSubscriptionChange? in
            // A timestamp-less physical delete is only authoritative when no versioned
            // active/tombstone payload exists in this complete fetch. This preserves
            // compatibility with released clients without letting one half of an older
            // paired unsubscribe destroy a newer subscribe.
            let versionedCandidates = candidates.filter { !$0.isLegacyDeletion }
            let eligibleCandidates = versionedCandidates.isEmpty ? candidates : versionedCandidates
            guard let winner = eligibleCandidates.max(by: { lhs, rhs in
                let lhsDate = lhs.payload["updatedAt"] as? Date ?? .distantPast
                let rhsDate = rhs.payload["updatedAt"] as? Date ?? .distantPast
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                if lhs.isTombstone != rhs.isTombstone {
                    // Equal logical clocks are resolved identically on every device;
                    // deletion wins the tie so a partial pair cannot resurrect a feed.
                    return !lhs.isTombstone && rhs.isTombstone
                }
                return lhs.recordName < rhs.recordName
            }) else { return nil }
            return PendingSubscriptionChange(
                feedURL: winner.feedURL,
                recordName: winner.recordName,
                payload: winner.payload,
                snapshots: candidates.flatMap(\.snapshots),
                isTombstone: winner.isTombstone,
                isLegacyDeletion: winner.isLegacyDeletion
            )
        }

        // Active winners with the smallest synced ranks appear first while the batched
        // stub creation progresses; the feed URL makes ordering deterministic on ties.
        return winners.sorted { lhs, rhs in
            let lhsRank = (lhs.payload["rank"] as? NSNumber)?.intValue ?? Int.max
            let rhsRank = (rhs.payload["rank"] as? NSNumber)?.intValue ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.feedURL < rhs.feedURL
        }
    }

    func applyPendingSubscriptions() async {
        // Same enabled-gate as applyRemoteRecord: without it a customer who turned
        // subscription sync OFF could still get pending remote feeds subscribed
        // (including the network fetch) on the next app start.
        guard subscriptionsSyncEnabled, !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              let context = databaseManager.objectContext else { return }
        guard pendingSubscriptionFetchIsComplete else {
            logSyncEvent("Wartende Abo-Payloads bleiben bis zum vollständigen Fetch geparkt")
            return
        }
        guard !isApplyingPendingSubscriptions else { return }
        let initialCount: Int
        do {
            initialCount = try await Self.pendingSubscriptionStateCount(
                accountRecordName: accountRecordName
            )
        } catch {
            handleLocalPersistenceFailure(error)
            return
        }
        guard initialCount > 0 else { return }
        isApplyingPendingSubscriptions = true
        let generation = cloudAccountGeneration
        defer {
            isApplyingPendingSubscriptions = false
            remoteAppliedObjectIDs.removeAll()
        }

        var cursor: String?
        while true {
            let page: ICCloudPendingSubscriptionStatePage
            do {
                page = try await Self.pendingSubscriptionStateBatch(
                    accountRecordName: accountRecordName,
                    afterRecordName: cursor
                )
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  subscriptionsSyncEnabled, !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }
            guard let nextRecordName = page.nextRecordName else { break }

            let changes: [PendingSubscriptionChange]
            do {
                changes = try resolvedPendingSubscriptionChanges(page.snapshots)
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            if changes.isEmpty {
                cursor = nextRecordName
                await Task.yield()
                continue
            }

            let outboxRecordNames = changes.reduce(into: Set<String>()) { result, change in
                for recordName in change.snapshots.map(\.recordName) {
                    result.formUnion(Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName))
                }
            }
            let entries: [ICCloudSyncOutboxSnapshot]
            do {
                entries = try await Self.localOutboxEntries(
                    accountRecordName: accountRecordName,
                    recordNames: outboxRecordNames
                )
            } catch {
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                      subscriptionsSyncEnabled, !isICloudAccountSignedOut,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      !Task.isCancelled else { return }
                handleLocalPersistenceFailure(error)
                return
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  subscriptionsSyncEnabled, !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return }
            mergeLocalOutboxSnapshotsIntoCache(entries)

            let metadataRecordNames = changes.reduce(into: Set<String>()) { result, change in
                result.formUnion(change.snapshots.map(\.recordName))
                guard !change.feedURL.isEmpty else { return }
                result.insert(Self.subscriptionRecordName(forFeedURL: change.feedURL))
                result.insert(Self.subscriptionTombstoneRecordName(forFeedURL: change.feedURL))
            }
            var metadataBatch: ICCloudSyncItemMetadataContextBatch
            do {
                metadataBatch = try Self.prepareSyncItemMetadataContextBatch(
                    accountRecordName: accountRecordName,
                    recordNames: metadataRecordNames,
                    context: context
                )
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }

            var appliedSnapshots: [ICCloudPendingSubscriptionStateSnapshot] = []
            do {
                let didFlush = try performSynchronousRemoteApplyBatch {
                    for change in changes {
                        let applied: Bool
                        if change.isLegacyDeletion {
                            applied = try applyPendingLegacySubscriptionDeletion(
                                change.payload,
                                recordName: change.recordName,
                                metadataBatch: &metadataBatch
                            )
                        } else if change.recordName.hasPrefix(RecordPrefix.subscriptionTombstone) {
                            applied = try applyRemoteSubscriptionTombstone(
                                change.payload,
                                recordName: change.recordName,
                                metadataBatch: &metadataBatch
                            )
                        } else {
                            // Includes transitional same-type tombstones; that method migrates
                            // their durable local pair after applying the logical deletion.
                            applied = try applyRemoteSubscription(
                                change.payload,
                                recordName: change.recordName,
                                metadataBatch: &metadataBatch
                            )
                        }
                        if applied {
                            appliedSnapshots.append(contentsOf: change.snapshots)
                        }
                    }
                }
                guard didFlush else { return }
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            do {
                // A CloudKit callback can stage a newer revision while this task awaits.
                // Delete only the exact bytes that were committed locally; the newer row
                // remains for the next replay pass.
                _ = try await Self.removePendingSubscriptionStates(appliedSnapshots)
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }

            cursor = nextRecordName
            await Task.yield()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  subscriptionsSyncEnabled, !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }
        }

        // List settings depend on all referenced feed stubs, so apply this singleton
        // after every subscription page instead of letting record-name order decide.
        let listSettingsSnapshot: ICCloudPendingSubscriptionStateSnapshot?
        do {
            listSettingsSnapshot = try await Self.pendingSubscriptionState(
                accountRecordName: accountRecordName,
                recordName: RecordPrefix.subscriptionListSettings
            )
        } catch {
            handleLocalPersistenceFailure(error)
            return
        }
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
              subscriptionsSyncEnabled, !isICloudAccountSignedOut,
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }
        if let listSettingsSnapshot {
            let listSettings: [String: Any]
            do {
                listSettings = try listSettingsSnapshot.payloadDictionary()
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
            var applied = false
            let didFlush = performSynchronousRemoteApplyBatch {
                applied = applyRemoteSubscriptionListSettings(listSettings)
            }
            guard didFlush else { return }
            guard await applySubscriptionListSortIfNeeded() else { return }
            if applied {
                do {
                    _ = try await Self.removePendingSubscriptionStates([listSettingsSnapshot])
                } catch {
                    handleLocalPersistenceFailure(error)
                    return
                }
            }
            await Task.yield()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  subscriptionsSyncEnabled, !isICloudAccountSignedOut else { return }
        }

        let remainingCount: Int
        do {
            remainingCount = try await Self.pendingSubscriptionStateCount(
                accountRecordName: accountRecordName
            )
        } catch {
            handleLocalPersistenceFailure(error)
            return
        }
        logSyncEvent("Wartende Abo-Payloads verarbeitet", metadata: [
            "applied": max(0, initialCount - remainingCount),
            "remaining": remainingCount,
        ])
        hydrateStubFeedsIfNeeded()
    }

    func applyRemoteAppSettings(_ payload: [String: Any]) {
        // Enable phase (marker still set, nothing published yet) and the cloud already
        // has settings: the USER decides (12.06.) — adopt the cloud state or overwrite
        // it with this device's settings. Park the payload and ask; nothing is applied
        // or published until the choice is made (the fetch-gated initial publish is
        // held back by the parked payload).
        if defaults.bool(forKey: Self.initialSettingsBackfillPendingKey) {
            setSyncMetadata(payload, forKey: Self.pendingInitialSettingsPayloadKey)
            logSyncEvent("Einstellungs-Wahl erforderlich (iCloud hat bereits Einstellungen)")
            postStateChanged()
            NotificationCenter.default.post(name: NSNotification.Name(Self.initialSettingsChoiceNeededNotification), object: nil)
            return
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = settingsLocalModifiedDate(), localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(appSettingsRecordID())
            return
        }
        adoptSettingsPayload(payload)
    }

    // Shared apply core: writes the synced values, re-baselines and refreshes the UI.
    func adoptSettingsPayload(_ payload: [String: Any]) {
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        guard let values = payload["values"] as? [String: Any] else {
            logSyncEvent("Einstellungs-Payload ungültig", metadata: [
                "hasValues": false,
                "payloadKeyCount": payload.keys.count,
            ])
            return
        }
        var appliedSettingsValueCount = 0
        for (key, value) in values where Self.shouldSyncSettingsKeyForSyncEngineCallback(key) && Self.isValidSettingsValueForSyncEngineCallback(value) {
            defaults.set(value, forKey: key)
            appliedSettingsValueCount += 1
        }

        let credentials = payload["credentials"] as? NSDictionary
        if let credentials {
            ICRemoteChapterCredentialStore.restoreBackupCredentialValues(credentials)
        }

        setSettingsLocalModifiedDate(remoteDate)
        // Re-baseline so the apply itself doesn't read as a local settings change on the
        // next debounced check (that echoed the record back up with a fresh updatedAt).
        setStoredSyncedSettingsHash(syncedSettingsHash())
        // Remote settings adopted — the fetch-gated initial publish is obsolete.
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        defaults.synchronize()
        ICAppearanceManager.shared()?.updateAppearance()
        NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
        logSyncEvent("Einstellungs-Payload übernommen", metadata: [
            "settingsValueCount": values.count,
            "appliedSettingsValueCount": appliedSettingsValueCount,
            "hasCredentials": credentials != nil,
        ])
        postStateChanged()
    }

    // MARK: - Initial settings choice (user decision on enabling settings sync)

    @objc var hasPendingInitialSettingsChoice: Bool {
        Self.syncMetadataValue(forKey: Self.pendingInitialSettingsPayloadKey) != nil
    }

    // "Einstellungen aus iCloud übernehmen": apply the parked cloud settings here.
    @objc func resolveInitialSettingsAdoptingCloud() {
        guard let payload = Self.syncMetadataValue(forKey: Self.pendingInitialSettingsPayloadKey) as? [String: Any] else {
            logSyncEvent("Einstellungs-Wahl: iCloud-Stand fehlt", metadata: syncDiagnosticsMetadata())
            postStateChanged()
            return
        }
        logSyncEvent("Einstellungs-Wahl: iCloud-Stand wird übernommen", metadata: [
            "settingsValueCount": (payload["values"] as? [String: Any])?.count ?? -1,
            "hasCredentials": payload["credentials"] != nil,
        ])
        setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        adoptSettingsPayload(payload)
        logSyncEvent("Einstellungs-Wahl: iCloud-Stand übernommen")
        markSyncCompletedIfFinished()
    }

    // "Meine Einstellungen für alle verwenden": publish this device's settings with a
    // fresh date — the other devices adopt them via plain recency.
    @objc func resolveInitialSettingsPublishingLocal() {
        setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        setSettingsLocalModifiedDate(Date())
        setStoredSyncedSettingsHash(syncedSettingsHash())
        addPendingSave(appSettingsRecordID())
        logSyncEvent("Einstellungs-Wahl: lokale Einstellungen veröffentlicht")
        postStateChanged()
    }

    func applyRemoteListScrollPositions(_ payload: [String: Any]) {
        guard let positions = payload["positions"] as? [String: NSNumber] else { return }
        let remoteDate = payload["lastModified"] as? Date ?? payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = scrollPositionsLocalModifiedDate(), localDate.compare(remoteDate) == .orderedDescending {
            addPendingSave(listScrollPositionsRecordID())
            return
        }

        ICApplySyncedListScrollPositions(positions, remoteDate)
        setScrollPositionsLocalModifiedDate(remoteDate)
    }
}
