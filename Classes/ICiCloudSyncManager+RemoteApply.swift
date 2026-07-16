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

    nonisolated static let episodeOutboxResolutionMarkerPrefix = "resolvedOutboxRevision:v1:"
    nonisolated static let localSubscriptionCleanupAccountRecordName = "__local_subscription_cleanup__"
    nonisolated static let localSubscriptionCleanupCategory = "subscriptionCleanup"
    nonisolated static let localSubscriptionCleanupRecordPrefix = "localSubscriptionCleanup:v1:"
    nonisolated static let localSubscriptionCleanupFeedURLKey = "feedURL"
    nonisolated static let localSubscriptionCleanupFeedObjectURIKey = "feedObjectURI"
    nonisolated static let localSubscriptionCleanupPendingSnapshotsKey = "pendingSnapshots"

    nonisolated static func episodeOutboxResolutionMarker(for revision: String) -> String {
        episodeOutboxResolutionMarkerPrefix + revision
    }

    nonisolated static func episodeOutboxRevisionResolvedByMetadata(
        _ outbox: ICCloudSyncOutboxSnapshot,
        metadata: ICCloudSyncItemMetadataSnapshot?
    ) -> Bool {
        guard outbox.category == localOutboxEpisodeCategory,
              !outbox.revision.isEmpty else { return false }
        return metadata?.payloadHash == episodeOutboxResolutionMarker(for: outbox.revision)
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
              let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw pendingEpisodeStateStoreError(code: 1,
                                                description: "Der lokale iCloud-Episodenstatusspeicher konnte nicht geöffnet werden.")
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: pendingEpisodeStateEntityName)
            request.predicate = NSPredicate(format: "accountRecordName == %@", accountRecordName)
            return try context.count(for: request)
        }
    }

    nonisolated static func applyPendingEpisodeStateBatchInBackground(
        accountRecordName: String,
        snapshots: [ICCloudPendingEpisodeStateSnapshot],
        generation: Int,
        episodeEpoch: UInt64,
        validityGate: ICiCloudSyncEngineCallbackGate,
        remoteOriginGate: ICiCloudRemoteEpisodeOriginGate,
        remoteEpisodeClockGate: ICiCloudRemoteEpisodeClockGate
    ) async throws -> ICCloudEpisodeApplyBatchResult {
        guard snapshots.count <= remoteApplyBatchSize else {
            throw pendingEpisodeStateStoreError(
                code: 2,
                description: "Ein iCloud-Episodenstatus-Batch überschreitet die sichere Transaktionsgröße."
            )
        }
        let boundedSnapshots = snapshots
        guard !boundedSnapshots.isEmpty else {
            return ICCloudEpisodeApplyBatchResult(
                appliedCount: 0,
                recordNamesToUpload: [],
                recordNamesNeedingOutboxDrain: [],
                resolvedOutboxRevisions: [:],
                remoteClockFloors: [:],
                insertedObjectURIStrings: [],
                updatedObjectURIStrings: [],
                remoteEpisodeObjectURIStrings: [],
                originRegistration: nil,
                clockRegistration: nil,
                commitLease: nil
            )
        }

        var remoteClockFloors: [String: Date] = [:]
        for snapshot in boundedSnapshots {
            let payload = try snapshot.payloadDictionary()
            remoteClockFloors[snapshot.recordName] =
                payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        }
        let batchRemoteClockFloors = remoteClockFloors
        let clockRegistration = remoteEpisodeClockGate.register(batchRemoteClockFloors)

        do {
            for attempt in 0...1 {
                guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
                    throw pendingEpisodeStateStoreError(
                        code: 1,
                        description: "Der lokale iCloud-Episodenstatusspeicher konnte nicht geöffnet werden."
                    )
                }
                context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
                context.undoManager = nil
                do {
                    return try await context.perform {
                        var originRegistration: UUID?
                        var commitLease: ICiCloudRemoteApplyCommitLease?
                        do {
                            let recordNames = Set(boundedSnapshots.map(\.recordName))
                            let expectedPayloadByRecordName = Dictionary(
                                uniqueKeysWithValues: boundedSnapshots.map { ($0.recordName, $0.payloadData) }
                            )

                            let pendingRequest = NSFetchRequest<NSManagedObject>(
                                entityName: pendingEpisodeStateEntityName
                            )
                            pendingRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                                NSPredicate(format: "accountRecordName == %@", accountRecordName),
                                NSPredicate(format: "recordName IN %@", Array(recordNames)),
                            ])
                            pendingRequest.fetchBatchSize = remoteApplyBatchSize
                            var pendingByRecordName: [String: NSManagedObject] = [:]
                            for pending in try context.fetch(pendingRequest) {
                                guard let recordName = pending.value(forKey: "recordName") as? String,
                                      let payloadData = pending.value(forKey: "payloadData") as? Data,
                                      expectedPayloadByRecordName[recordName] == payloadData else { continue }
                                pendingByRecordName[recordName] = pending
                            }

                            var payloadByRecordName: [String: [String: Any]] = [:]
                            var objectHashes = Set<String>()
                            for snapshot in boundedSnapshots
                            where pendingByRecordName[snapshot.recordName] != nil {
                                let payload = try snapshot.payloadDictionary()
                                guard let objectHash = payload["objectHash"] as? String,
                                      !objectHash.isEmpty else {
                                    throw syncItemMetadataStoreError(
                                        code: 3,
                                        description: "Ein empfangener iCloud-Episodenstatus hat keine gültige Episodenidentität."
                                    )
                                }
                                _ = try episodeSyncItemMetadataIdentityWrite(
                                    recordName: snapshot.recordName,
                                    objectHash: objectHash
                                )
                                payloadByRecordName[snapshot.recordName] = payload
                                objectHashes.insert(objectHash)
                            }

                            let episodeRequest = NSFetchRequest<CDEpisode>(entityName: "Episode")
                            episodeRequest.predicate = NSPredicate(
                                format: "objectHash IN %@",
                                Array(objectHashes)
                            )
                            episodeRequest.includesSubentities = false
                            let episodes = try context.fetch(episodeRequest)
                            let episodesByObjectHash = deterministicallyResolvedEpisodesByObjectHash(
                                episodes
                            )

                            var metadataBatch = try prepareSyncItemMetadataContextBatch(
                                accountRecordName: accountRecordName,
                                recordNames: Set(payloadByRecordName.keys),
                                context: context
                            )
                            let identityWrites = try payloadByRecordName.compactMap {
                                recordName, payload -> ICCloudSyncItemMetadataWrite? in
                                guard let objectHash = payload["objectHash"] as? String,
                                      episodesByObjectHash[objectHash] != nil else { return nil }
                                return try episodeSyncItemMetadataIdentityWrite(
                                    recordName: recordName,
                                    objectHash: objectHash
                                )
                            }
                            try upsertSyncItemMetadata(
                                identityWrites,
                                updating: [],
                                metadataBatch: &metadataBatch,
                                context: context
                            )

                            let outboxRequest = NSFetchRequest<NSManagedObject>(
                                entityName: localOutboxEntityName
                            )
                            outboxRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                                NSPredicate(format: "accountRecordName == %@", accountRecordName),
                                NSPredicate(format: "recordName IN %@", Array(recordNames)),
                            ])
                            outboxRequest.fetchBatchSize = remoteApplyBatchSize
                            var outboxByRecordName: [String: ICCloudSyncOutboxSnapshot] = [:]
                            for storedOutbox in try context.fetch(outboxRequest) {
                                let outbox = try episodeOutboxSnapshot(from: storedOutbox)
                                guard outboxByRecordName[outbox.recordName] == nil else {
                                    throw localOutboxStoreError(
                                        code: 2,
                                        description: "Ein lokaler iCloud-Episoden-Outbox-Eintrag ist mehrfach vorhanden."
                                    )
                                }
                                outboxByRecordName[outbox.recordName] = outbox
                            }

                            var appliedCount = 0
                            var recordNamesToUpload = Set<String>()
                            var recordNamesNeedingOutboxDrain = Set<String>()
                            var resolvedOutboxRevisions: [String: String] = [:]
                            var changedEpisodeObjectIDs = Set<NSManagedObjectID>()

                            for snapshot in boundedSnapshots {
                                guard let pending = pendingByRecordName[snapshot.recordName],
                                      let payload = payloadByRecordName[snapshot.recordName],
                                      let objectHash = payload["objectHash"] as? String,
                                      let episode = episodesByObjectHash[objectHash] else { continue }

                                let metadata = try syncItemMetadataSnapshot(
                                    forRecordName: snapshot.recordName,
                                    metadataBatch: metadataBatch
                                )
                                var activeOutbox = outboxByRecordName[snapshot.recordName]
                                if let outbox = activeOutbox,
                                   episodeOutboxRevisionResolvedByMetadata(outbox, metadata: metadata) {
                                    activeOutbox = nil
                                }
                                let remoteDate = payload["updatedAt"] as? Date
                                    ?? Date(timeIntervalSince1970: 0)
                                let remoteRevision = payload[localMutationRevisionPayloadKey] as? String

                                if let outbox = activeOutbox {
                                    guard outbox.category == localOutboxEpisodeCategory else {
                                        throw localOutboxStoreError(
                                            code: 2,
                                            description: "Ein lokaler iCloud-Episoden-Outbox-Eintrag hat eine falsche Kategorie."
                                        )
                                    }
                                    let remoteResolvesOutbox = remoteRevision == outbox.revision
                                        || remoteDate > outbox.changedAt
                                    if !remoteResolvesOutbox {
                                        recordNamesNeedingOutboxDrain.insert(snapshot.recordName)
                                        context.delete(pending)
                                        appliedCount += 1
                                        continue
                                    }
                                    resolvedOutboxRevisions[snapshot.recordName] = outbox.revision
                                } else if let localDate = metadata?.localModifiedAt,
                                          localDate > remoteDate {
                                    recordNamesToUpload.insert(snapshot.recordName)
                                    context.delete(pending)
                                    appliedCount += 1
                                    continue
                                }

                                var played = boolValue(payload["played"]) ?? false
                                var starred = boolValue(payload["starred"]) ?? false
                                var position = max(0, int32Value(payload["position"]) ?? 0)
                                var localWon = false
                                if metadata?.localModifiedAt == nil && activeOutbox == nil {
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

                                var didMutateEpisode = false
                                if episode.consumed != played {
                                    episode.consumed = played
                                    didMutateEpisode = true
                                }
                                if episode.starred != starred {
                                    episode.starred = starred
                                    didMutateEpisode = true
                                }
                                let resolvedPosition: Int32 = played ? 0 : position
                                if episode.position != resolvedPosition {
                                    episode.position = resolvedPosition
                                    didMutateEpisode = true
                                }
                                if didMutateEpisode {
                                    changedEpisodeObjectIDs.insert(episode.objectID)
                                }

                                let appliedDate: Date
                                if localWon {
                                    appliedDate = nextCloudKitSafeDate(
                                        proposed: Date(),
                                        after: remoteDate
                                    )
                                    recordNamesToUpload.insert(snapshot.recordName)
                                } else {
                                    appliedDate = remoteDate
                                }
                                let resolvedRevision = resolvedOutboxRevisions[snapshot.recordName]
                                try upsertSyncItemMetadata(
                                    [ICCloudSyncItemMetadataWrite(
                                        category: localOutboxEpisodeCategory,
                                        recordName: snapshot.recordName,
                                        itemIdentifier: objectHash,
                                        localModifiedAt: appliedDate,
                                        localState: nil,
                                        payloadHash: resolvedRevision.map(episodeOutboxResolutionMarker)
                                            ?? metadata?.payloadHash
                                    )],
                                    metadataBatch: &metadataBatch,
                                    context: context
                                )
                                context.delete(pending)
                                appliedCount += 1
                            }

                            guard validityGate.episodeApplyIsValid(
                                generation: generation,
                                accountRecordName: accountRecordName,
                                epoch: episodeEpoch
                            ), !Task.isCancelled else {
                                throw CancellationError()
                            }

                            if !context.insertedObjects.isEmpty {
                                try context.obtainPermanentIDs(for: Array(context.insertedObjects))
                            }
                            let insertedObjectURIStrings = Set(context.insertedObjects.compactMap {
                                $0.entity.name == pendingEpisodeStateEntityName
                                    ? nil
                                    : $0.objectID.uriRepresentation().absoluteString
                            })
                            let updatedObjectURIStrings = Set(context.updatedObjects.compactMap {
                                $0.entity.name == pendingEpisodeStateEntityName
                                    ? nil
                                    : $0.objectID.uriRepresentation().absoluteString
                            })
                            let remoteEpisodeObjectURIStrings = Set(changedEpisodeObjectIDs.map {
                                $0.uriRepresentation().absoluteString
                            })
                            originRegistration = remoteOriginGate.register(
                                remoteEpisodeObjectURIStrings
                            )
                            guard let acquiredCommitLease = validityGate.acquireEpisodeApplyCommitLease(
                                generation: generation,
                                accountRecordName: accountRecordName,
                                epoch: episodeEpoch
                            ) else {
                                throw CancellationError()
                            }
                            commitLease = acquiredCommitLease
                            if context.hasChanges {
                                try context.save()
                            }
                            return ICCloudEpisodeApplyBatchResult(
                                appliedCount: appliedCount,
                                recordNamesToUpload: recordNamesToUpload,
                                recordNamesNeedingOutboxDrain: recordNamesNeedingOutboxDrain,
                                resolvedOutboxRevisions: resolvedOutboxRevisions,
                                remoteClockFloors: batchRemoteClockFloors,
                                insertedObjectURIStrings: insertedObjectURIStrings,
                                updatedObjectURIStrings: updatedObjectURIStrings,
                                remoteEpisodeObjectURIStrings: remoteEpisodeObjectURIStrings,
                                originRegistration: originRegistration,
                                clockRegistration: clockRegistration,
                                commitLease: commitLease
                            )
                        } catch {
                            context.rollback()
                            remoteOriginGate.discard(originRegistration)
                            if let commitLease {
                                validityGate.releaseRemoteApplyCommitLease(commitLease)
                            }
                            throw error
                        }
                    }
                } catch {
                    let persistenceError = error as NSError
                    if attempt == 0,
                       persistenceError.domain == NSCocoaErrorDomain,
                       persistenceError.code == 133020 {
                        continue
                    }
                    throw error
                }
            }
            throw pendingEpisodeStateStoreError(
                code: 3,
                description: "Der lokale iCloud-Episodenstatus konnte nicht konfliktfrei gespeichert werden."
            )
        } catch {
            remoteEpisodeClockGate.remove(clockRegistration)
            throw error
        }
    }

    nonisolated static func episodeOutboxSnapshot(
        from entry: NSManagedObject
    ) throws -> ICCloudSyncOutboxSnapshot {
        guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
              let recordName = entry.value(forKey: "recordName") as? String,
              let category = entry.value(forKey: "category") as? String,
              let operation = entry.value(forKey: "operation") as? String,
              let revision = entry.value(forKey: "revision") as? String,
              let changedAt = entry.value(forKey: "changedAt") as? Date,
              let payloadData = entry.value(forKey: "payloadData") as? Data else {
            throw localOutboxStoreError(
                code: 2,
                description: "Ein lokaler iCloud-Episoden-Outbox-Eintrag ist beschädigt."
            )
        }
        return ICCloudSyncOutboxSnapshot(
            accountRecordName: accountRecordName,
            recordName: recordName,
            category: category,
            operation: operation,
            acknowledged: localOutboxEntryIsAcknowledged(entry),
            revision: revision,
            changedAt: changedAt,
            payloadData: payloadData
        )
    }

    func performSynchronousRemoteViewContextMerge(
        _ changes: [AnyHashable: Any],
        into context: NSManagedObjectContext
    ) {
        guard !changes.isEmpty else { return }
        let wasApplyingRemoteChange = isApplyingRemoteChange
        isApplyingRemoteChange = true
        defer {
            isApplyingRemoteChange = wasApplyingRemoteChange
        }
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: changes,
            into: [context]
        )
        context.processPendingChanges()
    }

    func consumeEpisodeApplyBatchResult(_ result: ICCloudEpisodeApplyBatchResult) throws {
        defer {
            remoteEpisodeClockGate.remove(result.clockRegistration)
        }
        let commitLease = result.commitLease
        if let commitLease {
            guard syncEngineCallbackGate.remoteApplyCommitLeaseIsActive(commitLease) else {
                remoteOriginGate.discard(result.originRegistration)
                throw CancellationError()
            }
        } else {
            guard result.appliedCount == 0,
                  result.insertedObjectURIStrings.isEmpty,
                  result.updatedObjectURIStrings.isEmpty else {
                remoteOriginGate.discard(result.originRegistration)
                throw CancellationError()
            }
        }
        defer {
            if let commitLease {
                syncEngineCallbackGate.releaseRemoteApplyCommitLease(commitLease)
            }
        }
        guard let context = databaseManager.objectContext else {
            remoteOriginGate.discard(result.originRegistration)
            throw Self.syncItemMetadataStoreError(
                code: 1,
                description: "Der lokale iCloud-Episodenstatus konnte nicht in die Benutzeroberfläche übernommen werden."
            )
        }

        rebaseRegisteredLocalEpisodeOutboxClocks(
            remoteClockFloors: result.remoteClockFloors,
            resolvedOutboxRevisions: result.resolvedOutboxRevisions,
            context: context
        )

        let registeredOriginURIStrings = remoteOriginGate.take(result.originRegistration)
        let originObjectIDs = try managedObjectIDs(
            forURIStrings: registeredOriginURIStrings,
            coordinator: databaseManager.storeCoordinator
        )
        remoteAppliedObjectIDs.formUnion(originObjectIDs)
        defer {
            remoteAppliedObjectIDs.subtract(originObjectIDs)
        }
        let insertedObjectIDs = try managedObjectIDs(
            forURIStrings: result.insertedObjectURIStrings,
            coordinator: databaseManager.storeCoordinator
        )
        let updatedObjectIDs = try managedObjectIDs(
            forURIStrings: result.updatedObjectURIStrings,
            coordinator: databaseManager.storeCoordinator
        )
        var changes: [AnyHashable: Any] = [:]
        if !insertedObjectIDs.isEmpty {
            changes[NSInsertedObjectIDsKey] = insertedObjectIDs
        }
        if !updatedObjectIDs.isEmpty {
            changes[NSUpdatedObjectIDsKey] = updatedObjectIDs
        }
        performSynchronousRemoteViewContextMerge(changes, into: context)

        for (recordName, revision) in result.resolvedOutboxRevisions
        where localOutboxSnapshotCache[recordName]?.revision == revision {
            localOutboxSnapshotCache.removeValue(forKey: recordName)
        }
        if !result.recordNamesToUpload.isEmpty {
            var pendingKeys = pendingRecordZoneChangeKeys()
            addPendingSaves(
                result.recordNamesToUpload.map {
                    CKRecord.ID(recordName: $0, zoneID: zoneID)
                },
                pendingKeys: &pendingKeys,
                stampDeviceRecordForUserData: false
            )
        }
        if !result.recordNamesNeedingOutboxDrain.isEmpty {
            scheduleLocalOutboxDrain()
        }
    }

    func rebaseRegisteredLocalEpisodeOutboxClocks(
        remoteClockFloors: [String: Date],
        resolvedOutboxRevisions: [String: String],
        context: NSManagedObjectContext
    ) {
        guard !remoteClockFloors.isEmpty else { return }
        var metadataByRecordName: [String: NSManagedObject] = [:]
        for object in context.registeredObjects
        where !object.isDeleted && object.entity.name == Self.syncItemMetadataEntityName {
            guard let recordName = object.value(forKey: "recordName") as? String else { continue }
            metadataByRecordName[recordName] = object
        }
        for object in context.registeredObjects
        where !object.isDeleted && object.entity.name == Self.localOutboxEntityName {
            guard object.value(forKey: "category") as? String == Self.localOutboxEpisodeCategory,
                  let recordName = object.value(forKey: "recordName") as? String,
                  let revision = object.value(forKey: "revision") as? String,
                  resolvedOutboxRevisions[recordName] != revision,
                  let changedAt = object.value(forKey: "changedAt") as? Date,
                  let remoteFloor = remoteClockFloors[recordName],
                  changedAt <= remoteFloor else { continue }
            let rebasedDate = Self.nextCloudKitSafeDate(
                proposed: Date(),
                after: remoteFloor
            )
            object.setValue(rebasedDate, forKey: "changedAt")
            metadataByRecordName[recordName]?.setValue(rebasedDate, forKey: "localModifiedAt")
            metadataByRecordName[recordName]?.setValue(nil, forKey: "payloadHash")
            if let cached = localOutboxSnapshotCache[recordName], cached.revision == revision {
                localOutboxSnapshotCache[recordName] = ICCloudSyncOutboxSnapshot(
                    accountRecordName: cached.accountRecordName,
                    recordName: cached.recordName,
                    category: cached.category,
                    operation: cached.operation,
                    acknowledged: cached.acknowledged,
                    revision: cached.revision,
                    changedAt: rebasedDate,
                    payloadData: cached.payloadData
                )
            }
        }
    }

    func managedObjectIDs(
        forURIStrings uriStrings: Set<String>,
        coordinator: NSPersistentStoreCoordinator
    ) throws -> Set<NSManagedObjectID> {
        var objectIDs = Set<NSManagedObjectID>()
        objectIDs.reserveCapacity(uriStrings.count)
        for uriString in uriStrings {
            guard let url = URL(string: uriString),
                  let objectID = coordinator.managedObjectID(forURIRepresentation: url) else {
                throw Self.syncItemMetadataStoreError(
                    code: 2,
                    description: "Ein gespeicherter iCloud-Episodenstatus hat keine gültige Datenbankidentität."
                )
            }
            objectIDs.insert(objectID)
        }
        return objectIDs
    }

    @discardableResult
    nonisolated static func removePendingEpisodeStates(
        _ snapshots: [ICCloudPendingEpisodeStateSnapshot]
    ) async throws -> Int {
        guard !snapshots.isEmpty else { return 0 }
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
              let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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

    nonisolated static func subscriptionCleanupIntentRecordName(
        feedObjectURIString: String
    ) -> String {
        localSubscriptionCleanupRecordPrefix + sha256Hex(feedObjectURIString)
    }

    nonisolated static func subscriptionCleanupPendingSnapshotPayload(
        _ snapshot: ICCloudPendingSubscriptionStateSnapshot
    ) -> [String: Any] {
        [
            "accountRecordName": snapshot.accountRecordName,
            "recordName": snapshot.recordName,
            "payloadData": snapshot.payloadData,
        ]
    }

    nonisolated static func subscriptionCleanupPendingSnapshots(
        from rawValue: Any?
    ) throws -> [ICCloudPendingSubscriptionStateSnapshot] {
        guard let values = rawValue as? [[String: Any]] else {
            throw localOutboxStoreError(
                code: 2,
                description: "Ein lokaler Abo-Aufräumauftrag ist beschädigt."
            )
        }
        var snapshotsByIdentity: [String: ICCloudPendingSubscriptionStateSnapshot] = [:]
        for value in values {
            guard let accountRecordName = value["accountRecordName"] as? String,
                  !accountRecordName.isEmpty,
                  let recordName = value["recordName"] as? String,
                  !recordName.isEmpty,
                  let payloadData = value["payloadData"] as? Data else {
                throw localOutboxStoreError(
                    code: 2,
                    description: "Ein lokaler Abo-Aufräumauftrag ist beschädigt."
                )
            }
            let identity = accountRecordName + "\u{1}" + recordName
            if let existing = snapshotsByIdentity[identity], existing.payloadData != payloadData {
                throw localOutboxStoreError(
                    code: 2,
                    description: "Ein lokaler Abo-Aufräumauftrag enthält widersprüchliche Daten."
                )
            }
            snapshotsByIdentity[identity] = ICCloudPendingSubscriptionStateSnapshot(
                accountRecordName: accountRecordName,
                recordName: recordName,
                payloadData: payloadData
            )
        }
        return snapshotsByIdentity.values.sorted {
            if $0.accountRecordName != $1.accountRecordName {
                return $0.accountRecordName < $1.accountRecordName
            }
            return $0.recordName < $1.recordName
        }
    }

    nonisolated static func subscriptionCleanupIntentSnapshot(
        from entry: NSManagedObject
    ) throws -> ICCloudSubscriptionCleanupIntentSnapshot {
        guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
              accountRecordName == localSubscriptionCleanupAccountRecordName,
              let category = entry.value(forKey: "category") as? String,
              category == localSubscriptionCleanupCategory,
              let recordName = entry.value(forKey: "recordName") as? String,
              let revision = entry.value(forKey: "revision") as? String,
              !revision.isEmpty,
              let payloadData = entry.value(forKey: "payloadData") as? Data,
              let payload = try PropertyListSerialization.propertyList(
                from: payloadData,
                options: [],
                format: nil
              ) as? [String: Any],
              let feedObjectURIString = payload[localSubscriptionCleanupFeedObjectURIKey]
                as? String,
              !feedObjectURIString.isEmpty,
              recordName == subscriptionCleanupIntentRecordName(
                feedObjectURIString: feedObjectURIString
              ),
              let feedURL = payload[localSubscriptionCleanupFeedURLKey] as? String,
              !feedURL.isEmpty else {
            throw localOutboxStoreError(
                code: 2,
                description: "Ein lokaler Abo-Aufräumauftrag ist beschädigt."
            )
        }
        return ICCloudSubscriptionCleanupIntentSnapshot(
            recordName: recordName,
            revision: revision,
            payloadData: payloadData,
            feedObjectURIString: feedObjectURIString,
            feedURL: feedURL,
            pendingSnapshots: try subscriptionCleanupPendingSnapshots(
                from: payload[localSubscriptionCleanupPendingSnapshotsKey]
            )
        )
    }

    nonisolated static func subscriptionCleanupIntentEntry(
        feedObjectURIString: String,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "accountRecordName == %@",
                localSubscriptionCleanupAccountRecordName
            ),
            NSPredicate(format: "category == %@", localSubscriptionCleanupCategory),
            NSPredicate(
                format: "recordName == %@",
                subscriptionCleanupIntentRecordName(
                    feedObjectURIString: feedObjectURIString
                )
            ),
        ])
        request.fetchLimit = 2
        let entries = try context.fetch(request)
        guard entries.count <= 1 else {
            throw localOutboxStoreError(
                code: 2,
                description: "Ein lokaler Abo-Aufräumauftrag ist mehrfach vorhanden."
            )
        }
        return entries.first
    }

    nonisolated static func matchingPendingSubscriptionSnapshotData(
        _ snapshots: [ICCloudPendingSubscriptionStateSnapshot]
    ) throws -> [String: Data] {
        var dataByIdentity: [String: Data] = [:]
        for snapshot in snapshots {
            let identity = snapshot.accountRecordName + "\u{1}" + snapshot.recordName
            if let existing = dataByIdentity[identity], existing != snapshot.payloadData {
                throw pendingSubscriptionStateStoreError(
                    code: 2,
                    description: "Ein lokaler Abo-Aufräumauftrag enthält widersprüchliche Zustände."
                )
            }
            dataByIdentity[identity] = snapshot.payloadData
        }
        return dataByIdentity
    }

    @discardableResult
    nonisolated static func deleteMatchingPendingSubscriptionSnapshots(
        _ snapshots: [ICCloudPendingSubscriptionStateSnapshot],
        context: NSManagedObjectContext
    ) throws -> Int {
        guard !snapshots.isEmpty else { return 0 }
        let expectedDataByIdentity = try matchingPendingSubscriptionSnapshotData(snapshots)
        let request = NSFetchRequest<NSManagedObject>(entityName: pendingSubscriptionStateEntityName)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "accountRecordName IN %@",
                Array(Set(snapshots.map(\.accountRecordName)))
            ),
            NSPredicate(
                format: "recordName IN %@",
                Array(Set(snapshots.map(\.recordName)))
            ),
        ])
        var removed = 0
        for entry in try context.fetch(request) {
            guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
                  let recordName = entry.value(forKey: "recordName") as? String,
                  let payloadData = entry.value(forKey: "payloadData") as? Data,
                  expectedDataByIdentity[accountRecordName + "\u{1}" + recordName]
                    == payloadData else { continue }
            context.delete(entry)
            removed += 1
        }
        return removed
    }

    @discardableResult
    nonisolated static func persistPendingSubscriptionCleanupIntent(
        for feed: CDFeed,
        feedURL: String,
        pendingSnapshots: [ICCloudPendingSubscriptionStateSnapshot],
        context: NSManagedObjectContext
    ) throws -> String {
        guard !feed.objectID.isTemporaryID,
              !feedURL.isEmpty else {
            throw localOutboxStoreError(
                code: 2,
                description: "Der lokale Abo-Aufräumauftrag hat keine dauerhafte Identität."
            )
        }
        let feedObjectURIString = feed.objectID.uriRepresentation().absoluteString
        let existingEntry = try subscriptionCleanupIntentEntry(
            feedObjectURIString: feedObjectURIString,
            context: context
        )
        var pendingSnapshotsByIdentity: [String: ICCloudPendingSubscriptionStateSnapshot] = [:]
        if let existingEntry {
            let existingSnapshot = try subscriptionCleanupIntentSnapshot(from: existingEntry)
            for snapshot in existingSnapshot.pendingSnapshots {
                let identity = snapshot.accountRecordName + "\u{1}" + snapshot.recordName
                pendingSnapshotsByIdentity[identity] = snapshot
            }
        }
        // A later tombstone for the same CloudKit record supersedes the payload held by
        // an older cleanup generation. Keeping both revisions makes the durable retry
        // self-contradictory and prevents the newer pending row from ever being removed.
        for snapshot in pendingSnapshots {
            let identity = snapshot.accountRecordName + "\u{1}" + snapshot.recordName
            pendingSnapshotsByIdentity[identity] = snapshot
        }
        let uniquePendingSnapshots = pendingSnapshotsByIdentity.values.sorted {
            if $0.accountRecordName != $1.accountRecordName {
                return $0.accountRecordName < $1.accountRecordName
            }
            return $0.recordName < $1.recordName
        }
        let payload: [String: Any] = [
            localSubscriptionCleanupFeedObjectURIKey: feedObjectURIString,
            localSubscriptionCleanupFeedURLKey: feedURL,
            localSubscriptionCleanupPendingSnapshotsKey: uniquePendingSnapshots.map {
                subscriptionCleanupPendingSnapshotPayload($0)
            },
        ]
        let payloadData = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
        let entry = existingEntry ?? NSEntityDescription.insertNewObject(
            forEntityName: localOutboxEntityName,
            into: context
        )
        entry.setValue(localSubscriptionCleanupAccountRecordName, forKey: "accountRecordName")
        entry.setValue(
            subscriptionCleanupIntentRecordName(feedObjectURIString: feedObjectURIString),
            forKey: "recordName"
        )
        entry.setValue(localSubscriptionCleanupCategory, forKey: "category")
        entry.setValue(localOutboxSaveOperation, forKey: "operation")
        Self.markLocalOutboxEntryUnacknowledged(entry)
        let revision = UUID().uuidString
        entry.setValue(revision, forKey: "revision")
        entry.setValue(Date(), forKey: "changedAt")
        entry.setValue(payloadData, forKey: "payloadData")
        return revision
    }

    nonisolated static func localSubscriptionUnsubscribeError(
        underlyingError: Error? = nil
    ) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: NSLocalizedString(
                "The podcast could not be unsubscribed because the change could not be saved. Check available storage and try again.",
                comment: ""
            ),
        ]
        if let underlyingError {
            userInfo[NSUnderlyingErrorKey] = underlyingError
        }
        return NSError(
            domain: "ICiCloudSyncLocalSubscription",
            code: 1,
            userInfo: userInfo
        )
    }

    nonisolated static func commitLocalSubscriptionUnsubscribeInBackground(
        feedObjectURIString: String
    ) throws -> String {
        guard let feedObjectURI = URL(string: feedObjectURIString),
              let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localSubscriptionUnsubscribeError()
        }
        let committedCleanupRevision = try context.performAndWait {
            var outboxCommitPlan: ICBackgroundLocalOutboxCommitPlan?
            var cleanupRevision: String?
            var cleanupProtectionStageToken: String?
            do {
                guard let coordinator = context.persistentStoreCoordinator,
                      let feedObjectID = coordinator.managedObjectID(
                        forURIRepresentation: feedObjectURI
                      ),
                      let feed = try context.existingObject(with: feedObjectID) as? CDFeed,
                      !feed.isDeleted,
                      let feedURL = feed.sourceURL?.absoluteString,
                      !feedURL.isEmpty else {
                    throw localSubscriptionUnsubscribeError()
                }

                feed.subscribed = false
                cleanupRevision = try persistPendingSubscriptionCleanupIntent(
                    for: feed,
                    feedURL: feedURL,
                    pendingSnapshots: [],
                    context: context
                )
                try journalBackgroundSubscriptionChanges(
                    in: context,
                    credentialIntents: [:]
                )
                outboxCommitPlan = try prepareBackgroundLocalOutboxCommit(in: context)
                guard let cleanupRevision,
                      let subscriptionManager = SubscriptionManager.shared() else {
                    throw localSubscriptionUnsubscribeError()
                }
                guard let stageToken = subscriptionManager
                    .stageAutoDownloadsDuringUnsubscribeCleanup(
                    feedObjectURIString: feedObjectURIString,
                    revision: cleanupRevision
                ) else {
                    throw localSubscriptionUnsubscribeError()
                }
                cleanupProtectionStageToken = stageToken
                try context.save()
                subscriptionManager.commitAutoDownloadsDuringUnsubscribeCleanup(
                    feedObjectURIString: feedObjectURIString,
                    revision: cleanupRevision,
                    stageToken: stageToken
                )
                if let outboxCommitPlan {
                    completeBackgroundLocalOutboxCommit(outboxCommitPlan)
                }
                context.reset()
                return cleanupRevision
            } catch {
                if let cleanupRevision, let cleanupProtectionStageToken {
                    SubscriptionManager.shared()?
                        .cancelAutoDownloadsDuringUnsubscribeCleanup(
                            feedObjectURIString: feedObjectURIString,
                            revision: cleanupRevision,
                            stageToken: cleanupProtectionStageToken
                        )
                }
                if let outboxCommitPlan {
                    cancelBackgroundLocalOutboxCommit(outboxCommitPlan)
                }
                context.rollback()
                throw error
            }
        }
        return committedCleanupRevision
    }

    @objc(commitLocalSubscriptionUnsubscribeForFeed:completion:)
    func commitLocalSubscriptionUnsubscribe(
        for feed: CDFeed,
        completion: @escaping (NSError?) -> Void
    ) {
        guard isStarted,
              feed.managedObjectContext === databaseManager.objectContext,
              !feed.objectID.isTemporaryID else {
            completion(Self.localSubscriptionUnsubscribeError())
            return
        }
        let feedObjectURIString = feed.objectID.uriRepresentation().absoluteString
        let mergePlan: ICBackgroundLocalSubscriptionMergePlan
        do {
            mergePlan = try prepareBackgroundLocalSubscriptionMerge(
                insertedObjectURIStrings: [],
                updatedObjectURIStrings: [feedObjectURIString]
            )
        } catch {
            completion(Self.localSubscriptionUnsubscribeError(underlyingError: error))
            return
        }

        let cleanupEpoch = localSubscriptionCleanupEpoch
        let taskIdentifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else {
                completion(Self.localSubscriptionUnsubscribeError())
                return
            }
            defer {
                localSubscriptionCommitTasks.removeValue(forKey: taskIdentifier)
            }
            do {
                _ = try await Task.detached(priority: .utility) {
                    try Self.commitLocalSubscriptionUnsubscribeInBackground(
                        feedObjectURIString: feedObjectURIString
                    )
                }.value
            } catch {
                completion(Self.localSubscriptionUnsubscribeError(underlyingError: error))
                return
            }
            guard cleanupEpoch == localSubscriptionCleanupEpoch, isStarted else {
                completion(Self.localSubscriptionUnsubscribeError())
                return
            }
            commitBackgroundLocalSubscriptionMergePlan(mergePlan)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = await drainPendingSubscriptionCleanupIntentsIfNeeded() {
                    handleLocalSubscriptionCleanupFailure(error)
                }
            }
            completion(nil)
        }
        localSubscriptionCommitTasks[taskIdentifier] = task
    }

    nonisolated static func commitLocalSubscriptionResubscribeCleanupInBackground(
        feedObjectURIString: String
    ) throws -> Bool {
        guard let feedObjectURI = URL(string: feedObjectURIString),
              let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localSubscriptionUnsubscribeError()
        }
        return try context.performAndWait {
            var cleanupRevision: String?
            var cleanupProtectionStageToken: String?
            do {
                guard let coordinator = context.persistentStoreCoordinator,
                      let feedObjectID = coordinator.managedObjectID(
                        forURIRepresentation: feedObjectURI
                      ),
                      let feed = try context.existingObject(with: feedObjectID) as? CDFeed,
                      !feed.isDeleted,
                      feed.subscribed,
                      let feedURL = feed.sourceURL?.absoluteString,
                      !feedURL.isEmpty else {
                    return false
                }
                guard try subscriptionCleanupIntentEntry(
                    feedObjectURIString: feedObjectURIString,
                    context: context
                ) != nil else {
                    return false
                }
                cleanupRevision = try persistPendingSubscriptionCleanupIntent(
                    for: feed,
                    feedURL: feedURL,
                    pendingSnapshots: [],
                    context: context
                )
                guard let cleanupRevision,
                      let subscriptionManager = SubscriptionManager.shared(),
                      let stageToken = subscriptionManager
                        .stageAutoDownloadsDuringUnsubscribeCleanup(
                            feedObjectURIString: feedObjectURIString,
                            revision: cleanupRevision
                        ) else {
                    throw localSubscriptionUnsubscribeError()
                }
                cleanupProtectionStageToken = stageToken
                try context.save()
                subscriptionManager.commitAutoDownloadsDuringUnsubscribeCleanup(
                    feedObjectURIString: feedObjectURIString,
                    revision: cleanupRevision,
                    stageToken: stageToken
                )
                context.reset()
                return true
            } catch {
                if let cleanupRevision, let cleanupProtectionStageToken {
                    SubscriptionManager.shared()?
                        .cancelAutoDownloadsDuringUnsubscribeCleanup(
                            feedObjectURIString: feedObjectURIString,
                            revision: cleanupRevision,
                            stageToken: cleanupProtectionStageToken
                        )
                }
                context.rollback()
                throw error
            }
        }
    }

    @objc(commitLocalSubscriptionResubscribeCleanupForFeed:)
    func commitLocalSubscriptionResubscribeCleanup(for feed: CDFeed) -> NSError? {
        guard isStarted,
              let context = feed.managedObjectContext,
              context === databaseManager.objectContext,
              !feed.objectID.isTemporaryID else {
            return Self.localSubscriptionUnsubscribeError()
        }
        let feedObjectURIString = feed.objectID.uriRepresentation().absoluteString
        do {
            guard try Self.subscriptionCleanupIntentEntry(
                feedObjectURIString: feedObjectURIString,
                context: context
            ) != nil else {
                return databaseManager.saveReturningError() as NSError?
            }
        } catch {
            return error as NSError
        }

        let resubscribeHandoffRevision = "resubscribe-handoff-\(UUID().uuidString)"
        guard let resubscribeHandoffStageToken = subscriptionManager
            .stageAutoDownloadsDuringUnsubscribeCleanup(
                feedObjectURIString: feedObjectURIString,
                revision: resubscribeHandoffRevision
            ) else {
            return Self.localSubscriptionUnsubscribeError()
        }
        if let saveError = databaseManager.saveReturningError() {
            subscriptionManager.cancelAutoDownloadsDuringUnsubscribeCleanup(
                feedObjectURIString: feedObjectURIString,
                revision: resubscribeHandoffRevision,
                stageToken: resubscribeHandoffStageToken
            )
            return saveError as NSError
        }

        let cleanupEpoch = localSubscriptionCleanupEpoch
        let taskIdentifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                subscriptionManager.cancelAutoDownloadsDuringUnsubscribeCleanup(
                    feedObjectURIString: feedObjectURIString,
                    revision: resubscribeHandoffRevision,
                    stageToken: resubscribeHandoffStageToken
                )
                localSubscriptionCommitTasks.removeValue(forKey: taskIdentifier)
            }
            let renewedCleanup: Bool
            do {
                renewedCleanup = try await Task.detached(priority: .utility) {
                    try Self.commitLocalSubscriptionResubscribeCleanupInBackground(
                        feedObjectURIString: feedObjectURIString
                    )
                }.value
            } catch {
                guard cleanupEpoch == localSubscriptionCleanupEpoch, isStarted else { return }
                handleLocalSubscriptionCleanupFailure(error)
                return
            }
            guard renewedCleanup,
                  cleanupEpoch == localSubscriptionCleanupEpoch,
                  isStarted else { return }
            if let error = await drainPendingSubscriptionCleanupIntentsIfNeeded() {
                handleLocalSubscriptionCleanupFailure(error)
            }
        }
        localSubscriptionCommitTasks[taskIdentifier] = task
        return nil
    }

    @objc(pendingSubscriptionCleanupFeedObjectURIStringsInContext:error:)
    nonisolated static func pendingSubscriptionCleanupFeedObjectURIStrings(
        in context: NSManagedObjectContext
    ) throws -> [String] {
        try pendingSubscriptionCleanupIntentSnapshots(in: context).map(\.feedObjectURIString)
    }

    nonisolated static func pendingSubscriptionCleanupIntentSnapshots(
        in context: NSManagedObjectContext
    ) throws -> [ICCloudSubscriptionCleanupIntentSnapshot] {
        let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "accountRecordName == %@",
                localSubscriptionCleanupAccountRecordName
            ),
            NSPredicate(format: "category == %@", localSubscriptionCleanupCategory),
        ])
        return try context.fetch(request).map(subscriptionCleanupIntentSnapshot)
    }

    nonisolated static func pendingSubscriptionCleanupIntentSnapshotsForStartup()
        async throws -> [ICCloudSubscriptionCleanupIntentSnapshot] {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localOutboxStoreError(
                code: 1,
                description: "Der lokale Abo-Aufräumspeicher konnte nicht geöffnet werden."
            )
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(
                    format: "accountRecordName == %@",
                    localSubscriptionCleanupAccountRecordName
                ),
                NSPredicate(format: "category == %@", localSubscriptionCleanupCategory),
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
            request.fetchBatchSize = remoteApplyBatchSize
            let snapshots = try context.fetch(request).map { entry in
                var snapshot = try subscriptionCleanupIntentSnapshot(from: entry)
                if let feedObjectURI = URL(string: snapshot.feedObjectURIString),
                   let coordinator = context.persistentStoreCoordinator,
                   let feedObjectID = coordinator.managedObjectID(
                    forURIRepresentation: feedObjectURI
                   ),
                   let feed = try? context.existingObject(with: feedObjectID) as? CDFeed,
                   !feed.isDeleted {
                    snapshot.feedSubscribed = feed.subscribed
                }
                return snapshot
            }
            context.reset()
            return snapshots
        }
    }

    func protectPendingSubscriptionCleanupAutoDownloads() async throws {
        subscriptionManager.setUnsubscribeCleanupRecoveryBlocked(true)
        let protectionEpoch = localSubscriptionCleanupEpoch
        let intents = try await Self.pendingSubscriptionCleanupIntentSnapshotsForStartup()
        guard protectionEpoch == localSubscriptionCleanupEpoch, isStarted else {
            throw CancellationError()
        }
        for batchStart in stride(
            from: 0,
            to: intents.count,
            by: Self.startupCleanupProtectionBatchSize
        ) {
            let batchEnd = min(
                batchStart + Self.startupCleanupProtectionBatchSize,
                intents.count
            )
            for intent in intents[batchStart..<batchEnd] {
                subscriptionManager.installAutoDownloadsDuringUnsubscribeCleanup(
                    feedObjectURIString: intent.feedObjectURIString,
                    revision: intent.revision
                )
            }
            await Task.yield()
            guard protectionEpoch == localSubscriptionCleanupEpoch,
                  isStarted,
                  !Task.isCancelled else {
                throw CancellationError()
            }
        }
        subscriptionManager.setUnsubscribeCleanupRecoveryBlocked(false)
    }

    nonisolated static func pendingSubscriptionCleanupIntentBatch(
        limit: Int = remoteApplyBatchSize
    ) async throws -> [ICCloudSubscriptionCleanupIntentSnapshot] {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localOutboxStoreError(
                code: 1,
                description: "Der lokale Abo-Aufräumspeicher konnte nicht geöffnet werden."
            )
        }
        return try await context.perform {
            let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(
                    format: "accountRecordName == %@",
                    localSubscriptionCleanupAccountRecordName
                ),
                NSPredicate(format: "category == %@", localSubscriptionCleanupCategory),
            ])
            request.sortDescriptors = [NSSortDescriptor(key: "recordName", ascending: true)]
            request.fetchLimit = max(1, min(limit, remoteApplyBatchSize))
            let snapshots = try context.fetch(request).map { entry in
                var snapshot = try subscriptionCleanupIntentSnapshot(from: entry)
                if let feedObjectURI = URL(string: snapshot.feedObjectURIString),
                   let coordinator = context.persistentStoreCoordinator,
                   let feedObjectID = coordinator.managedObjectID(
                    forURIRepresentation: feedObjectURI
                   ),
                   let feed = try? context.existingObject(with: feedObjectID) as? CDFeed,
                   !feed.isDeleted {
                    snapshot.feedSubscribed = feed.subscribed
                }
                return snapshot
            }
            context.reset()
            return snapshots
        }
    }

    @discardableResult
    nonisolated static func completePendingSubscriptionCleanupIntents(
        _ intents: [ICCloudSubscriptionCleanupIntentSnapshot]
    ) async throws -> [ICCloudSubscriptionCleanupIntentSnapshot] {
        guard !intents.isEmpty else { return [] }
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw localOutboxStoreError(
                code: 1,
                description: "Der lokale Abo-Aufräumspeicher konnte nicht geöffnet werden."
            )
        }
        return try await context.perform {
            var expectedByRecordName: [String: ICCloudSubscriptionCleanupIntentSnapshot] = [:]
            for intent in intents {
                guard expectedByRecordName[intent.recordName] == nil else {
                    throw localOutboxStoreError(
                        code: 2,
                        description: "Ein lokaler Abo-Aufräumauftrag ist mehrfach vorhanden."
                    )
                }
                expectedByRecordName[intent.recordName] = intent
            }
            let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(
                    format: "accountRecordName == %@",
                    localSubscriptionCleanupAccountRecordName
                ),
                NSPredicate(format: "category == %@", localSubscriptionCleanupCategory),
                NSPredicate(format: "recordName IN %@", Array(expectedByRecordName.keys)),
            ])
            var completedIntents: [ICCloudSubscriptionCleanupIntentSnapshot] = []
            for entry in try context.fetch(request) {
                guard let recordName = entry.value(forKey: "recordName") as? String,
                      let revision = entry.value(forKey: "revision") as? String,
                      let payloadData = entry.value(forKey: "payloadData") as? Data,
                      let expected = expectedByRecordName[recordName],
                      expected.revision == revision,
                      expected.payloadData == payloadData else { continue }
                context.delete(entry)
                completedIntents.append(expected)
            }
            _ = try deleteMatchingPendingSubscriptionSnapshots(
                completedIntents.flatMap(\.pendingSnapshots),
                context: context
            )
            if context.hasChanges {
                try context.save()
            }
            context.reset()
            return completedIntents
        }
    }

    var localSubscriptionCleanupFailureStatusText: String {
        NSLocalizedString(
            "Abbestellte Podcasts wurden gespeichert, aber ihre lokalen Downloads konnten noch nicht vollständig entfernt werden. InstacastPlus versucht es später erneut.",
            comment: ""
        )
    }

    func handleLocalSubscriptionCleanupFailure(_ error: Error) {
        let nsError = error as NSError
        logSyncEvent("Lokale Abo-Bereinigung fehlgeschlagen", metadata: [
            "domain": nsError.domain,
            "code": nsError.code,
            "description": nsError.localizedDescription,
        ])
        setSyncMetadata(
            localSubscriptionCleanupFailureStatusText,
            forKey: Self.localSubscriptionCleanupStatusKey
        )
        postStateChanged()
    }

    func clearLocalSubscriptionCleanupFailureIfNeeded() {
        guard defaults.object(forKey: Self.localSubscriptionCleanupStatusKey) != nil else { return }
        setSyncMetadata(nil, forKey: Self.localSubscriptionCleanupStatusKey)
        postStateChanged()
    }

    nonisolated static func localSubscriptionCleanupCancellationError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }

    func performPendingSubscriptionCleanupIntentDrain() async throws {
        while !Task.isCancelled {
            let intents = try await Self.pendingSubscriptionCleanupIntentBatch()
            try Task.checkCancellation()
            guard !intents.isEmpty else { return }

            for intent in intents {
                subscriptionManager.installAutoDownloadsDuringUnsubscribeCleanup(
                    feedObjectURIString: intent.feedObjectURIString,
                    revision: intent.revision
                )
            }

            guard let context = databaseManager.objectContext else {
                throw Self.localOutboxStoreError(
                    code: 1,
                    description: "Die lokale Abo-Bereinigung konnte nicht auf die Podcast-Daten zugreifen."
                )
            }
            let objectIDs = try managedObjectIDs(
                forURIStrings: Set(intents.map(\.feedObjectURIString)),
                coordinator: databaseManager.storeCoordinator
            )
            var feedsByObjectURIString: [String: CDFeed] = [:]
            feedsByObjectURIString.reserveCapacity(objectIDs.count)
            for objectID in objectIDs {
                guard let feed = try? context.existingObject(with: objectID) as? CDFeed,
                      !feed.isDeleted else { continue }
                feedsByObjectURIString[objectID.uriRepresentation().absoluteString] = feed
            }
            let existingFeedObjectIDs = Set(feedsByObjectURIString.values.map(\.objectID))
            if !existingFeedObjectIDs.isEmpty {
                performSynchronousRemoteViewContextMerge(
                    [NSUpdatedObjectIDsKey: existingFeedObjectIDs],
                    into: context
                )
            }
            func feedMatchesDurableSubscriptionState(
                _ intent: ICCloudSubscriptionCleanupIntentSnapshot
            ) -> Bool {
                guard let durableSubscribed = intent.feedSubscribed,
                      let feed = feedsByObjectURIString[intent.feedObjectURIString] else {
                    return false
                }
                return feed.subscribed == durableSubscribed
            }
            let resubscribedIntents = intents.filter {
                $0.feedSubscribed == true
                    && feedMatchesDurableSubscriptionState($0)
            }
            let unsubscribedIntents = intents.filter {
                $0.feedSubscribed == false
                    && feedMatchesDurableSubscriptionState($0)
            }
            let orphanedIntents = intents.filter {
                $0.feedSubscribed == nil
                    || feedsByObjectURIString[$0.feedObjectURIString] == nil
            }
            let stateMismatchedIntents = intents.filter {
                $0.feedSubscribed != nil
                    && feedsByObjectURIString[$0.feedObjectURIString] != nil
                    && !feedMatchesDurableSubscriptionState($0)
            }
            let resubscribedFeeds = resubscribedIntents.compactMap {
                feedsByObjectURIString[$0.feedObjectURIString]
            }
            let unsubscribedFeeds = unsubscribedIntents.compactMap {
                feedsByObjectURIString[$0.feedObjectURIString]
            }

            if !resubscribedFeeds.isEmpty {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    subscriptionManager.performResubscribeCleanup(for: resubscribedFeeds) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                try Task.checkCancellation()
                let completedResubscribedIntents = try await Self
                    .completePendingSubscriptionCleanupIntents(resubscribedIntents)
                for intent in completedResubscribedIntents {
                    subscriptionManager.completeAutoDownloadsDuringUnsubscribeCleanup(
                        feedObjectURIString: intent.feedObjectURIString,
                        revision: intent.revision
                    )
                }
                await Task.yield()
                continue
            }
            if !unsubscribedFeeds.isEmpty {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    subscriptionManager.performUnsubscribeSideEffects(for: unsubscribedFeeds) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
                try Task.checkCancellation()
                let completedUnsubscribedIntents = try await Self
                    .completePendingSubscriptionCleanupIntents(unsubscribedIntents)
                for intent in completedUnsubscribedIntents {
                    subscriptionManager.completeAutoDownloadsDuringUnsubscribeCleanup(
                        feedObjectURIString: intent.feedObjectURIString,
                        revision: intent.revision
                    )
                }
                await Task.yield()
                continue
            }
            if !orphanedIntents.isEmpty {
                try Task.checkCancellation()
                let completedOrphanedIntents = try await Self
                    .completePendingSubscriptionCleanupIntents(orphanedIntents)
                for intent in completedOrphanedIntents {
                    subscriptionManager.completeAutoDownloadsDuringUnsubscribeCleanup(
                        feedObjectURIString: intent.feedObjectURIString,
                        revision: intent.revision
                    )
                }
            }
            if !stateMismatchedIntents.isEmpty {
                await Task.yield()
                continue
            }
            await Task.yield()
        }
        throw CancellationError()
    }

    func drainPendingSubscriptionCleanupIntentsIfNeeded() async -> NSError? {
        guard isStarted else { return nil }
        let callerEpoch = localSubscriptionCleanupEpoch
        if let startupCleanupProtectionTask {
            let protectionError = await startupCleanupProtectionTask.value
            guard callerEpoch == localSubscriptionCleanupEpoch, isStarted else {
                return nil
            }
            self.startupCleanupProtectionTask = nil
            if Task.isCancelled { return nil }
            if let protectionError { return protectionError }
        }
        localSubscriptionCleanupRequestedGeneration &+= 1
        let callerGeneration = localSubscriptionCleanupRequestedGeneration

        while true {
            guard callerEpoch == localSubscriptionCleanupEpoch, isStarted else {
                return nil
            }
            if Task.isCancelled {
                return nil
            }
            let task: Task<ICCloudSubscriptionCleanupDrainResult, Never>
            if let existingTask = localSubscriptionCleanupTask {
                task = existingTask
            } else {
                let identifier = UUID()
                let initialGeneration = localSubscriptionCleanupRequestedGeneration
                let newTask = Task { @MainActor [weak self]
                    () -> ICCloudSubscriptionCleanupDrainResult in
                    guard let self else {
                        return ICCloudSubscriptionCleanupDrainResult(
                            error: Self.localSubscriptionCleanupCancellationError(),
                            attemptedGeneration: initialGeneration,
                            completedGeneration: 0
                        )
                    }
                    var attemptedGeneration = initialGeneration
                    var resultError: NSError?
                    repeat {
                        guard callerEpoch == localSubscriptionCleanupEpoch,
                              isStarted,
                              !Task.isCancelled else {
                            resultError = Self.localSubscriptionCleanupCancellationError()
                            break
                        }
                        attemptedGeneration = localSubscriptionCleanupRequestedGeneration
                        do {
                            try await self.performPendingSubscriptionCleanupIntentDrain()
                            localSubscriptionCleanupCompletedGeneration = max(
                                localSubscriptionCleanupCompletedGeneration,
                                attemptedGeneration
                            )
                        } catch is CancellationError {
                            resultError = Self.localSubscriptionCleanupCancellationError()
                        } catch {
                            resultError = error as NSError
                        }
                    } while resultError == nil
                        && localSubscriptionCleanupCompletedGeneration
                            < localSubscriptionCleanupRequestedGeneration

                    let completedGeneration = localSubscriptionCleanupCompletedGeneration
                    let ownsTask = localSubscriptionCleanupTaskIdentifier == identifier
                    if ownsTask {
                        localSubscriptionCleanupTask = nil
                        localSubscriptionCleanupTaskIdentifier = nil
                    }
                    if resultError == nil,
                       ownsTask,
                       callerEpoch == localSubscriptionCleanupEpoch,
                       isStarted {
                        subscriptionManager.setUnsubscribeCleanupRecoveryBlocked(false)
                        clearLocalSubscriptionCleanupFailureIfNeeded()
                    }
                    return ICCloudSubscriptionCleanupDrainResult(
                        error: resultError,
                        attemptedGeneration: attemptedGeneration,
                        completedGeneration: completedGeneration
                    )
                }
                localSubscriptionCleanupTaskIdentifier = identifier
                localSubscriptionCleanupTask = newTask
                task = newTask
            }

            let result = await task.value
            guard callerEpoch == localSubscriptionCleanupEpoch, isStarted else {
                return nil
            }
            if callerGeneration <= localSubscriptionCleanupCompletedGeneration {
                return nil
            }
            if Task.isCancelled {
                return nil
            }
            if let error = result.error {
                if error.domain == NSCocoaErrorDomain,
                   error.code == NSUserCancelledError {
                    return nil
                }
                if callerGeneration > result.attemptedGeneration {
                    continue
                }
                return error
            }
        }
    }

    nonisolated static func deleteAllPendingSubscriptionStates(
        accountRecordName: String? = nil
    ) async throws {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
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
        syncEngineCallbackGate.beginRemoteApplyAccountTransition()
        await syncEngineCallbackGate.awaitRemoteApplyCommitLeases()
        iCloudAccountTransitionToken &+= 1
        return iCloudAccountTransitionToken
    }

    func releaseICloudAccountTransition() {
        syncEngineCallbackGate.endRemoteApplyAccountTransition()
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
        if hasPendingLegacyFinalDeviceRecordUpdate,
           let previousAccountUserRecordName,
           !migrateLegacyFinalDeviceRecordUpdateIntentIfNeeded(
                accountRecordName: previousAccountUserRecordName
           ) {
            throw NSError(
                domain: "ICiCloudSyncDeviceControlIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Die ausstehende iCloud-Geräteänderung konnte nicht lokal migriert werden."]
            )
        }
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
            await cancelAndAwaitInitialQueueTask()
            guard lookupGeneration == cloudAccountGeneration else { return false }
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
            try bindSingletonClockFloors(
                from: pendingScope,
                to: currentAccountUserRecordName
            )
            guard bindingGeneration == cloudAccountGeneration else { return false }
            try await bindPendingSingletonUploadIntents(
                from: pendingScope,
                to: currentAccountUserRecordName
            )
            guard bindingGeneration == cloudAccountGeneration else { return false }
            try bindPendingDeviceControlIntents(
                from: pendingScope,
                to: currentAccountUserRecordName
            )
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
            try bindSingletonClockFloors(
                from: Self.localOutboxUnboundAccountRecordName,
                to: currentAccountUserRecordName
            )
            guard bindingGeneration == cloudAccountGeneration else { return false }
            try await bindPendingSingletonUploadIntents(
                from: Self.localOutboxUnboundAccountRecordName,
                to: currentAccountUserRecordName
            )
            guard bindingGeneration == cloudAccountGeneration else { return false }
            try bindPendingDeviceControlIntents(
                from: Self.localOutboxUnboundAccountRecordName,
                to: currentAccountUserRecordName
            )
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
        migrateResumableInitialBackfillAccountsIfNeeded()
        if episodesSyncEnabled {
            prepareInitialEpisodeFetchBeforeUploadIfNeeded(
                accountRecordName: currentAccountUserRecordName
            )
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
                await continueEnabledSyncAfterAccountVerification()
                scheduleApplyPendingPayloads()
            }
        }
        resumePendingDeviceControlIntentsForVerifiedAccount()
        requestKnownRecordSystemFieldsPruneIfNeeded(
            accountRecordName: currentAccountUserRecordName
        )
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
        if hasPendingLegacyFinalDeviceRecordUpdate,
           let previousAccountRecordName,
           !migrateLegacyFinalDeviceRecordUpdateIntentIfNeeded(
                accountRecordName: previousAccountRecordName
           ) {
            throw NSError(
                domain: "ICiCloudSyncDeviceControlIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Die ausstehende iCloud-Geräteänderung konnte nicht lokal migriert werden."]
            )
        }
        setICloudAccountIdentityVerified(false)
        ensurePendingLocalOutboxScope()
        setICloudAccountSignedOut(false)
        defaults.set(true, forKey: Self.localOutboxAwaitingAccountSwitchKey)
        try persistICloudAccountResetRequired()
        // Close/cancel every old-account producer before the bounded background cleanup.
        // Local edits made while cleanup suspends stay in the same durable pending scope
        // that may already contain cold-start edits captured before this account event.
        await cancelAndAwaitInitialQueueTask()
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
            cancelCloudInventoryRefreshForSync()
            requestedCloudInventoryRefreshReason = nil
            cloudAccountGeneration &+= 1
            updateSyncEngineCallbackGate()
            isFetchingCloudInventory = false
            pendingCloudInventoryRefreshReason = nil
            defaults.removeObject(forKey: Self.cloudInventoryKey)
            defaults.removeObject(forKey: Self.lastSyncDateKey)
            setSyncMetadata([String: [String: Any]](), forKey: Self.deviceCacheKey)
            pendingInitialUploadBatches.removeAll()
            recentlyUploadedRecordVersions.removeAll()
            hasUnresolvedSyncFailures = false
            isApplyingRemoteChange = false
            isPerformingManualSync = false
            syncedUserDataInCurrentRun = false
            clearSyncActivity()
            postDevicesChanged()
            return
        }

        if transferPendingChanges {
            flushPendingSingletonChangesForSameAccountTransition()
        }
        let transferableChanges = transferPendingChanges ? transferablePendingUserChanges() : []
        syncEngine = nil
        updateSyncEngineCallbackGate()
        if transferPendingChanges {
            resetAllLocalSyncMetadata(
                preserveInitialBackfillState: true,
                preserveSameAccountUserDataState: true,
                preservePendingDeviceControlIntents: true
            )
        } else {
            resetAllLocalSyncMetadata(
                preservePendingSingletonIntents: true,
                preservePendingDeviceControlIntents: true
            )
            resetInitialBackfillCursorsForEnabledOptions()
        }
        initializeSyncEngineIfNeeded()
        if !transferableChanges.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: transferableChanges)
        }
        scheduleCurrentEnabledDataForUpload()
        if transferPendingChanges {
            scheduleSettingsChangeCheck()
        }
        postDevicesChanged()
    }

    func flushPendingSingletonChangesForSameAccountTransition() {
        settingsDebounceWorkItem?.cancel()
        settingsDebounceWorkItem = nil
        settingsChangeCheckRevision &+= 1

        guard scrollDebounceWorkItem != nil else { return }
        scrollDebounceWorkItem?.cancel()
        scrollDebounceWorkItem = nil
        if episodesSyncEnabled {
            queueListScrollPositionsRecord()
        }
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
                || recordName == RecordPrefix.appSettings
                || recordName == RecordPrefix.listScrollPositions
                || recordName == RecordPrefix.subscriptionListSettings
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
            // The event itself proves this account's zone no longer exists. Invalidate
            // completion before fallible local cleanup so an error cannot suppress reseeding.
            invalidateInitialBackfillParticipation()
            storeCloudInventory([:], reason: "fetchedZoneDeletion")
            defaults.removeObject(forKey: Self.cloudInventoryPayloadScanCompletedKey)
            cachedSyncTotalCounts = nil
            clearInitialUploadCursors()
            pendingInitialUploadBatches.removeAll()
            recentlyUploadedRecordVersions.removeAll()
            resetInitialBackfillCursorsForEnabledOptions()
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
            syncEngine?.state.add(
                pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]
            )
            requestedCloudInventoryRefreshReason = "fetchedZoneReseed"
            captureInitialBackfillTotalsFromCachedCountsIfNeeded()
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

        // A fetch after an upload can return the exact records this process just saved.
        // Only high-volume episode/subscription records are skipped, and only when the
        // CloudKit change tag exactly matches the acknowledged server version. Settings
        // must always pass through apply so a later enable can offer the cloud/local choice.
        let verifiedOwnEchoModifications = event.modifications.filter { modification in
            let record = modification.record
            guard let uploadedChangeTag = recentlyUploadedRecordVersions[record.recordID.recordName],
                  let fetchedChangeTag = record.recordChangeTag,
                  !uploadedChangeTag.isEmpty,
                  !fetchedChangeTag.isEmpty,
                  uploadedChangeTag == fetchedChangeTag else {
                return false
            }
            return (record["deviceID"] as? String) == deviceID
        }
        let localEchoModifications = verifiedOwnEchoModifications.filter {
            isBulkEchoRecord($0.record)
        }
        var localEchoRecordVersions: [String: String] = [:]
        for modification in localEchoModifications {
            if let changeTag = modification.record.recordChangeTag {
                localEchoRecordVersions[modification.record.recordID.recordName] = changeTag
            }
        }
        for modification in event.modifications {
            recentlyUploadedRecordVersions.removeValue(forKey: modification.record.recordID.recordName)
        }
        let remoteModifications = event.modifications.filter { modification in
            let record = modification.record
            guard let localEchoChangeTag = localEchoRecordVersions[record.recordID.recordName],
                  let fetchedChangeTag = record.recordChangeTag else {
                return true
            }
            return localEchoChangeTag != fetchedChangeTag
        }
        let orderedRecords = orderedModifications(remoteModifications)

        if event.modifications.contains(where: { isUserDataRecordID($0.record.recordID) })
            || event.deletions.contains(where: { isUserDataRecordID($0.recordID) }) {
            syncedUserDataInCurrentRun = true
        }

        let activityDirection = fetchedActivityDirection(
            remoteModifications: remoteModifications,
            deletions: event.deletions,
            verifiedOwnEchoModifications: verifiedOwnEchoModifications
        )
        beginSyncActivity(activityDirection)
        if activityDirection == .verifying {
            recordSyncActivity(verifiedOwnEchoModifications.count)
        }

        defer {
            if generation == cloudAccountGeneration {
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
                let committedUserDataDeletionCount = batch.filter {
                    isVisibleSyncActivityDeletion($0)
                }.count
                if committedUserDataDeletionCount > 0 {
                    recordSyncActivity(committedUserDataDeletionCount)
                }
                if batch.contains(where: { isCloudInventoryRecordType($0.recordType) }) {
                    invalidateCloudInventory(reason: "fetchedRecordDeletion")
                    if requestedCloudInventoryRefreshReason == nil {
                        requestedCloudInventoryRefreshReason = "fetchedRecordDeletion"
                    }
                }
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
                    if record.recordType == RecordKind.subscription
                                || record.recordType == RecordKind.subscriptionTombstone {
                        result.formUnion(Self.subscriptionOutboxRecordNames(
                            forCloudRecordName: record.recordID.recordName
                        ))
                    } else if record.recordType == RecordKind.subscriptionListSettings {
                        result.insert(record.recordID.recordName)
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
            if episodesSyncEnabled, !stagedEpisodeStates.isEmpty {
                do {
                    guard let episodeEpoch = syncEngineCallbackGate.beginEpisodeApply(
                        generation: generation,
                        accountRecordName: accountRecordName
                    ) else { return }
                    let episodeResult = try await Self.applyPendingEpisodeStateBatchInBackground(
                        accountRecordName: accountRecordName,
                        snapshots: stagedEpisodeStates,
                        generation: generation,
                        episodeEpoch: episodeEpoch,
                        validityGate: syncEngineCallbackGate,
                        remoteOriginGate: remoteOriginGate,
                        remoteEpisodeClockGate: remoteEpisodeClockGate
                    )
                    try consumeEpisodeApplyBatchResult(episodeResult)
                } catch is CancellationError {
                    return
                } catch {
                    handleLocalPersistenceFailure(error)
                    return
                }
            }
            do {
                let didFlush = try performSynchronousRemoteApplyBatch {
                    _ = try processFetchedModificationBatch(
                        batch,
                        modificationCountsByType: &modificationCountsByType
                    )
                }
                guard didFlush else { return }
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
        modificationCountsByType: inout [String: Int]
    ) throws -> FetchedModificationBatchResult {
        var records: [CKRecord] = []
        records.reserveCapacity(batch.count)
        for modification in batch {
            let record = modification.record
            records.append(record)
            modificationCountsByType[record.recordType, default: 0] += 1
            if record.recordType != RecordKind.episodeState
                && record.recordType != RecordKind.subscription
                && record.recordType != RecordKind.subscriptionTombstone
                && record.recordType != RecordKind.subscriptionListSettings {
                applyRemoteNonEpisodeRecord(record)
            }
            if isVisibleSyncActivityRecordType(record.recordType) {
                recordSyncActivity(1)
            }
        }
        return FetchedModificationBatchResult(records: records)
    }


    nonisolated static func deterministicallyResolvedEpisodesByObjectHash(
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

    func fetchedActivityDirection(
        remoteModifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion],
        verifiedOwnEchoModifications: [CKDatabase.RecordZoneChange.Modification]
    ) -> SyncActivityDirection {
        let verifiedOwnEchoRecordNames = Set(verifiedOwnEchoModifications.map {
            $0.record.recordID.recordName
        })
        let containsRemoteUserData = remoteModifications.contains {
            isVisibleSyncActivityRecordType($0.record.recordType)
                && !verifiedOwnEchoRecordNames.contains($0.record.recordID.recordName)
        } || deletions.contains {
            isVisibleSyncActivityDeletion($0)
        }
        if containsRemoteUserData {
            return .down
        }
        let containsVerifiedLocalEcho = verifiedOwnEchoModifications.contains {
            isVisibleSyncActivityRecordType($0.record.recordType)
        }
        return containsVerifiedLocalEcho ? .verifying : .down
    }

    func isVisibleSyncActivityRecordType(_ recordType: String) -> Bool {
        recordType == RecordKind.episodeState
            || recordType == RecordKind.subscription
            || recordType == RecordKind.subscriptionTombstone
            || recordType == RecordKind.appSettings
            || recordType == RecordKind.listScrollPositions
            || recordType == RecordKind.subscriptionListSettings
    }

    func isVisibleSyncActivityDeletion(
        _ deletion: CKDatabase.RecordZoneChange.Deletion
    ) -> Bool {
        deletion.recordType != RecordKind.subscriptionTombstone
            && isVisibleSyncActivityRecordType(deletion.recordType)
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

    func acknowledgePendingSingletonUpload(_ record: CKRecord) {
        guard record.recordID.recordName == RecordPrefix.appSettings
                || record.recordID.recordName == RecordPrefix.listScrollPositions
                || record.recordID.recordName == RecordPrefix.subscriptionListSettings,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              let intent = pendingSingletonUploadIntent(
                recordName: record.recordID.recordName,
                accountRecordName: accountRecordName
              ),
              let payload = payloadDictionary(from: record) else {
            return
        }
        let acknowledgedRevision = payload[Self.localMutationRevisionPayloadKey] as? String
        let acknowledgedModifiedAt = payload["updatedAt"] as? Date
        if acknowledgedRevision == intent.revision,
           clearPendingSingletonUploadIntent(intent) {
            return
        }

        logSyncEvent("Veraltete Singleton-Bestätigung wird erneut gesendet", metadata: [
            "recordName": record.recordID.recordName,
            "revisionMatches": acknowledgedRevision == intent.revision,
            "modifiedAtMatches": acknowledgedModifiedAt == intent.modifiedAt,
        ])
        if queuePendingSingletonUploadWithoutReplacingIntent(
            recordName: record.recordID.recordName
        ) {
            requiresImmediateSingletonRecordResend = true
        }
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

        let episodeConflictServerRecords = conflictServerRecords.filter {
            $0.recordType == RecordKind.episodeState
        }
        var preappliedEpisodeConflictRecordNames = Set<String>()
        var resolvedEpisodeConflictOutboxRevisions: [String: String] = [:]
        if !episodeConflictServerRecords.isEmpty {
            do {
                let writes = try episodeConflictServerRecords.compactMap {
                    record -> ICCloudPendingEpisodeStateWrite? in
                    guard let payload = payloadDictionary(from: record) else { return nil }
                    return ICCloudPendingEpisodeStateWrite(
                        recordName: record.recordID.recordName,
                        payloadData: try PropertyListSerialization.data(
                            fromPropertyList: payload,
                            format: .binary,
                            options: 0
                        )
                    )
                }
                let staged = try await Self.stagePendingEpisodeStates(
                    accountRecordName: accountRecordName,
                    writes: writes
                )
                preappliedEpisodeConflictRecordNames = Set(staged.map(\.recordName))
                if episodesSyncEnabled, !staged.isEmpty {
                    guard let episodeEpoch = syncEngineCallbackGate.beginEpisodeApply(
                        generation: generation,
                        accountRecordName: accountRecordName
                    ) else { return }
                    var index = staged.startIndex
                    while index < staged.endIndex {
                        let end = staged.index(
                            index,
                            offsetBy: Self.remoteApplyBatchSize,
                            limitedBy: staged.endIndex
                        ) ?? staged.endIndex
                        let result = try await Self.applyPendingEpisodeStateBatchInBackground(
                            accountRecordName: accountRecordName,
                            snapshots: Array(staged[index..<end]),
                            generation: generation,
                            episodeEpoch: episodeEpoch,
                            validityGate: syncEngineCallbackGate,
                            remoteOriginGate: remoteOriginGate,
                            remoteEpisodeClockGate: remoteEpisodeClockGate
                        )
                        resolvedEpisodeConflictOutboxRevisions.merge(
                            result.resolvedOutboxRevisions
                        ) { _, latest in latest }
                        try consumeEpisodeApplyBatchResult(result)
                        index = end
                        if index < staged.endIndex {
                            await Task.yield()
                            guard generation == cloudAccountGeneration,
                                  episodesSyncEnabled,
                                  isICloudAccountIdentityVerified,
                                  defaults.string(forKey: Self.accountUserRecordNameKey)
                                    == accountRecordName else { return }
                        }
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
        }

        for record in event.savedRecords where isVisibleSyncActivityRecordType(record.recordType) {
            if let changeTag = record.recordChangeTag {
                recentlyUploadedRecordVersions[record.recordID.recordName] = changeTag
            }
        }

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
            acknowledgePendingSingletonUpload(record)
            if record.recordType == RecordKind.device, let payload = payloadDictionary(from: record) {
                updateDeviceCache(with: payload)
                _ = acknowledgePendingDeviceControlSave(
                    record,
                    accountRecordName: accountRecordName
                )
            }
        }
        var acknowledgedSaveRevisions: [String: String] = [:]
        for record in event.savedRecords where record.recordType != RecordKind.device {
            guard let payload = payloadDictionary(from: record),
                  let revision = payload[Self.localMutationRevisionPayloadKey] as? String,
                  !revision.isEmpty else { continue }
            acknowledgedSaveRevisions[record.recordID.recordName] = revision
        }

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
        var syncZoneWasMissing = false
        func invalidateMissingSyncZoneIfNeeded() {
            guard !syncZoneWasMissing else { return }
            syncZoneWasMissing = true
            invalidateInitialBackfillParticipation()
            clearInitialUploadCursors()
            pendingInitialUploadBatches.removeAll()
            recentlyUploadedRecordVersions.removeAll()
            resetInitialBackfillCursorsForEnabledOptions()
        }

        for failedSave in event.failedRecordSaves {
            if failedSave.error.code == .zoneNotFound {
                invalidateMissingSyncZoneIfNeeded()
            }
            if !(await handleFailedRecordSave(
                failedSave,
                preappliedEpisodeConflictRecordNames: preappliedEpisodeConflictRecordNames,
                resolvedEpisodeConflictOutboxRevisions: resolvedEpisodeConflictOutboxRevisions,
                retryRecords: &retryRecords,
                retryZones: &retryZones
            )) {
                hasFailedRecordChanges = true
                lastFailureCode = failedSave.error.code
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
        }

        for (recordID, error) in event.failedRecordDeletes {
            if error.code == .zoneNotFound {
                invalidateMissingSyncZoneIfNeeded()
            }
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

        let localOutboxAcknowledgementResult: ICCloudLocalOutboxAcknowledgementResult
        do {
            localOutboxAcknowledgementResult = try await Self.acknowledgeLocalOutboxOperationsInBackground(
                saveRevisionsByRecordName: acknowledgedSaveRevisions,
                deleteRevisionsByRecordName: acknowledgedDeleteRevisions.filter {
                    !$0.key.hasPrefix(RecordPrefix.device)
                },
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
              defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
            return
        }
        consumeLocalOutboxAcknowledgementResult(localOutboxAcknowledgementResult)
        recordInitialUploadRecordsSaved(event.savedRecords.map { $0.recordID })
        acknowledgePendingDeviceControlDeletes(
            acknowledgedDeleteRevisions,
            accountRecordName: accountRecordName
        )
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
        } else {
            if !event.failedRecordSaves.isEmpty || !event.failedRecordDeletes.isEmpty {
                handledRecordZonePartialFailureInCurrentSend = true
            }
            if !hasUnresolvedSyncFailures {
                await queueNextInitialUploadPageDuringActiveSend()
                markSyncCompletedIfFinished()
            }
        }
    }

    nonisolated static func acknowledgeLocalOutboxOperationsInBackground(
        saveRevisionsByRecordName: [String: String],
        deleteRevisionsByRecordName: [String: String],
        accountRecordName: String
    ) async throws -> ICCloudLocalOutboxAcknowledgementResult {
        var sentAttemptsByRecordName: [String: ICCloudLocalOutboxAcknowledgementAttempt] = [:]
        for (recordName, revision) in saveRevisionsByRecordName {
            sentAttemptsByRecordName[recordName] = ICCloudLocalOutboxAcknowledgementAttempt(
                revision: revision,
                operation: localOutboxSaveOperation
            )
        }
        for (recordName, revision) in deleteRevisionsByRecordName {
            sentAttemptsByRecordName[recordName] = ICCloudLocalOutboxAcknowledgementAttempt(
                revision: revision,
                operation: localOutboxDeleteOperation
            )
        }
        let sentAttempts = sentAttemptsByRecordName
        guard !sentAttempts.isEmpty else {
            return ICCloudLocalOutboxAcknowledgementResult(
                objectIDURIsByRecordName: [:],
                updatedObjectIDURIs: [],
                acknowledgedAttemptsByRecordName: [:],
                fullyAcknowledgedAttemptsByRecordName: [:],
                needsOutboxDrain: false
            )
        }

        var lastPersistenceError: Error?
        for attempt in 0..<2 {
            guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
                throw localOutboxStoreError(
                    code: 1,
                    description: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."
                )
            }
            context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
            do {
                return try await context.perform {
                    let expandedRecordNames = sentAttempts.keys.reduce(
                        into: Set<String>()
                    ) { result, recordName in
                        result.formUnion(subscriptionOutboxRecordNames(
                            forCloudRecordName: recordName
                        ))
                    }
                    let request = NSFetchRequest<NSManagedObject>(
                        entityName: localOutboxEntityName
                    )
                    request.predicate = NSPredicate(
                        format: "accountRecordName == %@ AND recordName IN %@",
                        accountRecordName,
                        Array(expandedRecordNames)
                    )
                    let entries = try context.fetch(request)
                    var entriesByRecordName: [String: NSManagedObject] = [:]
                    var objectIDURIsByRecordName: [String: URL] = [:]
                    for entry in entries {
                        guard let recordName = entry.value(forKey: "recordName") as? String,
                              entriesByRecordName[recordName] == nil else {
                            throw localOutboxStoreError(
                                code: 2,
                                description: "Ein lokaler iCloud-Outbox-Eintrag hat keine eindeutige Identität."
                            )
                        }
                        entriesByRecordName[recordName] = entry
                        objectIDURIsByRecordName[recordName] = entry.objectID.uriRepresentation()
                    }

                    var acknowledgedAttemptsByRecordName:
                        [String: ICCloudLocalOutboxAcknowledgementAttempt] = [:]
                    var updatedObjectIDURIs: [URL] = []
                    var needsOutboxDrain = false
                    for (recordName, sentAttempt) in sentAttempts {
                        guard let entry = entriesByRecordName[recordName] else { continue }
                        guard let currentRevision = entry.value(forKey: "revision") as? String,
                              let currentOperation = entry.value(forKey: "operation") as? String else {
                            throw localOutboxStoreError(
                                code: 2,
                                description: "Ein lokaler iCloud-Outbox-Eintrag hat keine gültige Revision."
                            )
                        }
                        guard currentRevision == sentAttempt.revision,
                              currentOperation == sentAttempt.operation else {
                            needsOutboxDrain = true
                            continue
                        }
                        entry.setValue(
                            sentAttempt.revision,
                            forKey: "acknowledgedRevision"
                        )
                        entry.setValue(
                            sentAttempt.operation,
                            forKey: "acknowledgedOperation"
                        )
                        acknowledgedAttemptsByRecordName[recordName] = sentAttempt
                        updatedObjectIDURIs.append(entry.objectID.uriRepresentation())
                    }

                    var fullyAcknowledgedAttemptsByRecordName:
                        [String: ICCloudLocalOutboxAcknowledgementAttempt] = [:]
                    for (recordName, sentAttempt) in acknowledgedAttemptsByRecordName {
                        guard let entry = entriesByRecordName[recordName],
                              entry.value(forKey: "category") as? String
                                == localOutboxSubscriptionCategory else {
                            fullyAcknowledgedAttemptsByRecordName[recordName] = sentAttempt
                            continue
                        }
                        let pairRecordNames = subscriptionOutboxRecordNames(
                            forCloudRecordName: recordName
                        )
                        let pairEntries = pairRecordNames.compactMap {
                            entriesByRecordName[$0]
                        }
                        guard pairEntries.count == 2,
                              Set(pairEntries.compactMap {
                                  $0.value(forKey: "revision") as? String
                              }).count == 1,
                              pairEntries.allSatisfy({
                                  localOutboxEntryIsAcknowledged($0)
                              }) else {
                            continue
                        }
                        for pairEntry in pairEntries {
                            guard let pairRecordName = pairEntry.value(forKey: "recordName") as? String,
                                  let pairRevision = pairEntry.value(forKey: "revision") as? String,
                                  let pairOperation = pairEntry.value(forKey: "operation") as? String else {
                                throw localOutboxStoreError(
                                    code: 2,
                                    description: "Ein lokales iCloud-Abo-Paar ist unvollständig."
                                )
                            }
                            fullyAcknowledgedAttemptsByRecordName[pairRecordName] =
                                ICCloudLocalOutboxAcknowledgementAttempt(
                                    revision: pairRevision,
                                    operation: pairOperation
                                )
                        }
                    }

                    if context.hasChanges {
                        try context.save()
                    }
                    return ICCloudLocalOutboxAcknowledgementResult(
                        objectIDURIsByRecordName: objectIDURIsByRecordName,
                        updatedObjectIDURIs: updatedObjectIDURIs,
                        acknowledgedAttemptsByRecordName: acknowledgedAttemptsByRecordName,
                        fullyAcknowledgedAttemptsByRecordName:
                            fullyAcknowledgedAttemptsByRecordName,
                        needsOutboxDrain: needsOutboxDrain
                    )
                }
            } catch {
                lastPersistenceError = error
                let persistenceError = error as NSError
                if attempt == 0,
                   persistenceError.domain == NSCocoaErrorDomain,
                   persistenceError.code == 133020 {
                    continue
                }
                throw error
            }
        }
        throw lastPersistenceError ?? localOutboxStoreError(
            code: 3,
            description: "Die lokale iCloud-Outbox konnte nicht konfliktfrei bestätigt werden."
        )
    }

    func consumeLocalOutboxAcknowledgementResult(
        _ result: ICCloudLocalOutboxAcknowledgementResult
    ) {
        guard let context = databaseManager.objectContext,
              let coordinator = context.persistentStoreCoordinator else {
            scheduleLocalOutboxDrain()
            return
        }
        let objectIDsByRecordName = result.objectIDURIsByRecordName.reduce(
            into: [String: NSManagedObjectID]()
        ) { resolved, item in
            if let objectID = coordinator.managedObjectID(forURIRepresentation: item.value) {
                resolved[item.key] = objectID
            }
        }
        let updatedObjectIDs = result.updatedObjectIDURIs.compactMap {
            coordinator.managedObjectID(forURIRepresentation: $0)
        }
        if !updatedObjectIDs.isEmpty {
            // These IDs are local outbox metadata, not remotely applied user data. Merging
            // them under the remote-origin flag would also suppress a genuine user edit that
            // Core Data delivers in the same pending ObjectsDidChange notification.
            NSManagedObjectContext.mergeChanges(
                fromRemoteContextSave: [NSUpdatedObjectIDsKey: updatedObjectIDs],
                into: [context]
            )
            context.processPendingChanges()
        }

        func currentStateMatches(
            recordName: String,
            acknowledgedAttempt: ICCloudLocalOutboxAcknowledgementAttempt
        ) -> Bool {
            if let objectID = objectIDsByRecordName[recordName],
               let entry = context.registeredObject(for: objectID) {
                guard !entry.isDeleted,
                      let currentRevision = entry.value(forKey: "revision") as? String,
                      let currentOperation = entry.value(forKey: "operation") as? String,
                      currentRevision == acknowledgedAttempt.revision,
                      currentOperation == acknowledgedAttempt.operation else {
                    return false
                }
            }
            if let cached = localOutboxSnapshotCache[recordName],
               (cached.revision != acknowledgedAttempt.revision
                || cached.operation != acknowledgedAttempt.operation) {
                return false
            }
            return true
        }

        var removablePendingRecordNames = Set<String>()
        var needsOutboxDrain = result.needsOutboxDrain
        for (recordName, acknowledgedAttempt) in result.acknowledgedAttemptsByRecordName {
            guard currentStateMatches(
                recordName: recordName,
                acknowledgedAttempt: acknowledgedAttempt
            ) else {
                needsOutboxDrain = true
                continue
            }
            removablePendingRecordNames.insert(recordName)
            if let cached = localOutboxSnapshotCache[recordName] {
                localOutboxSnapshotCache[recordName] = cached.replacingAcknowledged(true)
            }
        }
        for (recordName, acknowledgedAttempt) in result.fullyAcknowledgedAttemptsByRecordName {
            guard currentStateMatches(
                recordName: recordName,
                acknowledgedAttempt: acknowledgedAttempt
            ) else {
                needsOutboxDrain = true
                continue
            }
            removablePendingRecordNames.insert(recordName)
            localOutboxSnapshotCache.removeValue(forKey: recordName)
        }
        removePendingRecordChanges(recordNames: removablePendingRecordNames)
        if needsOutboxDrain {
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
                Self.markLocalOutboxEntryUnacknowledged(entry)
            } else if revisionsToAcknowledge[recordName] == currentRevision {
                guard let operation = entry.value(forKey: "operation") as? String else {
                    throw Self.localOutboxStoreError(
                        code: 2,
                        description: "Ein lokaler iCloud-Outbox-Eintrag hat keine gültige Operation."
                    )
                }
                Self.markLocalOutboxEntryAcknowledged(
                    entry,
                    revision: currentRevision,
                    operation: operation
                )
                completedRecordNames.insert(recordName)
                if entry.value(forKey: "category") as? String
                    != Self.localOutboxSubscriptionCategory {
                    localOutboxSnapshotCache.removeValue(forKey: recordName)
                }
            }
        }
        for recordName in requestedRecordNames {
            let pair = Self.subscriptionOutboxRecordNames(forCloudRecordName: recordName)
            let pairEntries = pair.compactMap { entriesByRecordName[$0] }
            guard pairEntries.count == 2,
                  Set(pairEntries.compactMap { $0.value(forKey: "revision") as? String }).count == 1,
                  pairEntries.allSatisfy({ Self.localOutboxEntryIsAcknowledged($0) }) else { continue }
            for pairEntry in pairEntries {
                if let pairRecordName = pairEntry.value(forKey: "recordName") as? String {
                    completedRecordNames.insert(pairRecordName)
                    localOutboxSnapshotCache.removeValue(forKey: pairRecordName)
                }
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

    func handleFailedRecordSave(
        _ failedSave: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
        preappliedEpisodeConflictRecordNames: Set<String>,
        resolvedEpisodeConflictOutboxRevisions: [String: String],
        retryRecords: inout [CKSyncEngine.PendingRecordZoneChange],
        retryZones: inout [CKSyncEngine.PendingDatabaseChange]
    ) async -> Bool {
        let generation = cloudAccountGeneration
        let recordID = failedSave.record.recordID
        switch failedSave.error.code {
        case .serverRecordChanged:
            if let serverRecord = failedSave.error.serverRecord {
                if serverRecord.recordType == RecordKind.episodeState {
                    guard preappliedEpisodeConflictRecordNames.contains(
                        serverRecord.recordID.recordName
                    ) else { return false }
                } else {
                    guard await applyRemoteRecord(serverRecord) else { return false }
                }
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return true }
                if serverRecord.recordType == RecordKind.device {
                    retryRecords.append(.saveRecord(recordID))
                    requiresImmediateFinalDeviceRecordResend = true
                    return true
                }
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
                if serverRecord.recordType == RecordKind.episodeState,
                   let sentRevision,
                   resolvedEpisodeConflictOutboxRevisions[recordID.recordName] == sentRevision {
                    recordInitialUploadRecordsSaved([recordID])
                    return true
                }
                if serverRecord.recordType == RecordKind.episodeState {
                    retryRecords.append(.saveRecord(recordID))
                    return true
                }
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

        if record.recordType == RecordKind.episodeState {
            do {
                guard let accountRecordName = defaults.string(
                    forKey: Self.accountUserRecordNameKey
                ) else {
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
                let staged = try await Self.stagePendingEpisodeStates(
                    accountRecordName: accountRecordName,
                    writes: [ICCloudPendingEpisodeStateWrite(
                        recordName: record.recordID.recordName,
                        payloadData: payloadData
                    )]
                )
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified,
                      defaults.string(forKey: Self.accountUserRecordNameKey)
                        == accountRecordName else { return false }
                if episodesSyncEnabled, !staged.isEmpty {
                    guard let episodeEpoch = syncEngineCallbackGate.beginEpisodeApply(
                        generation: generation,
                        accountRecordName: accountRecordName
                    ) else { return false }
                    let result = try await Self.applyPendingEpisodeStateBatchInBackground(
                        accountRecordName: accountRecordName,
                        snapshots: staged,
                        generation: generation,
                        episodeEpoch: episodeEpoch,
                        validityGate: syncEngineCallbackGate,
                        remoteOriginGate: remoteOriginGate,
                        remoteEpisodeClockGate: remoteEpisodeClockGate
                    )
                    try consumeEpisodeApplyBatchResult(result)
                }
                return true
            } catch is CancellationError {
                return false
            } catch {
                handleLocalPersistenceFailure(error)
                return false
            }
        }

        if record.recordType == RecordKind.subscription
            || record.recordType == RecordKind.subscriptionTombstone
            || record.recordType == RecordKind.subscriptionListSettings {
            do {
                guard let accountRecordName = defaults.string(
                    forKey: Self.accountUserRecordNameKey
                ) else {
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
                return generation == cloudAccountGeneration
                    && isICloudAccountIdentityVerified
                    && defaults.string(forKey: Self.accountUserRecordNameKey)
                        == accountRecordName
            } catch {
                handleLocalPersistenceFailure(error)
                return false
            }
        }

        return performSynchronousRemoteApplyBatch {
            applyRemoteNonEpisodeRecord(record)
        }
    }

    @discardableResult
    func queueSubscriptionListSettingsRepair(modifiedAt: Date) -> Bool {
        guard let intent = persistPendingSingletonUploadIntent(
            for: subscriptionListSettingsRecordID(),
            modifiedAt: modifiedAt
        ) else { return false }
        if let context = databaseManager.objectContext {
            setSyncMetadata(
                subscriptionListSettingsFingerprint(in: context),
                forKey: Self.subscriptionListSettingsBaselineKey
            )
        }
        setSyncMetadata(
            intent.modifiedAt,
            forKey: Self.subscriptionListSettingsLocalModifiedDateKey
        )
        addPendingSave(subscriptionListSettingsRecordID())
        return true
    }

    @discardableResult
    func applyRemoteSubscriptionListSettings(_ payload: [String: Any]) -> Bool {
        let hasRemoteMainMenuListUIDs = payload.keys.contains("mainMenuListUIDs")
        let remoteMainMenuListUIDs = hasRemoteMainMenuListUIDs
            ? ((payload["mainMenuListUIDs"] as? [String]) ?? [])
            : nil
        let remoteMainMenuSchemaVersion = payload["mainMenuListUIDsSchemaVersion"] as? Int ?? 0
        let hasStoredMainMenuListUIDs = defaults.object(forKey: "MainMenuListUIDs") != nil
        let currentMainMenuListUIDs = hasStoredMainMenuListUIDs
            ? ((defaults.array(forKey: "MainMenuListUIDs") as? [String]) ?? [])
            : Self.defaultMainMenuListUIDs()
        let isAmbiguousLegacyEmptyMainMenu = remoteMainMenuListUIDs?.isEmpty == true
            && remoteMainMenuSchemaVersion < Self.mainMenuListUIDsSchemaVersion
        let shouldRepairAmbiguousLegacyMainMenu = isAmbiguousLegacyEmptyMainMenu
            && (!hasStoredMainMenuListUIDs || !currentMainMenuListUIDs.isEmpty)

        let discardedTransactionalListMutation: Bool
        switch remoteOutboxDecision(
            payload: payload,
            recordName: RecordPrefix.subscriptionListSettings
        ) {
        case .keepLocal:
            return true
        case .applyRemote(let discarded):
            discardedTransactionalListMutation = discarded
        }
        let remoteSortMode = (payload["sortMode"] as? String) ?? ""
        let remoteManualOrder = (payload["manualOrder"] as? [String]) ?? []
        let remoteEpisodeLists = (payload["episodeLists"] as? [[String: Any]]) ?? []
        let hasRemoteEpisodeLists = !remoteEpisodeLists.isEmpty
        // An EMPTY record (published by a pre-fix build on a freshly installed device)
        // must not win last-writer-wins against a real local state: ignore it entirely —
        // applying it would re-stamp localModifiedDate/baseline and silence this device
        // forever — and push the real local state back up instead.
        guard !remoteSortMode.isEmpty || !remoteManualOrder.isEmpty || hasRemoteEpisodeLists || hasRemoteMainMenuListUIDs else {
            if Self.hasLocalSubscriptionListSettings() {
                return queueSubscriptionListSettingsRepair(
                    modifiedAt: (defaults.object(
                        forKey: Self.subscriptionListSettingsLocalModifiedDateKey
                    ) as? Date) ?? Date()
                )
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
                return queueSubscriptionListSettingsRepair(
                    modifiedAt: (defaults.object(
                        forKey: Self.subscriptionListSettingsLocalModifiedDateKey
                    ) as? Date) ?? Date()
                )
            }
            shouldApplySortSettings = false
            shouldRepairSortSettings = true
        }
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if !discardedTransactionalListMutation,
           let localDate = defaults.object(forKey: Self.subscriptionListSettingsLocalModifiedDateKey) as? Date,
           localDate.compare(remoteDate) == .orderedDescending {
            // Only defend the local state if one actually exists — a pre-fix build may
            // have stamped localModifiedDate on a device that has nothing to defend.
            if Self.hasLocalSubscriptionListSettings() {
                return queueSubscriptionListSettingsRepair(modifiedAt: localDate)
            }
        }
        guard discardPendingSingletonUploadIntent(
            recordName: RecordPrefix.subscriptionListSettings
        ) else { return false }
        if shouldApplySortSettings, !remoteSortMode.isEmpty {
            defaults.set(remoteSortMode, forKey: FeedListSortMode)
        }
        if shouldApplySortSettings, !remoteManualOrder.isEmpty {
            defaults.set(remoteManualOrder, forKey: Self.manualFeedOrderDefaultsKey)
        }
        let resolvedEpisodeListFeeds = hasRemoteEpisodeLists ? applyRemoteEpisodeLists(remoteEpisodeLists) : true
        if let remoteMainMenuListUIDs, !shouldRepairAmbiguousLegacyMainMenu {
            _ = applyRemoteMainMenuListUIDs(remoteMainMenuListUIDs)
        }
        guard resolvedEpisodeListFeeds else {
            return false
        }
        let requiresMergedSettingsRepair = shouldRepairSortSettings || shouldRepairAmbiguousLegacyMainMenu
        setSyncMetadata(requiresMergedSettingsRepair ? Date() : remoteDate, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
        // Re-baseline so applying the payload doesn't read as a local change and echo back.
        setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
        // The actual reordering happens once at the end of the apply batch, after all
        // subscription records (and their stub feeds) of this fetch exist.
        if shouldApplySortSettings {
            needsSubscriptionListSortApply = true
        }
        if shouldRepairSortSettings || shouldRepairAmbiguousLegacyMainMenu {
            return queueSubscriptionListSettingsRepair(modifiedAt: Date())
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
        let hasStoredUIDs = defaults.object(forKey: "MainMenuListUIDs") != nil
        let currentUIDs = defaults.array(forKey: "MainMenuListUIDs") as? [String] ?? []
        guard !hasStoredUIDs || currentUIDs != mainMenuListUIDs else { return false }
        defaults.set(mainMenuListUIDs, forKey: "MainMenuListUIDs")
        NotificationCenter.default.post(name: NSNotification.Name("MainMenuListUIDsDidChangeNotification"), object: nil)
        return true
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

    func applyPendingEpisodeStates() async {
        guard episodesSyncEnabled, !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
            return
        }
        let generation = cloudAccountGeneration
        let initialCount: Int
        do {
            initialCount = try await Self.pendingEpisodeStateCount(
                accountRecordName: accountRecordName
            )
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
            guard generation == cloudAccountGeneration,
                  episodesSyncEnabled,
                  isICloudAccountIdentityVerified,
                  !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  !Task.isCancelled else { return }

            do {
                guard let episodeEpoch = syncEngineCallbackGate.beginEpisodeApply(
                    generation: generation,
                    accountRecordName: accountRecordName
                ) else { return }
                let result = try await Self.applyPendingEpisodeStateBatchInBackground(
                    accountRecordName: accountRecordName,
                    snapshots: snapshots,
                    generation: generation,
                    episodeEpoch: episodeEpoch,
                    validityGate: syncEngineCallbackGate,
                    remoteOriginGate: remoteOriginGate,
                    remoteEpisodeClockGate: remoteEpisodeClockGate
                )
                try consumeEpisodeApplyBatchResult(result)
            } catch is CancellationError {
                return
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }

            cursor = snapshots.last?.recordName
            await Task.yield()
            guard generation == cloudAccountGeneration,
                  episodesSyncEnabled,
                  isICloudAccountIdentityVerified,
                  !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
                return
            }
        }

        let remainingCount: Int
        do {
            remainingCount = try await Self.pendingEpisodeStateCount(
                accountRecordName: accountRecordName
            )
        } catch {
            handleLocalPersistenceFailure(error)
            return
        }
        logSyncEvent("Wartende Episoden-Status verarbeitet", metadata: [
            "applied": initialCount - remainingCount,
            "remaining": remainingCount,
        ])
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

    nonisolated static func resolvedPendingSubscriptionChanges(
        _ snapshots: [ICCloudPendingSubscriptionStateSnapshot]
    ) throws -> [PendingSubscriptionChange] {
        var candidatesByFeedURL: [String: [PendingSubscriptionChange]] = [:]
        for snapshot in snapshots where snapshot.recordName != RecordPrefix.subscriptionListSettings {
            let recordName = snapshot.recordName
            let payload = try snapshot.payloadDictionary()
            let feedURL = (payload["feedURL"] as? String) ?? ""
            let isLegacyDeletion = (payload["legacyPhysicalDelete"] as? Bool) == true
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

        // Equivalent old/new feed URLs can resolve to the same local feed after a redirect.
        // Apply by logical clock; at an equal clock the old-URL tombstone must run first so
        // the new active URL is the final state. Exact same-URL pairs were reduced above.
        return winners.sorted { lhs, rhs in
            let lhsDate = lhs.payload["updatedAt"] as? Date ?? .distantPast
            let rhsDate = rhs.payload["updatedAt"] as? Date ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            if lhs.isTombstone != rhs.isTombstone {
                return lhs.isTombstone
            }
            return lhs.feedURL < rhs.feedURL
        }
    }

    nonisolated static func subscriptionFeedIdentityCandidates(_ feedURL: String) -> [String] {
        let raw = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        var result: [String] = []
        func append(_ candidate: String?) {
            guard let candidate, !candidate.isEmpty, !result.contains(candidate) else { return }
            result.append(candidate)
            guard var components = URLComponents(string: candidate) else { return }
            if components.percentEncodedPath.hasSuffix("/") {
                components.percentEncodedPath = String(components.percentEncodedPath.dropLast())
            } else {
                components.percentEncodedPath += "/"
            }
            if let pathVariant = components.string,
               !pathVariant.isEmpty,
               !result.contains(pathVariant) {
                result.append(pathVariant)
            }
        }
        for candidate in DatabaseManager.equivalentFeedURLStrings(forURLString: raw) {
            append(candidate)
        }
        append(raw)
        return result
    }

    nonisolated static func subscriptionStorageURL(_ feedURL: String) -> URL? {
        var normalized = feedURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix("/"), normalized.count > 1 {
            normalized.removeLast()
        }
        return URL(string: normalized)
    }

    nonisolated static func subscriptionOutboxSnapshot(
        from entry: NSManagedObject
    ) throws -> ICCloudSyncOutboxSnapshot {
        guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
              let recordName = entry.value(forKey: "recordName") as? String,
              let category = entry.value(forKey: "category") as? String,
              let operation = entry.value(forKey: "operation") as? String,
              let revision = entry.value(forKey: "revision") as? String,
              let changedAt = entry.value(forKey: "changedAt") as? Date,
              let payloadData = entry.value(forKey: "payloadData") as? Data else {
            throw localOutboxStoreError(
                code: 2,
                description: "Ein lokaler iCloud-Abo-Outbox-Eintrag ist beschädigt."
            )
        }
        return ICCloudSyncOutboxSnapshot(
            accountRecordName: accountRecordName,
            recordName: recordName,
            category: category,
            operation: operation,
            acknowledged: localOutboxEntryIsAcknowledged(entry),
            revision: revision,
            changedAt: changedAt,
            payloadData: payloadData
        )
    }

    nonisolated static func applySubscriptionPayloadInBackground(
        _ payload: [String: Any],
        to feed: CDFeed,
        changedRemoteObjectIDs: inout Set<NSManagedObjectID>,
        credentialPasswordsByFeed: inout [CDFeed: (expectedPassword: String?, password: String)]
    ) {
        var didMutateFeed = feed.isInserted
        if let title = payload["title"] as? String, !title.isEmpty, feed.title == nil {
            feed.title = title
            didMutateFeed = true
        }
        if let rank = (payload["rank"] as? NSNumber)?.int32Value, feed.rank != rank {
            feed.rank = rank
            didMutateFeed = true
        }
        if let parked = payload["parked"] as? Bool, feed.parked != parked {
            feed.parked = parked
            didMutateFeed = true
        }
        if let username = payload["username"] as? String,
           !username.isEmpty, feed.username != username {
            feed.username = username
            didMutateFeed = true
        }
        let expectedPassword = feed.password
        if let password = payload["password"] as? String,
           !password.isEmpty,
           let username = feed.username,
           !username.isEmpty,
           expectedPassword != password {
            credentialPasswordsByFeed[feed] = (expectedPassword, password)
        }

        if let properties = payload["properties"] as? [[String: Any]] {
            for property in properties {
                guard let rawKey = property["key"] as? String, !rawKey.isEmpty else { continue }
                let key = localFeedPropertyKey(rawKey, feedUID: feed.uid)
                guard let cdProperty = feed.property(forKey: key, insertOnDemand: true) else { continue }
                var didMutateProperty = cdProperty.isInserted
                let boolValue = (property["boolValue"] as? NSNumber)?.boolValue ?? false
                let int32Value = (property["int32Value"] as? NSNumber)?.int32Value ?? 0
                let doubleValue = (property["doubleValue"] as? NSNumber)?.doubleValue ?? 0
                let stringValue = property["stringValue"] as? String
                if cdProperty.boolValue != boolValue {
                    cdProperty.boolValue = boolValue
                    didMutateProperty = true
                }
                if cdProperty.int32Value != int32Value {
                    cdProperty.int32Value = int32Value
                    didMutateProperty = true
                }
                if cdProperty.doubleValue != doubleValue {
                    cdProperty.doubleValue = doubleValue
                    didMutateProperty = true
                }
                if cdProperty.stringValue != stringValue {
                    cdProperty.stringValue = stringValue
                    didMutateProperty = true
                }
                if didMutateProperty {
                    changedRemoteObjectIDs.insert(cdProperty.objectID)
                    didMutateFeed = true
                }
            }
        }
        if didMutateFeed {
            changedRemoteObjectIDs.insert(feed.objectID)
        }
    }

    nonisolated static func applyPendingSubscriptionBatchInBackground(
        accountRecordName: String,
        snapshots: [ICCloudPendingSubscriptionStateSnapshot],
        generation: Int,
        subscriptionEpoch: UInt64,
        suppressDeletions: Bool,
        deviceID: String,
        validityGate: ICiCloudSyncEngineCallbackGate,
        remoteOriginGate: ICiCloudRemoteEpisodeOriginGate
    ) async throws -> ICCloudSubscriptionApplyBatchResult {
        guard snapshots.count <= remoteApplyBatchSize * 2 else {
            throw pendingSubscriptionStateStoreError(
                code: 2,
                description: "Ein iCloud-Abo-Batch überschreitet die sichere Transaktionsgröße."
            )
        }
        guard !snapshots.isEmpty else {
            return ICCloudSubscriptionApplyBatchResult(
                appliedSnapshots: [],
                needsOutboxDrain: false,
                finalOutboxSnapshots: [:],
                removedOutboxRevisions: [:],
                completedOutboxRecordNames: [],
                insertedObjectURIStrings: [],
                updatedObjectURIStrings: [],
                deletedObjectURIStrings: [],
                remoteObjectURIStrings: [],
                credentialUpdates: [],
                credentialPendingSnapshots: [],
                hasPendingSubscriptionCleanup: false,
                originRegistration: nil,
                commitLease: nil
            )
        }

        for attempt in 0...1 {
            guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
                throw pendingSubscriptionStateStoreError(
                    code: 1,
                    description: "Der lokale iCloud-Abonnementspeicher konnte nicht geöffnet werden."
                )
            }
            context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
            context.undoManager = nil
            do {
                return try await context.perform {
                    var originRegistration: UUID?
                    var commitLease: ICiCloudRemoteApplyCommitLease?
                    var cleanupProtectionRevisionsByFeedObjectURIString: [String: String] = [:]
                    var stagedCleanupProtectionsByFeedObjectURIString: [
                        String: ICCloudSubscriptionCleanupProtectionStage
                    ] = [:]
                    do {
                        let expectedPayloadByRecordName = Dictionary(
                            uniqueKeysWithValues: snapshots.map { ($0.recordName, $0.payloadData) }
                        )
                        let pendingRequest = NSFetchRequest<NSManagedObject>(
                            entityName: pendingSubscriptionStateEntityName
                        )
                        pendingRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                            NSPredicate(format: "accountRecordName == %@", accountRecordName),
                            NSPredicate(
                                format: "recordName IN %@",
                                Array(expectedPayloadByRecordName.keys)
                            ),
                        ])
                        pendingRequest.fetchBatchSize = remoteApplyBatchSize
                        var pendingByRecordName: [String: NSManagedObject] = [:]
                        for pending in try context.fetch(pendingRequest) {
                            guard let recordName = pending.value(forKey: "recordName") as? String,
                                  let payloadData = pending.value(forKey: "payloadData") as? Data,
                                  expectedPayloadByRecordName[recordName] == payloadData else { continue }
                            pendingByRecordName[recordName] = pending
                        }
                        let currentSnapshots = snapshots.filter {
                            pendingByRecordName[$0.recordName] != nil
                        }
                        let changes = try resolvedPendingSubscriptionChanges(currentSnapshots)
                        guard !changes.isEmpty else {
                            return ICCloudSubscriptionApplyBatchResult(
                                appliedSnapshots: [],
                                needsOutboxDrain: false,
                                finalOutboxSnapshots: [:],
                                removedOutboxRevisions: [:],
                                completedOutboxRecordNames: [],
                                insertedObjectURIStrings: [],
                                updatedObjectURIStrings: [],
                                deletedObjectURIStrings: [],
                                remoteObjectURIStrings: [],
                                credentialUpdates: [],
                                credentialPendingSnapshots: [],
                                hasPendingSubscriptionCleanup: false,
                                originRegistration: nil,
                                commitLease: nil
                            )
                        }

                        var allOutboxRecordNames = changes.reduce(into: Set<String>()) { result, change in
                            result.formUnion(subscriptionOutboxRecordNames(
                                forCloudRecordName: change.recordName
                            ))
                        }
                        var metadataRecordNames = changes.reduce(into: Set<String>()) { result, change in
                            result.formUnion(change.snapshots.map(\.recordName))
                            guard !change.feedURL.isEmpty else { return }
                            for candidateFeedURL in subscriptionFeedIdentityCandidates(
                                change.feedURL
                            ) {
                                result.insert(subscriptionRecordName(forFeedURL: candidateFeedURL))
                                result.insert(subscriptionTombstoneRecordName(
                                    forFeedURL: candidateFeedURL
                                ))
                            }
                        }
                        var metadataBatch = try prepareSyncItemMetadataContextBatch(
                            accountRecordName: accountRecordName,
                            recordNames: metadataRecordNames,
                            context: context
                        )

                        let outboxRequest = NSFetchRequest<NSManagedObject>(
                            entityName: localOutboxEntityName
                        )
                        outboxRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                            NSPredicate(format: "accountRecordName == %@", accountRecordName),
                            NSPredicate(format: "recordName IN %@", Array(allOutboxRecordNames)),
                        ])
                        outboxRequest.fetchBatchSize = remoteApplyBatchSize
                        var outboxByRecordName: [String: NSManagedObject] = [:]
                        for entry in try context.fetch(outboxRequest) {
                            guard let recordName = entry.value(forKey: "recordName") as? String,
                                  outboxByRecordName[recordName] == nil else {
                                throw localOutboxStoreError(
                                    code: 2,
                                    description: "Ein lokaler iCloud-Abo-Outbox-Eintrag ist mehrfach vorhanden."
                                )
                            }
                            outboxByRecordName[recordName] = entry
                        }

                        var identityCandidatesByFeedURL: [String: [String]] = [:]
                        var storedURLCandidates = Set<String>()
                        for change in changes where !change.feedURL.isEmpty {
                            let candidates = subscriptionFeedIdentityCandidates(change.feedURL)
                            identityCandidatesByFeedURL[change.feedURL] = candidates
                            storedURLCandidates.formUnion(candidates)
                        }
                        let feedRequest = NSFetchRequest<CDFeed>(entityName: "Feed")
                        feedRequest.predicate = NSPredicate(
                            format: "sourceURL_ IN[c] %@",
                            Array(storedURLCandidates)
                        )
                        feedRequest.includesSubentities = false
                        feedRequest.relationshipKeyPathsForPrefetching = ["properties"]
                        feedRequest.sortDescriptors = [
                            NSSortDescriptor(key: "rank", ascending: true),
                            NSSortDescriptor(key: "uid", ascending: true),
                        ]
                        let fetchedFeeds = try context.fetch(feedRequest)
                        var exactFeedsByStoredURL: [String: [CDFeed]] = [:]
                        var aliasFeedsByIdentity: [String: [CDFeed]] = [:]
                        for feed in fetchedFeeds {
                            guard let storedURL = feed.value(forKey: "sourceURL_") as? String else { continue }
                            let identities = subscriptionFeedIdentityCandidates(storedURL)
                            if let exactIdentity = identities.first {
                                exactFeedsByStoredURL[exactIdentity, default: []].append(feed)
                            }
                            for identity in identities {
                                aliasFeedsByIdentity[identity, default: []].append(feed)
                            }
                        }
                        var resolvedFeedByFeedURL: [String: CDFeed] = [:]
                        for (feedURL, candidates) in identityCandidatesByFeedURL {
                            if let exactIdentity = candidates.first,
                               let exactFeed = exactFeedsByStoredURL[exactIdentity]?.first {
                                resolvedFeedByFeedURL[feedURL] = exactFeed
                                continue
                            }
                            for alias in candidates.dropFirst() {
                                if let feed = aliasFeedsByIdentity[alias]?.first {
                                    resolvedFeedByFeedURL[feedURL] = feed
                                    break
                                }
                            }
                        }

                        var actualStoredFeedURLByFeedURL: [String: String] = [:]
                        for (feedURL, feed) in resolvedFeedByFeedURL {
                            guard let storedFeedURL = feed.value(forKey: "sourceURL_") as? String,
                                  !storedFeedURL.isEmpty else { continue }
                            actualStoredFeedURLByFeedURL[feedURL] = storedFeedURL
                        }
                        func conflictFeedURLCandidates(_ feedURL: String) -> [String] {
                            var candidates = subscriptionFeedIdentityCandidates(feedURL)
                            if let storedFeedURL = actualStoredFeedURLByFeedURL[feedURL],
                               !candidates.contains(storedFeedURL) {
                                candidates.append(storedFeedURL)
                            }
                            return candidates
                        }

                        var additionalMetadataRecordNames = Set<String>()
                        var additionalOutboxRecordNames = Set<String>()
                        for feedURL in changes.map(\.feedURL) where !feedURL.isEmpty {
                            guard let storedFeedURL = actualStoredFeedURLByFeedURL[feedURL],
                                  !subscriptionFeedIdentityCandidates(feedURL).contains(storedFeedURL)
                            else { continue }
                            additionalMetadataRecordNames.insert(subscriptionRecordName(
                                forFeedURL: storedFeedURL
                            ))
                            additionalMetadataRecordNames.insert(subscriptionTombstoneRecordName(
                                forFeedURL: storedFeedURL
                            ))
                            additionalOutboxRecordNames.formUnion(subscriptionOutboxRecordNames(
                                forCloudRecordName: subscriptionRecordName(
                                    forFeedURL: storedFeedURL
                                )
                            ))
                        }
                        additionalMetadataRecordNames.subtract(metadataRecordNames)
                        if !additionalMetadataRecordNames.isEmpty {
                            metadataRecordNames.formUnion(additionalMetadataRecordNames)
                            metadataBatch = try prepareSyncItemMetadataContextBatch(
                                accountRecordName: accountRecordName,
                                recordNames: metadataRecordNames,
                                context: context
                            )
                        }
                        additionalOutboxRecordNames.subtract(allOutboxRecordNames)
                        if !additionalOutboxRecordNames.isEmpty {
                            allOutboxRecordNames.formUnion(additionalOutboxRecordNames)
                            outboxRequest.predicate = NSCompoundPredicate(
                                andPredicateWithSubpredicates: [
                                    NSPredicate(
                                        format: "accountRecordName == %@",
                                        accountRecordName
                                    ),
                                    NSPredicate(
                                        format: "recordName IN %@",
                                        Array(additionalOutboxRecordNames)
                                    ),
                                ]
                            )
                            for entry in try context.fetch(outboxRequest) {
                                guard let recordName = entry.value(forKey: "recordName") as? String,
                                      outboxByRecordName[recordName] == nil else {
                                    throw localOutboxStoreError(
                                        code: 2,
                                        description: "Ein lokaler iCloud-Abo-Outbox-Eintrag ist mehrfach vorhanden."
                                    )
                                }
                                outboxByRecordName[recordName] = entry
                            }
                        }

                        var appliedSnapshots: [ICCloudPendingSubscriptionStateSnapshot] = []
                        var changedRemoteObjectIDs = Set<NSManagedObjectID>()
                        var cleanupAffectedFeeds = Set<CDFeed>()
                        var feedsRequiringCleanup = Set<CDFeed>()
                        var cleanupPendingSnapshotsByFeed: [
                            CDFeed: [String: ICCloudPendingSubscriptionStateSnapshot]
                        ] = [:]
                        var heldCleanupSnapshotRecordNames = Set<String>()
                        var credentialPasswordsByFeed: [
                            CDFeed: (expectedPassword: String?, password: String)
                        ] = [:]
                        var credentialPendingSnapshots: [
                            ICCloudPendingSubscriptionStateSnapshot
                        ] = []
                        var needsOutboxDrain = false
                        var removedOutboxRevisions: [String: String] = [:]
                        var completedOutboxRecordNames = Set<String>()

                        func ensureMetadataMapping(feedURL: String, recordName: String) throws {
                            let activeRecordName = subscriptionRecordName(forFeedURL: feedURL)
                            let tombstoneRecordName = subscriptionTombstoneRecordName(forFeedURL: feedURL)
                            guard recordName == activeRecordName || recordName == tombstoneRecordName else {
                                throw syncItemMetadataStoreError(
                                    code: 3,
                                    description: "Ein empfangenes iCloud-Abo hat eine widersprüchliche Identität."
                                )
                            }
                            try upsertSyncItemMetadata(
                                [ICCloudSyncItemMetadataWrite(
                                    category: localOutboxSubscriptionCategory,
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

                        func metadata(for feedURL: String) throws -> ICCloudSyncItemMetadataSnapshot? {
                            let candidateMetadataSnapshots = try conflictFeedURLCandidates(
                                feedURL
                            ).compactMap { candidateFeedURL in
                                try syncItemMetadataSnapshot(
                                    forRecordName: subscriptionRecordName(
                                        forFeedURL: candidateFeedURL
                                    ),
                                    metadataBatch: metadataBatch
                                )
                            }
                            return candidateMetadataSnapshots.max { lhs, rhs in
                                let lhsDate = lhs.localModifiedAt ?? .distantPast
                                let rhsDate = rhs.localModifiedAt ?? .distantPast
                                if lhsDate != rhsDate { return lhsDate < rhsDate }
                                return lhs.recordName < rhs.recordName
                            }
                        }

                        func updateMetadata(
                            feedURL: String,
                            localModifiedAt: Date?,
                            localState: Bool?,
                            payloadHash: String?,
                            updating fields: ICCloudSyncItemMetadataUpdateFields = .all
                        ) throws {
                            try upsertSyncItemMetadata(
                                [ICCloudSyncItemMetadataWrite(
                                    category: localOutboxSubscriptionCategory,
                                    recordName: subscriptionRecordName(forFeedURL: feedURL),
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

                        func outboxSnapshots(
                            for recordName: String,
                            feedURL: String
                        ) throws -> [ICCloudSyncOutboxSnapshot] {
                            var candidateRecordNames = subscriptionOutboxRecordNames(
                                forCloudRecordName: recordName
                            )
                            for candidateFeedURL in conflictFeedURLCandidates(feedURL) {
                                candidateRecordNames.formUnion(subscriptionOutboxRecordNames(
                                    forCloudRecordName: subscriptionRecordName(
                                        forFeedURL: candidateFeedURL
                                    )
                                ))
                            }
                            return try candidateRecordNames.compactMap {
                                guard let entry = outboxByRecordName[$0] else { return nil }
                                return try subscriptionOutboxSnapshot(from: entry)
                            }
                        }

                        func completeAcknowledgedPair(containing recordName: String) throws {
                            let pair = subscriptionOutboxRecordNames(forCloudRecordName: recordName)
                            let entries = pair.compactMap { outboxByRecordName[$0] }
                            guard entries.count == 2,
                                  Set(entries.compactMap {
                                      $0.value(forKey: "revision") as? String
                                  }).count == 1,
                                  entries.allSatisfy({
                                      localOutboxEntryIsAcknowledged($0)
                                  }) else { return }
                            for entry in entries {
                                guard let pairRecordName = entry.value(forKey: "recordName") as? String,
                                      let revision = entry.value(forKey: "revision") as? String else {
                                    throw localOutboxStoreError(
                                        code: 2,
                                        description: "Ein lokaler iCloud-Abo-Outbox-Eintrag hat keine gültige Revision."
                                    )
                                }
                                removedOutboxRevisions[pairRecordName] = revision
                                completedOutboxRecordNames.insert(pairRecordName)
                                outboxByRecordName.removeValue(forKey: pairRecordName)
                            }
                        }

                        func observePhysicalDeletionAgainstOutbox(
                            recordName: String,
                            feedURL: String
                        ) throws -> Bool {
                            let entries = try outboxSnapshots(
                                for: recordName,
                                feedURL: feedURL
                            )
                            guard !entries.isEmpty else { return false }
                            guard let exactEntry = outboxByRecordName[recordName],
                                  let operation = exactEntry.value(forKey: "operation") as? String else {
                                needsOutboxDrain = true
                                return true
                            }
                            if operation == localOutboxDeleteOperation {
                                guard let revision = exactEntry.value(forKey: "revision") as? String else {
                                    throw localOutboxStoreError(
                                        code: 2,
                                        description: "Ein lokaler iCloud-Abo-Outbox-Eintrag hat keine gültige Revision."
                                    )
                                }
                                markLocalOutboxEntryAcknowledged(
                                    exactEntry,
                                    revision: revision,
                                    operation: operation
                                )
                                try completeAcknowledgedPair(containing: recordName)
                            } else {
                                Self.markLocalOutboxEntryUnacknowledged(exactEntry)
                                needsOutboxDrain = true
                            }
                            return true
                        }

                        func remoteDecision(
                            payload: [String: Any],
                            recordName: String,
                            feedURL: String
                        ) throws -> RemoteOutboxDecision {
                            let entries = try outboxSnapshots(
                                for: recordName,
                                feedURL: feedURL
                            )
                            guard let entry = entries.max(by: { first, second in
                                if first.changedAt != second.changedAt {
                                    return first.changedAt < second.changedAt
                                }
                                return first.operation == localOutboxDeleteOperation
                                    && second.operation == localOutboxSaveOperation
                            }) else {
                                return .applyRemote(discardedLocalMutation: false)
                            }
                            let remoteDate = payload["updatedAt"] as? Date
                                ?? Date(timeIntervalSince1970: 0)
                            let remoteRevision = payload[localMutationRevisionPayloadKey] as? String
                            if remoteRevision == entry.revision {
                                if let exactEntry = outboxByRecordName[recordName],
                                   exactEntry.value(forKey: "revision") as? String == entry.revision,
                                   exactEntry.value(forKey: "operation") as? String
                                        == localOutboxSaveOperation {
                                    markLocalOutboxEntryAcknowledged(
                                        exactEntry,
                                        revision: entry.revision,
                                        operation: localOutboxSaveOperation
                                    )
                                    try completeAcknowledgedPair(containing: recordName)
                                }
                                return .applyRemote(discardedLocalMutation: false)
                            }
                            if remoteDate > entry.changedAt {
                                for candidate in entries where candidate.revision == entry.revision {
                                    guard let storedEntry = outboxByRecordName[candidate.recordName] else { continue }
                                    removedOutboxRevisions[candidate.recordName] = candidate.revision
                                    completedOutboxRecordNames.insert(candidate.recordName)
                                    outboxByRecordName.removeValue(forKey: candidate.recordName)
                                    context.delete(storedEntry)
                                }
                                return .applyRemote(discardedLocalMutation: true)
                            }
                            if let exactEntry = outboxByRecordName[recordName],
                               exactEntry.value(forKey: "revision") as? String == entry.revision,
                               localOutboxEntryIsAcknowledged(exactEntry) {
                                Self.markLocalOutboxEntryUnacknowledged(exactEntry)
                            }
                            needsOutboxDrain = true
                            return .keepLocal
                        }

                        func hasCompleteOutboxPair(
                            for recordName: String,
                            feedURL: String
                        ) -> Bool {
                            var candidateRecordNames = subscriptionOutboxRecordNames(
                                forCloudRecordName: recordName
                            )
                            for candidateFeedURL in conflictFeedURLCandidates(feedURL) {
                                candidateRecordNames.formUnion(subscriptionOutboxRecordNames(
                                    forCloudRecordName: subscriptionRecordName(
                                        forFeedURL: candidateFeedURL
                                    )
                                ))
                            }
                            return candidateRecordNames.contains { candidateRecordName in
                                let pair = subscriptionOutboxRecordNames(
                                    forCloudRecordName: candidateRecordName
                                )
                                let entries = pair.compactMap { outboxByRecordName[$0] }
                                return entries.count == 2
                                    && Set(entries.compactMap {
                                        $0.value(forKey: "revision") as? String
                                    }).count == 1
                            }
                        }

                        func restoreOutboxIntent(
                            feedURL: String,
                            intentFeedURL: String? = nil,
                            subscribed: Bool,
                            changedAt proposedDate: Date
                        ) throws -> Bool {
                            let persistedFeedURL = intentFeedURL ?? feedURL
                            let payload: [String: Any]
                            let payloadHash: String?
                            if subscribed {
                                guard let feed = resolvedFeedByFeedURL[feedURL], feed.subscribed else {
                                    return false
                                }
                                payload = subscriptionPayload(
                                    for: feed,
                                    feedURL: persistedFeedURL,
                                    deviceID: deviceID
                                )
                                payloadHash = subscriptionPayloadHash(for: feed)
                            } else {
                                payload = [
                                    "feedURL": persistedFeedURL,
                                    "deleted": true,
                                    "deviceID": deviceID,
                                ]
                                payloadHash = nil
                            }
                            let activeRecordName = subscriptionRecordName(
                                forFeedURL: persistedFeedURL
                            )
                            let tombstoneRecordName = subscriptionTombstoneRecordName(
                                forFeedURL: persistedFeedURL
                            )
                            let pairRecordNames = [activeRecordName, tombstoneRecordName]
                            let existingDates = try pairRecordNames.compactMap { recordName -> Date? in
                                guard let entry = outboxByRecordName[recordName] else { return nil }
                                guard let changedAt = entry.value(forKey: "changedAt") as? Date else {
                                    throw localOutboxStoreError(
                                        code: 2,
                                        description: "Ein lokaler iCloud-Abo-Outbox-Eintrag hat keinen Zeitstempel."
                                    )
                                }
                                return changedAt
                            }
                            let metadataDate = try metadata(for: feedURL)?.localModifiedAt
                            let changedAt = nextCloudKitSafeDate(
                                proposed: proposedDate,
                                after: (existingDates + [metadataDate].compactMap { $0 }).max()
                            )
                            let payloadData = try PropertyListSerialization.data(
                                fromPropertyList: payload,
                                format: .binary,
                                options: 0
                            )
                            let revision = UUID().uuidString
                            let operationByRecordName = subscribed
                                ? [
                                    activeRecordName: localOutboxSaveOperation,
                                    tombstoneRecordName: localOutboxDeleteOperation,
                                ]
                                : [
                                    activeRecordName: localOutboxDeleteOperation,
                                    tombstoneRecordName: localOutboxSaveOperation,
                                ]
                            for recordName in pairRecordNames {
                                let entry = outboxByRecordName[recordName]
                                    ?? NSEntityDescription.insertNewObject(
                                        forEntityName: localOutboxEntityName,
                                        into: context
                                    )
                                entry.setValue(accountRecordName, forKey: "accountRecordName")
                                entry.setValue(recordName, forKey: "recordName")
                                entry.setValue(localOutboxSubscriptionCategory, forKey: "category")
                                entry.setValue(operationByRecordName[recordName], forKey: "operation")
                                Self.markLocalOutboxEntryUnacknowledged(entry)
                                entry.setValue(revision, forKey: "revision")
                                entry.setValue(changedAt, forKey: "changedAt")
                                entry.setValue(payloadData, forKey: "payloadData")
                                outboxByRecordName[recordName] = entry
                            }
                            try updateMetadata(
                                feedURL: persistedFeedURL,
                                localModifiedAt: changedAt,
                                localState: subscribed,
                                payloadHash: payloadHash
                            )
                            try upsertSyncItemMetadata(
                                [ICCloudSyncItemMetadataWrite(
                                    category: localOutboxSubscriptionCategory,
                                    recordName: tombstoneRecordName,
                                    itemIdentifier: persistedFeedURL,
                                    localModifiedAt: nil,
                                    localState: nil,
                                    payloadHash: nil
                                )],
                                updating: [],
                                metadataBatch: &metadataBatch,
                                context: context
                            )
                            needsOutboxDrain = true
                            return true
                        }

                        func unsubscribe(
                            _ feed: CDFeed,
                            pendingSnapshots: [ICCloudPendingSubscriptionStateSnapshot]
                        ) {
                            cleanupAffectedFeeds.insert(feed)
                            feedsRequiringCleanup.insert(feed)
                            var snapshotsByIdentity = cleanupPendingSnapshotsByFeed[feed] ?? [:]
                            for snapshot in pendingSnapshots {
                                let identity = snapshot.accountRecordName
                                    + "\u{1}" + snapshot.recordName
                                snapshotsByIdentity[identity] = snapshot
                                heldCleanupSnapshotRecordNames.insert(snapshot.recordName)
                            }
                            cleanupPendingSnapshotsByFeed[feed] = snapshotsByIdentity
                            if feed.subscribed {
                                feed.subscribed = false
                                changedRemoteObjectIDs.insert(feed.objectID)
                            }
                        }

                        func applyTombstone(
                            _ payload: [String: Any],
                            recordName: String,
                            feedURL: String,
                            pendingSnapshots: [ICCloudPendingSubscriptionStateSnapshot]
                        ) throws -> Bool {
                            try ensureMetadataMapping(feedURL: feedURL, recordName: recordName)
                            let localMetadata = try metadata(for: feedURL)
                            if suppressDeletions,
                               let feed = resolvedFeedByFeedURL[feedURL], feed.subscribed {
                                _ = try restoreOutboxIntent(
                                    feedURL: feedURL,
                                    intentFeedURL: actualStoredFeedURLByFeedURL[feedURL],
                                    subscribed: true,
                                    changedAt: localMetadata?.localModifiedAt ?? Date()
                                )
                                return true
                            }
                            let discardedLocalMutation: Bool
                            switch try remoteDecision(
                                payload: payload,
                                recordName: recordName,
                                feedURL: feedURL
                            ) {
                            case .keepLocal:
                                return true
                            case .applyRemote(let discarded):
                                discardedLocalMutation = discarded
                            }
                            let remoteDate = payload["updatedAt"] as? Date
                                ?? Date(timeIntervalSince1970: 0)
                            if !discardedLocalMutation,
                               let localDate = localMetadata?.localModifiedAt,
                               localDate > remoteDate {
                                let subscribed = localMetadata?.localState
                                    ?? resolvedFeedByFeedURL[feedURL]?.subscribed
                                    ?? false
                                _ = try restoreOutboxIntent(
                                    feedURL: feedURL,
                                    intentFeedURL: actualStoredFeedURLByFeedURL[feedURL],
                                    subscribed: subscribed,
                                    changedAt: localDate
                                )
                                return true
                            }
                            try updateMetadata(
                                feedURL: feedURL,
                                localModifiedAt: remoteDate,
                                localState: false,
                                payloadHash: nil
                            )
                            if let feed = resolvedFeedByFeedURL[feedURL] {
                                unsubscribe(feed, pendingSnapshots: pendingSnapshots)
                            }
                            return true
                        }

                        func applyChange(_ change: PendingSubscriptionChange) throws -> Bool {
                            guard !change.feedURL.isEmpty else { return true }
                            let feedURL = change.feedURL
                            if change.isLegacyDeletion {
                                try ensureMetadataMapping(
                                    feedURL: feedURL,
                                    recordName: change.recordName
                                )
                                if suppressDeletions { return true }
                                if try observePhysicalDeletionAgainstOutbox(
                                    recordName: change.recordName,
                                    feedURL: feedURL
                                ) {
                                    return true
                                }
                                let localMetadata = try metadata(for: feedURL)
                                try updateMetadata(
                                    feedURL: feedURL,
                                    localModifiedAt: localMetadata?.localModifiedAt,
                                    localState: false,
                                    payloadHash: nil,
                                    updating: [.localState, .payloadHash]
                                )
                                if let feed = resolvedFeedByFeedURL[feedURL] {
                                    unsubscribe(feed, pendingSnapshots: change.snapshots)
                                }
                                return true
                            }
                            if change.isTombstone {
                                let applied = try applyTombstone(
                                    change.payload,
                                    recordName: change.recordName,
                                    feedURL: feedURL,
                                    pendingSnapshots: change.snapshots
                                )
                                if applied,
                                   !change.recordName.hasPrefix(RecordPrefix.subscriptionTombstone),
                                   !hasCompleteOutboxPair(
                                    for: change.recordName,
                                    feedURL: feedURL
                                   ) {
                                    let localMetadata = try metadata(for: feedURL)
                                    _ = try restoreOutboxIntent(
                                        feedURL: feedURL,
                                        subscribed: localMetadata?.localState ?? false,
                                        changedAt: localMetadata?.localModifiedAt
                                            ?? (change.payload["updatedAt"] as? Date)
                                            ?? Date(timeIntervalSince1970: 0)
                                    )
                                }
                                return applied
                            }

                            try ensureMetadataMapping(
                                feedURL: feedURL,
                                recordName: change.recordName
                            )
                            let discardedLocalMutation: Bool
                            switch try remoteDecision(
                                payload: change.payload,
                                recordName: change.recordName,
                                feedURL: feedURL
                            ) {
                            case .keepLocal:
                                return true
                            case .applyRemote(let discarded):
                                discardedLocalMutation = discarded
                            }
                            let remoteDate = change.payload["updatedAt"] as? Date
                                ?? Date(timeIntervalSince1970: 0)
                            let localMetadata = try metadata(for: feedURL)
                            if !discardedLocalMutation,
                               let localDate = localMetadata?.localModifiedAt,
                               localDate > remoteDate {
                                let subscribed = localMetadata?.localState
                                    ?? resolvedFeedByFeedURL[feedURL]?.subscribed
                                    ?? false
                                _ = try restoreOutboxIntent(
                                    feedURL: feedURL,
                                    intentFeedURL: actualStoredFeedURLByFeedURL[feedURL],
                                    subscribed: subscribed,
                                    changedAt: localDate
                                )
                                return true
                            }

                            let feed: CDFeed
                            if let existing = resolvedFeedByFeedURL[feedURL] {
                                feed = existing
                            } else {
                                guard let url = subscriptionStorageURL(feedURL) else { return false }
                                guard let insertedFeed = NSEntityDescription.insertNewObject(
                                    forEntityName: "Feed",
                                    into: context
                                ) as? CDFeed else { return false }
                                insertedFeed.sourceURL = url
                                insertedFeed.title = (change.payload["title"] as? String).flatMap {
                                    $0.isEmpty ? nil : $0
                                } ?? feedURL
                                insertedFeed.subscribed = true
                                feed = insertedFeed
                                let insertedIdentities = Set(
                                    subscriptionFeedIdentityCandidates(feedURL)
                                )
                                for (candidateFeedURL, candidates) in identityCandidatesByFeedURL
                                where resolvedFeedByFeedURL[candidateFeedURL] == nil
                                        && !insertedIdentities.isDisjoint(with: Set(candidates)) {
                                    resolvedFeedByFeedURL[candidateFeedURL] = insertedFeed
                                }
                                changedRemoteObjectIDs.insert(insertedFeed.objectID)
                            }
                            if !feed.subscribed {
                                feed.subscribed = true
                                changedRemoteObjectIDs.insert(feed.objectID)
                            }
                            cleanupAffectedFeeds.insert(feed)
                            feedsRequiringCleanup.remove(feed)
                            applySubscriptionPayloadInBackground(
                                change.payload,
                                to: feed,
                                changedRemoteObjectIDs: &changedRemoteObjectIDs,
                                credentialPasswordsByFeed: &credentialPasswordsByFeed
                            )
                            try updateMetadata(
                                feedURL: feedURL,
                                localModifiedAt: remoteDate,
                                localState: true,
                                payloadHash: subscriptionPayloadHash(
                                    for: feed,
                                    passwordOverride: credentialPasswordsByFeed[feed]?.password
                                )
                            )
                            return true
                        }

                        func removePendingSubscriptionSnapshots(
                            _ snapshots: [ICCloudPendingSubscriptionStateSnapshot]
                        ) {
                            for snapshot in snapshots {
                                guard let pending = pendingByRecordName[snapshot.recordName] else { continue }
                                context.delete(pending)
                                pendingByRecordName.removeValue(forKey: snapshot.recordName)
                                appliedSnapshots.append(snapshot)
                            }
                        }

                        for change in changes {
                            guard try applyChange(change) else { continue }
                            if !change.isTombstone,
                               let feed = resolvedFeedByFeedURL[change.feedURL],
                               let payloadPassword = change.payload["password"] as? String,
                               credentialPasswordsByFeed[feed]?.password == payloadPassword {
                                credentialPendingSnapshots.append(contentsOf: change.snapshots)
                            } else {
                                removePendingSubscriptionSnapshots(change.snapshots.filter {
                                    !heldCleanupSnapshotRecordNames.contains($0.recordName)
                                })
                            }
                        }

                        guard validityGate.subscriptionApplyIsValid(
                            generation: generation,
                            accountRecordName: accountRecordName,
                            epoch: subscriptionEpoch
                        ), !Task.isCancelled else {
                            throw CancellationError()
                        }
                        if !context.insertedObjects.isEmpty {
                            try context.obtainPermanentIDs(for: Array(context.insertedObjects))
                        }
                        var hasPendingSubscriptionCleanup = false
                        for feed in cleanupAffectedFeeds {
                            let cleanupSnapshots = (cleanupPendingSnapshotsByFeed[feed]?.values
                                .sorted {
                                    if $0.accountRecordName != $1.accountRecordName {
                                        return $0.accountRecordName < $1.accountRecordName
                                    }
                                    return $0.recordName < $1.recordName
                                }) ?? []
                            if feedsRequiringCleanup.contains(feed), !feed.subscribed {
                                guard let feedURL = feed.value(forKey: "sourceURL_") as? String,
                                      !feedURL.isEmpty else {
                                    throw localOutboxStoreError(
                                        code: 2,
                                        description: "Der lokale Abo-Aufräumauftrag hat keine Podcast-Adresse."
                                    )
                                }
                                let cleanupRevision = try persistPendingSubscriptionCleanupIntent(
                                    for: feed,
                                    feedURL: feedURL,
                                    pendingSnapshots: cleanupSnapshots,
                                    context: context
                                )
                                cleanupProtectionRevisionsByFeedObjectURIString[
                                    feed.objectID.uriRepresentation().absoluteString
                                ] = cleanupRevision
                                hasPendingSubscriptionCleanup = true
                            } else {
                                let feedObjectURIString = feed.objectID
                                    .uriRepresentation().absoluteString
                                if try subscriptionCleanupIntentEntry(
                                    feedObjectURIString: feedObjectURIString,
                                    context: context
                                ) != nil {
                                    guard let feedURL = feed.value(forKey: "sourceURL_") as? String,
                                          !feedURL.isEmpty else {
                                        throw localOutboxStoreError(
                                            code: 2,
                                            description: "Der lokale Abo-Aufräumauftrag hat keine Podcast-Adresse."
                                        )
                                    }
                                    let cleanupRevision = try persistPendingSubscriptionCleanupIntent(
                                        for: feed,
                                        feedURL: feedURL,
                                        pendingSnapshots: cleanupSnapshots,
                                        context: context
                                    )
                                    cleanupProtectionRevisionsByFeedObjectURIString[
                                        feedObjectURIString
                                    ] = cleanupRevision
                                    hasPendingSubscriptionCleanup = true
                                }
                                removePendingSubscriptionSnapshots(cleanupSnapshots)
                            }
                        }
                        let userEntityNames: Set<String> = ["Feed", "FeedProperty"]
                        let insertedObjectURIStrings = Set(context.insertedObjects.compactMap {
                            userEntityNames.contains($0.entity.name ?? "")
                                ? $0.objectID.uriRepresentation().absoluteString : nil
                        })
                        let updatedObjectURIStrings = Set(context.updatedObjects.compactMap {
                            userEntityNames.contains($0.entity.name ?? "")
                                ? $0.objectID.uriRepresentation().absoluteString : nil
                        })
                        let deletedObjectURIStrings = Set(context.deletedObjects.compactMap {
                            userEntityNames.contains($0.entity.name ?? "")
                                ? $0.objectID.uriRepresentation().absoluteString : nil
                        })
                        let remoteObjectURIStrings = insertedObjectURIStrings.union(
                            updatedObjectURIStrings
                        )
                        let credentialUpdates = credentialPasswordsByFeed.compactMap {
                            feed, credential -> ICCloudSubscriptionCredentialUpdate? in
                            guard let sourceURLString = feed.value(forKey: "sourceURL_") as? String,
                                  let username = feed.username,
                                  !username.isEmpty else { return nil }
                            return ICCloudSubscriptionCredentialUpdate(
                                feedObjectURIString: feed.objectID.uriRepresentation().absoluteString,
                                sourceURLString: sourceURLString,
                                username: username,
                                expectedPassword: credential.expectedPassword,
                                password: credential.password
                            )
                        }
                        originRegistration = remoteOriginGate.register(remoteObjectURIStrings)

                        var finalOutboxSnapshots: [String: ICCloudSyncOutboxSnapshot] = [:]
                        for (recordName, entry) in outboxByRecordName {
                            finalOutboxSnapshots[recordName] = try subscriptionOutboxSnapshot(
                                from: entry
                            )
                        }
                        guard validityGate.subscriptionApplyIsValid(
                            generation: generation,
                            accountRecordName: accountRecordName,
                            epoch: subscriptionEpoch
                        ), !Task.isCancelled else {
                            throw CancellationError()
                        }
                        guard let acquiredCommitLease = validityGate.acquireSubscriptionApplyCommitLease(
                            generation: generation,
                            accountRecordName: accountRecordName,
                            epoch: subscriptionEpoch
                        ) else {
                            throw CancellationError()
                        }
                        commitLease = acquiredCommitLease
                        if !cleanupProtectionRevisionsByFeedObjectURIString.isEmpty {
                            guard let subscriptionManager = SubscriptionManager.shared() else {
                                throw localOutboxStoreError(
                                    code: 1,
                                    description: "Die lokale Abo-Bereinigung konnte nicht geschützt werden."
                                )
                            }
                            for (feedObjectURIString, revision) in
                                cleanupProtectionRevisionsByFeedObjectURIString {
                                guard let stageToken = subscriptionManager
                                    .stageAutoDownloadsDuringUnsubscribeCleanup(
                                        feedObjectURIString: feedObjectURIString,
                                        revision: revision
                                    ) else {
                                    throw localOutboxStoreError(
                                        code: 1,
                                        description: "Die lokale Abo-Bereinigung konnte nicht geschützt werden."
                                    )
                                }
                                stagedCleanupProtectionsByFeedObjectURIString[
                                    feedObjectURIString
                                ] = ICCloudSubscriptionCleanupProtectionStage(
                                    revision: revision,
                                    stageToken: stageToken
                                )
                            }
                        }
                        if context.hasChanges {
                            try context.save()
                        }
                        for (feedObjectURIString, protection) in
                            stagedCleanupProtectionsByFeedObjectURIString {
                            SubscriptionManager.shared()?
                                .commitAutoDownloadsDuringUnsubscribeCleanup(
                                    feedObjectURIString: feedObjectURIString,
                                    revision: protection.revision,
                                    stageToken: protection.stageToken
                                )
                        }
                        return ICCloudSubscriptionApplyBatchResult(
                            appliedSnapshots: appliedSnapshots,
                            needsOutboxDrain: needsOutboxDrain,
                            finalOutboxSnapshots: finalOutboxSnapshots,
                            removedOutboxRevisions: removedOutboxRevisions,
                            completedOutboxRecordNames: completedOutboxRecordNames,
                            insertedObjectURIStrings: insertedObjectURIStrings,
                            updatedObjectURIStrings: updatedObjectURIStrings,
                            deletedObjectURIStrings: deletedObjectURIStrings,
                            remoteObjectURIStrings: remoteObjectURIStrings,
                            credentialUpdates: credentialUpdates,
                            credentialPendingSnapshots: credentialPendingSnapshots,
                            hasPendingSubscriptionCleanup: hasPendingSubscriptionCleanup,
                            originRegistration: originRegistration,
                            commitLease: commitLease
                        )
                    } catch {
                        for (feedObjectURIString, protection) in
                            stagedCleanupProtectionsByFeedObjectURIString {
                            SubscriptionManager.shared()?
                                .cancelAutoDownloadsDuringUnsubscribeCleanup(
                                    feedObjectURIString: feedObjectURIString,
                                    revision: protection.revision,
                                    stageToken: protection.stageToken
                                )
                        }
                        context.rollback()
                        remoteOriginGate.discard(originRegistration)
                        if let commitLease {
                            validityGate.releaseRemoteApplyCommitLease(commitLease)
                        }
                        throw error
                    }
                }
            } catch {
                let persistenceError = error as NSError
                if attempt == 0,
                   persistenceError.domain == NSCocoaErrorDomain,
                   persistenceError.code == 133020 {
                    continue
                }
                throw error
            }
        }
        throw pendingSubscriptionStateStoreError(
            code: 3,
            description: "Die iCloud-Abonnements konnten nicht konfliktfrei gespeichert werden."
        )
    }

    func consumeSubscriptionApplyBatchResult(
        _ result: ICCloudSubscriptionApplyBatchResult,
        accountRecordName: String,
        generation: Int,
        subscriptionEpoch: UInt64
    ) async throws {
        let commitLease = result.commitLease
        var commitLeaseNeedsRelease = commitLease != nil
        if let commitLease {
            guard syncEngineCallbackGate.remoteApplyCommitLeaseIsActive(commitLease) else {
                remoteSubscriptionOriginGate.discard(result.originRegistration)
                throw CancellationError()
            }
        } else {
            guard generation == cloudAccountGeneration,
                  isICloudAccountIdentityVerified,
                  subscriptionsSyncEnabled,
                  !isICloudAccountSignedOut,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                  syncEngineCallbackGate.subscriptionApplyIsValid(
                    generation: generation,
                    accountRecordName: accountRecordName,
                    epoch: subscriptionEpoch
                  ) else {
                remoteSubscriptionOriginGate.discard(result.originRegistration)
                throw CancellationError()
            }
        }
        defer {
            if commitLeaseNeedsRelease, let commitLease {
                syncEngineCallbackGate.releaseRemoteApplyCommitLease(commitLease)
            }
        }
        guard let context = databaseManager.objectContext else {
            remoteSubscriptionOriginGate.discard(result.originRegistration)
            throw Self.pendingSubscriptionStateStoreError(
                code: 1,
                description: "Die iCloud-Abonnements konnten nicht in die Benutzeroberfläche übernommen werden."
            )
        }
        let registeredOriginURIStrings = remoteSubscriptionOriginGate.take(
            result.originRegistration
        )
        let originObjectIDs = try managedObjectIDs(
            forURIStrings: registeredOriginURIStrings,
            coordinator: databaseManager.storeCoordinator
        )
        remoteAppliedObjectIDs.formUnion(originObjectIDs)
        defer {
            remoteAppliedObjectIDs.subtract(originObjectIDs)
        }

        let insertedObjectIDs = try managedObjectIDs(
            forURIStrings: result.insertedObjectURIStrings,
            coordinator: databaseManager.storeCoordinator
        )
        let updatedObjectIDs = try managedObjectIDs(
            forURIStrings: result.updatedObjectURIStrings,
            coordinator: databaseManager.storeCoordinator
        )
        let deletedObjectIDs = try managedObjectIDs(
            forURIStrings: result.deletedObjectURIStrings,
            coordinator: databaseManager.storeCoordinator
        )
        var changes: [AnyHashable: Any] = [:]
        if !insertedObjectIDs.isEmpty { changes[NSInsertedObjectIDsKey] = insertedObjectIDs }
        if !updatedObjectIDs.isEmpty { changes[NSUpdatedObjectIDsKey] = updatedObjectIDs }
        if !deletedObjectIDs.isEmpty { changes[NSDeletedObjectIDsKey] = deletedObjectIDs }
        performSynchronousRemoteViewContextMerge(changes, into: context)

        for update in result.credentialUpdates {
            let objectIDs = try managedObjectIDs(
                forURIStrings: [update.feedObjectURIString],
                coordinator: databaseManager.storeCoordinator
            )
            guard let objectID = objectIDs.first,
                  let feed = try? context.existingObject(with: objectID) as? CDFeed,
                  feed.value(forKey: "sourceURL_") as? String == update.sourceURLString,
                  feed.username == update.username else { continue }
            let replaced: Bool
            do {
                var didMatch = ObjCBool(false)
                try feed.compareAndSetPassword(
                    update.password,
                    expected: update.expectedPassword,
                    expectedPresent: update.expectedPassword != nil,
                    didMatch: &didMatch
                )
                replaced = didMatch.boolValue
            } catch {
                throw Self.pendingSubscriptionStateStoreError(
                    code: 4,
                    description: "Podcast-Zugangsdaten konnten nicht sicher im Schlüsselbund gespeichert werden."
                )
            }
            guard replaced else {
                guard restoreDurableSubscriptionOutboxIntent(
                    feedURL: update.sourceURLString,
                    subscribed: true,
                    changedAt: Date()
                ) else {
                    throw Self.localOutboxStoreError(
                        code: 1,
                        description: "Neuere lokale Podcast-Zugangsdaten konnten nicht für iCloud vorgemerkt werden."
                    )
                }
                if let error = databaseManager.saveReturningError() {
                    throw error
                }
                scheduleLocalOutboxDrain()
                continue
            }
        }

        for (recordName, removedRevision) in result.removedOutboxRevisions {
            if localOutboxSnapshotCache[recordName]?.revision == removedRevision {
                localOutboxSnapshotCache.removeValue(forKey: recordName)
            }
            if localOutboxRevisionsToDelete[recordName] == removedRevision {
                localOutboxRevisionsToDelete.removeValue(forKey: recordName)
            }
            if localOutboxRevisionsToAcknowledge[recordName] == removedRevision {
                localOutboxRevisionsToAcknowledge.removeValue(forKey: recordName)
            }
            if localOutboxRevisionsToRearm[recordName] == removedRevision {
                localOutboxRevisionsToRearm.removeValue(forKey: recordName)
            }
        }
        for snapshot in result.finalOutboxSnapshots.values {
            if localOutboxSnapshotCache[snapshot.recordName]?.revision == snapshot.revision {
                // The worker can acknowledge/re-arm the same durable revision without
                // changing its logical timestamp. Propagate that CAS result as well.
                localOutboxSnapshotCache[snapshot.recordName] = snapshot
            } else {
                mergeLocalOutboxSnapshotsIntoCache([snapshot])
            }
        }
        let completedRecordNames = result.completedOutboxRecordNames.filter { recordName in
            guard let removedRevision = result.removedOutboxRevisions[recordName] else {
                return localOutboxSnapshotCache[recordName] == nil
            }
            return localOutboxSnapshotCache[recordName]?.revision == removedRevision
                || localOutboxSnapshotCache[recordName] == nil
        }
        if !completedRecordNames.isEmpty {
            removePendingRecordChanges(recordNames: Set(completedRecordNames))
        }
        if result.needsOutboxDrain {
            scheduleLocalOutboxDrain()
        }

        // Everything protected by the remote-origin IDs has been delivered synchronously.
        // Clear them before the credential CAS cleanup suspends this MainActor task.
        remoteAppliedObjectIDs.subtract(originObjectIDs)
        if !result.credentialPendingSnapshots.isEmpty {
            _ = try await Self.removePendingSubscriptionStates(
                result.credentialPendingSnapshots
            )
        }

        // Cache/history/file deletion can be slow and does not depend on the cloud account.
        // Release the remote apply lease before awaiting it so account transitions and the
        // rest of the UI cannot be held hostage by local disk work.
        if let commitLease, commitLeaseNeedsRelease {
            syncEngineCallbackGate.releaseRemoteApplyCommitLease(commitLease)
            commitLeaseNeedsRelease = false
        }
        if result.hasPendingSubscriptionCleanup,
           let error = await drainPendingSubscriptionCleanupIntentsIfNeeded() {
            handleLocalSubscriptionCleanupFailure(error)
        }
    }

    func applyPendingSubscriptions() async {
        if let error = await drainPendingSubscriptionCleanupIntentsIfNeeded() {
            handleLocalSubscriptionCleanupFailure(error)
        }
        // Same enabled-gate as applyRemoteRecord: without it a customer who turned
        // subscription sync OFF could still get pending remote feeds subscribed
        // (including the network fetch) on the next app start.
        guard subscriptionsSyncEnabled, !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              let deviceID else { return }
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
            guard let subscriptionEpoch = syncEngineCallbackGate.beginSubscriptionApply(
                generation: generation,
                accountRecordName: accountRecordName
            ) else { return }

            do {
                let result = try await Self.applyPendingSubscriptionBatchInBackground(
                    accountRecordName: accountRecordName,
                    snapshots: page.snapshots,
                    generation: generation,
                    subscriptionEpoch: subscriptionEpoch,
                    suppressDeletions: defaults.bool(
                        forKey: Self.suppressSubscriptionDeletionsKey
                    ),
                    deviceID: deviceID,
                    validityGate: syncEngineCallbackGate,
                    remoteOriginGate: remoteSubscriptionOriginGate
                )
                try await consumeSubscriptionApplyBatchResult(
                    result,
                    accountRecordName: accountRecordName,
                    generation: generation,
                    subscriptionEpoch: subscriptionEpoch
                )
            } catch is CancellationError {
                return
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
            do {
                let listOutboxEntries = try await Self.localOutboxEntries(
                    accountRecordName: accountRecordName,
                    recordNames: [RecordPrefix.subscriptionListSettings]
                )
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified,
                      subscriptionsSyncEnabled,
                      defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName,
                      !Task.isCancelled else { return }
                mergeLocalOutboxSnapshotsIntoCache(listOutboxEntries)
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
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
        guard payload["values"] is [String: Any] else {
            logSyncEvent("Einstellungs-Payload ungültig", metadata: [
                "hasValues": false,
                "payloadKeyCount": payload.keys.count,
            ])
            return
        }
        guard discardPendingSingletonUploadIntent(
            recordName: RecordPrefix.appSettings
        ) else { return }
        guard adoptSettingsPayload(payload) else { return }
    }

    // Shared apply core: writes the synced values, re-baselines and refreshes the UI.
    @discardableResult
    func adoptSettingsPayload(_ payload: [String: Any]) -> Bool {
        let remoteDate = payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        guard let values = payload["values"] as? [String: Any] else {
            logSyncEvent("Einstellungs-Payload ungültig", metadata: [
                "hasValues": false,
                "payloadKeyCount": payload.keys.count,
            ])
            return false
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
        return true
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
        guard payload["values"] is [String: Any] else {
            logSyncEvent("Einstellungs-Payload ungültig", metadata: [
                "hasValues": false,
                "payloadKeyCount": payload.keys.count,
            ])
            return
        }
        guard discardPendingSingletonUploadIntent(
            recordName: RecordPrefix.appSettings
        ) else { return }
        guard adoptSettingsPayload(payload) else { return }
        // The parked Cloud payload is the crash-replay intent for this explicit choice.
        // Consume it only after the values and their new baseline were applied successfully.
        setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        logSyncEvent("Einstellungs-Wahl: iCloud-Stand übernommen")
        markSyncCompletedIfFinished()
    }

    // "Meine Einstellungen für alle verwenden": publish this device's settings with a
    // fresh date — the other devices adopt them via plain recency.
    @objc func resolveInitialSettingsPublishingLocal() {
        guard let payload = Self.syncMetadataValue(
            forKey: Self.pendingInitialSettingsPayloadKey
        ) as? [String: Any],
              let remoteDate = payload["updatedAt"] as? Date else {
            handleLocalPersistenceFailure(NSError(
                domain: "ICiCloudSyncInitialSettingsChoice",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The pending iCloud settings timestamp is unavailable."]
            ))
            return
        }
        guard let intent = persistPendingSingletonUploadIntent(
            for: appSettingsRecordID(),
            modifiedAt: remoteDate
        ) else { return }
        setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
        setSettingsLocalModifiedDate(intent.modifiedAt)
        setStoredSyncedSettingsHash(syncedSettingsHash())
        addPendingSave(appSettingsRecordID())
        logSyncEvent("Einstellungs-Wahl: lokale Einstellungen veröffentlicht")
        postStateChanged()
    }

    func applyRemoteListScrollPositions(_ payload: [String: Any]) {
        guard let positions = payload["positions"] as? [String: NSNumber] else { return }
        let remoteDate = payload["lastModified"] as? Date ?? payload["updatedAt"] as? Date ?? Date(timeIntervalSince1970: 0)
        if let localDate = scrollPositionsLocalModifiedDate(), localDate.compare(remoteDate) == .orderedDescending {
            guard persistPendingSingletonUploadIntent(
                for: listScrollPositionsRecordID(),
                modifiedAt: localDate
            ) != nil else { return }
            queueListScrollPositionsRecord()
            return
        }

        guard discardPendingSingletonUploadIntent(
            recordName: RecordPrefix.listScrollPositions
        ) else { return }
        ICApplySyncedListScrollPositions(positions, remoteDate)
        setScrollPositionsLocalModifiedDate(remoteDate)
    }
}
