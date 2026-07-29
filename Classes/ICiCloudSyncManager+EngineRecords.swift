//
//  ICiCloudSyncManager+EngineRecords.swift
//  Instacast
//
//  CKSyncEngine delegate callbacks and record/payload builders.
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Darwin
import Foundation
import UIKit

@available(iOS 17.0, *)
extension ICiCloudSyncManager {

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let event):
            guard let generation = await statePersistenceGeneration(for: syncEngine) else { return }
            do {
                try await persistStateSerialization(event.stateSerialization)
            } catch {
                await handleStatePersistenceFailure(
                    error,
                    syncEngine: syncEngine,
                    generation: generation
                )
            }

        default:
            await handleEventOnMain(event, syncEngine: syncEngine)
        }
    }

    func statePersistenceGeneration(for syncEngine: CKSyncEngine) -> Int? {
        guard syncEngine === self.syncEngine,
              !requiresSyncEngineStateRollbackAfterPersistenceFailure else { return nil }
        return cloudAccountGeneration
    }

    func handleStatePersistenceFailure(
        _ error: Error,
        syncEngine: CKSyncEngine,
        generation: Int
    ) {
        guard syncEngine === self.syncEngine,
              generation == cloudAccountGeneration else { return }
        handleLocalPersistenceFailure(error)
    }

    func handleEventOnMain(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === self.syncEngine else { return }
        if isICloudAccountSignedOut || !isICloudAccountIdentityVerified {
            switch event {
            case .accountChange, .stateUpdate:
                break
            default:
                return
            }
        }
        switch event {
        case .stateUpdate:
            // State updates are intercepted by the nonisolated delegate entry point so
            // JSON encoding and the atomic file write never block MainActor.
            break

        case .accountChange(let event):
            await handleAccountChange(event, syncEngine: syncEngine)

        case .fetchedDatabaseChanges(let event):
            await handleFetchedDatabaseChanges(event)

        case .fetchedRecordZoneChanges(let event):
            await handleFetchedRecordZoneChanges(event)

        case .sentDatabaseChanges(let event):
            handleSentDatabaseChanges(event)

        case .sentRecordZoneChanges(let event):
            await handleSentRecordZoneChanges(event, syncEngine: syncEngine)

        case .willFetchChanges, .willFetchRecordZoneChanges:
            if subscriptionsSyncEnabled {
                markPendingSubscriptionFetchIncomplete()
            }
            beginSyncActivity(.down)
            postStateChanged()

        case .willSendChanges:
            hasUnresolvedSyncFailures = false
            beginSyncActivity(.up)
            postStateChanged()

        case .didFetchChanges:
            // Active records, tombstones and their inverse physical deletions can arrive
            // in different zone-change events. Only a complete fetch gives us the full
            // logical set needed to apply one LWW subscription state without destructive
            // unsubscribe/resubscribe flicker.
            let generation = cloudAccountGeneration
            await applyPendingEpisodeStates()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  !hasUnresolvedSyncFailures else { return }
            markPendingSubscriptionFetchComplete()
            await applyPendingSubscriptions()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
            completeInitialBackfillFetchBeforeUploadIfNeeded()
            // The first complete fetch after (re-)enabling subscription sync has been
            // processed (its catch-up deletions were suppressed) — deletions arriving
            // from now on are live propagation and are applied again. Must happen here,
            // after a real FETCH, not in markSyncCompleted: during the backfill a run can
            // complete with sends only, and the catch-up fetch comes later.
            if subscriptionsSyncEnabled, !hasUnresolvedSyncFailures, !hasInitialUploadBackfillWork,
               defaults.bool(forKey: Self.suppressSubscriptionDeletionsKey) {
                defaults.removeObject(forKey: Self.suppressSubscriptionDeletionsKey)
                logSyncEvent("Abo-Löschungs-Unterdrückung beendet (erster Fetch abgeschlossen)")
            }
            // Initial settings publish, fetch-gated: the first complete fetch after
            // enabling settings sync brought no remote settings record (a parked
            // payload means one DID arrive and the user's choice is still pending) —
            // this device's settings seed the cloud.
            if settingsSyncEnabled, !hasUnresolvedSyncFailures,
               defaults.bool(forKey: Self.initialSettingsBackfillPendingKey),
               !hasPendingInitialSettingsChoice {
                guard let intent = persistPendingSingletonUploadIntent(
                    for: appSettingsRecordID()
                ) else { return }
                defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
                setSettingsLocalModifiedDate(intent.modifiedAt)
                setStoredSyncedSettingsHash(syncedSettingsHash())
                addPendingSave(appSettingsRecordID())
                logSyncEvent("Initiale Einstellungen werden hochgeladen (keine in iCloud gefunden)")
            }
            markSyncCompletedIfFinished()

        case .didFetchRecordZoneChanges(let event):
            if let error = event.error {
                hasUnresolvedSyncFailures = true
                setError(error)
                scheduleSyncRetryAfterFailure(error: error, reason: "fetchZoneChanges")
            } else {
                markSyncCompletedIfFinished()
            }

        case .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    nonisolated func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let generation = syncEngineCallbackGate.currentGeneration(for: syncEngine) else { return nil }
        guard let snapshot = Self.syncEngineCallbackSnapshot() else {
            syncEngineCallbackGate.recordInitialUploadOutcome(
                resolvedRecordNames: [],
                localReadFailed: true,
                generation: generation,
                for: syncEngine
            )
            return nil
        }
        guard !snapshot.requiresInitialBackfillFetchBeforeUpload else { return nil }
        let scopedChanges = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0) && Self.pendingChangeIsEnabled($0, snapshot: snapshot)
        }
        guard !scopedChanges.isEmpty else { return nil }

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var staleSaveChanges: [CKSyncEngine.PendingRecordZoneChange] = []

        var saveRecordIDs: [CKRecord.ID] = []
        var validChangeCount = 0
        for change in scopedChanges {
            if validChangeCount >= Self.maximumRecordZoneChangesPerBatch { break }

            switch change {
            case .saveRecord(let recordID):
                saveRecordIDs.append(recordID)
                validChangeCount += 1
            case .deleteRecord(let recordID):
                recordIDsToDelete.append(recordID)
                validChangeCount += 1

            @unknown default:
                break
            }
        }

        // Materialize the whole batch with ONE Core Data fetch for the episodes instead of a
        // fresh background context + fetch per record. The per-record approach was the upload
        // bottleneck (1-2 min for 4400 episodes) and the store-lock contention that froze the UI.
        let materialized = Self.materializeRecordsForSyncEngineCallback(saveRecordIDs, snapshot: snapshot)
        recordsToSave = materialized.records
        staleSaveChanges = materialized.stale
        var unresolvedRecordIDs = materialized.unresolved

        guard syncEngineCallbackGate.currentGeneration(for: syncEngine) == generation else { return nil }

        let pendingDeviceControlIntents = snapshot.pendingDeviceControlIntents
        let localOutboxDeleteRecordIDs = recordIDsToDelete.filter {
            !$0.recordName.hasPrefix(RecordPrefix.device)
        }
        let deviceControlDeleteRecordIDs = recordIDsToDelete.filter {
            $0.recordName.hasPrefix(RecordPrefix.device)
        }
        let deleteOutboxLookup = Self.localOutboxEntriesByRecordName(
            Set(localOutboxDeleteRecordIDs.map(\.recordName)),
            accountRecordName: snapshot.accountUserRecordName)
        let deleteOutboxEntries = deleteOutboxLookup.values
        var staleDeleteChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        if deleteOutboxLookup.succeeded {
            recordIDsToDelete = deviceControlDeleteRecordIDs + localOutboxDeleteRecordIDs.filter { recordID in
                guard let entry = deleteOutboxEntries[recordID.recordName] else { return true }
                guard entry.operation == Self.localOutboxDeleteOperation,
                      !entry.acknowledged else {
                    staleDeleteChanges.append(.deleteRecord(recordID))
                    return false
                }
                return true
            }
        } else {
            unresolvedRecordIDs.append(contentsOf: localOutboxDeleteRecordIDs)
            recordIDsToDelete = deviceControlDeleteRecordIDs
        }
        recordIDsToDelete = recordIDsToDelete.filter { recordID in
            guard recordID.recordName.hasPrefix(RecordPrefix.device) else { return true }
            let targetDeviceID = String(recordID.recordName.dropFirst(RecordPrefix.device.count))
            guard let intent = pendingDeviceControlIntents[targetDeviceID],
                  intent.operation == Self.localOutboxDeleteOperation else {
                staleDeleteChanges.append(.deleteRecord(recordID))
                return false
            }
            return true
        }
        if !staleDeleteChanges.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: staleDeleteChanges)
        }
        let deleteAttemptRevisions = Dictionary(uniqueKeysWithValues: recordIDsToDelete.compactMap { recordID -> (String, String)? in
            if recordID.recordName.hasPrefix(RecordPrefix.device) {
                let targetDeviceID = String(recordID.recordName.dropFirst(RecordPrefix.device.count))
                guard let pendingDeviceControlIntent = pendingDeviceControlIntents[targetDeviceID],
                      pendingDeviceControlIntent.operation == Self.localOutboxDeleteOperation else { return nil }
                return (recordID.recordName, pendingDeviceControlIntent.revision)
            }
            guard let entry = deleteOutboxEntries[recordID.recordName],
                  entry.operation == Self.localOutboxDeleteOperation,
                  !entry.acknowledged else { return nil }
            return (recordID.recordName, entry.revision)
        })
        syncEngineCallbackGate.recordDeleteAttempts(deleteAttemptRevisions,
                                                    generation: generation,
                                                    for: syncEngine)

        var resolvedInitialUploadRecordNames: [String] = []
        if !staleSaveChanges.isEmpty {
            let staleUserDataSaveChanges = staleSaveChanges.filter { change in
                if case .saveRecord(let recordID) = change {
                    return Self.isUserDataRecordName(recordID.recordName)
                }
                return false
            }
            if !staleUserDataSaveChanges.isEmpty {
                Self.logStaleUserDataSaveChanges(staleUserDataSaveChanges, snapshot: snapshot, pendingRecordZoneChanges: syncEngine.state.pendingRecordZoneChanges.count)
            }
            syncEngine.state.remove(pendingRecordZoneChanges: staleSaveChanges)
            resolvedInitialUploadRecordNames = staleSaveChanges.compactMap { change -> String? in
                if case .saveRecord(let recordID) = change { return recordID.recordName }
                return nil
            }
        }

        syncEngineCallbackGate.recordInitialUploadOutcome(
            resolvedRecordNames: resolvedInitialUploadRecordNames,
            localReadFailed: !unresolvedRecordIDs.isEmpty,
            localChangesDeferred: !materialized.deferred.isEmpty,
            generation: generation,
            for: syncEngine
        )

        guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
        Self.logSyncEvent("CKSyncEngine-Send-Batch materialisiert", snapshot: snapshot, pendingRecordZoneChanges: syncEngine.state.pendingRecordZoneChanges.count, metadata: [
            "scopedChanges": scopedChanges.count,
            "recordsToSave": recordsToSave.count,
            "recordIDsToDelete": recordIDsToDelete.count,
            "staleSaveChanges": staleSaveChanges.count,
            "validChangeCount": validChangeCount,
            // Identifies what keeps re-queueing in repeated small batches (record names
            // carry only hashes/prefixes, no user content).
            "recordNames": recordsToSave.prefix(6).map { $0.recordID.recordName }.joined(separator: ","),
            "deleteNames": recordIDsToDelete.prefix(3).map { $0.recordName }.joined(separator: ","),
        ])
        guard syncEngineCallbackGate.currentGeneration(for: syncEngine) == generation else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: recordsToSave,
                                                  recordIDsToDelete: recordIDsToDelete,
                                                  atomicByZone: false)
    }

    nonisolated static func pendingChangeIsEnabled(_ change: CKSyncEngine.PendingRecordZoneChange,
                                                    snapshot: SyncEngineCallbackSnapshot) -> Bool {
        let recordName: String
        switch change {
        case .saveRecord(let recordID), .deleteRecord(let recordID):
            recordName = recordID.recordName
        @unknown default:
            return true
        }
        if recordName.hasPrefix(RecordPrefix.episode)
            || recordName == RecordPrefix.listScrollPositions {
            return snapshot.episodesSyncEnabled
        }
        if recordName.hasPrefix(RecordPrefix.subscription)
            || recordName.hasPrefix(RecordPrefix.subscriptionTombstone)
            || recordName == RecordPrefix.subscriptionListSettings {
            return snapshot.subscriptionsSyncEnabled
                && !snapshot.hasIncompletePendingSubscriptionFetch
        }
        if recordName == RecordPrefix.appSettings {
            return snapshot.settingsSyncEnabled
                && !snapshot.initialSettingsBackfillPending
                && !snapshot.initialSettingsChoicePending
        }
        return true
    }

    struct SyncPayloadLookup {
        let values: [String: [String: Any]]
        let succeeded: Bool
    }

    struct SyncOutboxLookup {
        let values: [String: ICCloudSyncOutboxSnapshot]
        let succeeded: Bool
    }

    struct SyncItemMetadataLookup {
        let values: [String: ICCloudSyncItemMetadataSnapshot]
        let succeeded: Bool
    }

    struct KnownRecordSystemFieldsLookup {
        let recordsByRecordName: [String: CKRecord]
        let invalidRecordNames: Set<String>
        let succeeded: Bool
    }

    nonisolated static func materializeRecordsForSyncEngineCallback(_ recordIDs: [CKRecord.ID], snapshot: SyncEngineCallbackSnapshot) -> (records: [CKRecord], stale: [CKSyncEngine.PendingRecordZoneChange], unresolved: [CKRecord.ID], deferred: [CKRecord.ID]) {
        var records: [CKRecord] = []
        var stale: [CKSyncEngine.PendingRecordZoneChange] = []
        var deferred: [CKRecord.ID] = []
        let knownRecordLookup = knownRecordSystemFieldsForSyncEngineCallback(
            recordIDs,
            accountRecordName: snapshot.accountUserRecordName
        )
        guard knownRecordLookup.succeeded else {
            return (records, stale, recordIDs, deferred)
        }
        var unresolved = recordIDs.filter {
            knownRecordLookup.invalidRecordNames.contains($0.recordName)
        }
        let materializableRecordIDs = recordIDs.filter {
            !knownRecordLookup.invalidRecordNames.contains($0.recordName)
        }
        let localOutboxLookup = localOutboxEntriesByRecordName(
            Set(materializableRecordIDs.map(\.recordName)),
            accountRecordName: snapshot.accountUserRecordName)
        guard localOutboxLookup.succeeded else {
            unresolved.append(contentsOf: materializableRecordIDs)
            return (records, stale, unresolved, deferred)
        }
        let localOutboxEntriesByRecordName = localOutboxLookup.values
        let legacySyncItemRecordNames = Set(materializableRecordIDs.compactMap { recordID -> String? in
            if recordID.recordName.hasPrefix(RecordPrefix.episode) {
                return recordID.recordName
            }
            guard localOutboxEntriesByRecordName[recordID.recordName] == nil,
                  recordID.recordName.hasPrefix(RecordPrefix.subscription) else { return nil }
            return recordID.recordName
        })
        let syncItemMetadataLookup = syncItemMetadataByRecordNameForSyncEngineCallback(
            legacySyncItemRecordNames,
            accountRecordName: snapshot.accountUserRecordName
        )

        let episodeRecordIDs = materializableRecordIDs.filter { $0.recordName.hasPrefix(RecordPrefix.episode) }
        if !episodeRecordIDs.isEmpty {
            if snapshot.episodesSyncEnabled {
                let legacyEpisodeRecordIDs = episodeRecordIDs.filter { localOutboxEntriesByRecordName[$0.recordName] == nil }
                let statesLookup = episodeStatesByObjectHash(legacyEpisodeRecordIDs.map { String($0.recordName.dropFirst(RecordPrefix.episode.count)) })
                for recordID in episodeRecordIDs {
                    if let entry = localOutboxEntriesByRecordName[recordID.recordName] {
                        guard syncItemMetadataLookup.succeeded else {
                            unresolved.append(recordID)
                            continue
                        }
                        if episodeOutboxRevisionResolvedByMetadata(
                            entry,
                            metadata: syncItemMetadataLookup.values[recordID.recordName]
                        ) {
                            stale.append(.saveRecord(recordID))
                            continue
                        }
                        guard entry.category == localOutboxEpisodeCategory,
                              entry.operation == localOutboxSaveOperation,
                              !entry.acknowledged,
                              var payload = entry.payloadDictionary() else {
                            stale.append(.saveRecord(recordID))
                            continue
                        }
                        payload["updatedAt"] = entry.changedAt
                        payload[localMutationRevisionPayloadKey] = entry.revision
                        let record = mutableRecordForSyncEngineCallback(
                            recordType: RecordKind.episodeState,
                            recordID: recordID,
                            knownRecordsByRecordName: knownRecordLookup.recordsByRecordName
                        )
                        populateForSyncEngineCallback(record, payload: payload, updatedAt: entry.changedAt, deviceID: snapshot.deviceID)
                        records.append(record)
                        continue
                    }
                    let objectHash = String(recordID.recordName.dropFirst(RecordPrefix.episode.count))
                    guard syncItemMetadataLookup.succeeded else {
                        unresolved.append(recordID)
                        continue
                    }
                    guard let itemMetadata = syncItemMetadataLookup.values[recordID.recordName] else {
                        stale.append(.saveRecord(recordID))
                        continue
                    }
                    guard itemMetadata.category == localOutboxEpisodeCategory,
                          itemMetadata.itemIdentifier == objectHash else {
                        logSyncEvent("Lokale iCloud-Episodenmetadaten sind widersprüchlich", metadata: [
                            "recordName": recordID.recordName,
                        ])
                        unresolved.append(recordID)
                        continue
                    }
                    guard statesLookup.succeeded else {
                        unresolved.append(recordID)
                        continue
                    }
                    guard var payload = statesLookup.values[objectHash] else {
                        if localOutboxEntriesByRecordName[recordID.recordName] != nil {
                            logSyncEvent("Lokaler Episoden-Outbox-Payload ist nicht lesbar", metadata: ["recordName": recordID.recordName])
                            continue
                        }
                        stale.append(.saveRecord(recordID))
                        continue
                    }
                    let updatedAt = itemMetadata.localModifiedAt ?? Date()
                    payload["updatedAt"] = updatedAt
                    let record = mutableRecordForSyncEngineCallback(
                        recordType: RecordKind.episodeState,
                        recordID: recordID,
                        knownRecordsByRecordName: knownRecordLookup.recordsByRecordName
                    )
                    populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
                    records.append(record)
                }
            } else {
                stale.append(contentsOf: episodeRecordIDs.map { .saveRecord($0) })
            }
        }

        // Subscriptions get the same one-fetch-per-batch treatment as episodes. The previous
        // per-record path (fresh background context + feed fetch + a relationship fault per
        // feed property) was the same store-lock-contention pattern that froze the UI when
        // toggling episode sync — just triggered by the subscriptions switch instead.
        let subscriptionRecordIDs = materializableRecordIDs.filter {
            $0.recordName.hasPrefix(RecordPrefix.subscription)
                && !$0.recordName.hasPrefix(RecordPrefix.subscriptionTombstone)
        }
        if !subscriptionRecordIDs.isEmpty {
            if snapshot.subscriptionsSyncEnabled {
                let legacySubscriptionRecordIDs = subscriptionRecordIDs.filter { localOutboxEntriesByRecordName[$0.recordName] == nil }
                let feedURLs = legacySubscriptionRecordIDs.compactMap {
                    syncItemMetadataLookup.values[$0.recordName]?.itemIdentifier
                }
                let payloadsLookup = subscriptionPayloadsByFeedURL(feedURLs, deviceID: snapshot.deviceID)
                for recordID in subscriptionRecordIDs {
                    if let entry = localOutboxEntriesByRecordName[recordID.recordName] {
                        guard entry.category == localOutboxSubscriptionCategory,
                              entry.operation == localOutboxSaveOperation,
                              !entry.acknowledged,
                              var payload = entry.payloadDictionary() else {
                            stale.append(.saveRecord(recordID))
                            continue
                        }
                        payload["updatedAt"] = entry.changedAt
                        payload[localMutationRevisionPayloadKey] = entry.revision
                        let record = mutableRecordForSyncEngineCallback(
                            recordType: RecordKind.subscription,
                            recordID: recordID,
                            knownRecordsByRecordName: knownRecordLookup.recordsByRecordName
                        )
                        populateForSyncEngineCallback(record, payload: payload, updatedAt: entry.changedAt, deviceID: snapshot.deviceID)
                        records.append(record)
                        continue
                    }
                    guard syncItemMetadataLookup.succeeded else {
                        unresolved.append(recordID)
                        continue
                    }
                    guard let itemMetadata = syncItemMetadataLookup.values[recordID.recordName] else {
                        stale.append(.saveRecord(recordID))
                        continue
                    }
                    guard itemMetadata.category == localOutboxSubscriptionCategory,
                          !itemMetadata.itemIdentifier.isEmpty else {
                        logSyncEvent("Lokale iCloud-Abo-Metadaten sind widersprüchlich", metadata: [
                            "recordName": recordID.recordName,
                        ])
                        unresolved.append(recordID)
                        continue
                    }
                    guard payloadsLookup.succeeded else {
                        unresolved.append(recordID)
                        continue
                    }
                    let feedURL = itemMetadata.itemIdentifier
                    guard var payload = payloadsLookup.values[feedURL] else {
                        if localOutboxEntriesByRecordName[recordID.recordName] != nil {
                            logSyncEvent("Lokaler Abo-Outbox-Payload ist nicht lesbar", metadata: ["recordName": recordID.recordName])
                            continue
                        }
                        stale.append(.saveRecord(recordID))
                        continue
                    }
                    let updatedAt = itemMetadata.localModifiedAt ?? Date()
                    payload["updatedAt"] = updatedAt
                    let record = mutableRecordForSyncEngineCallback(
                        recordType: RecordKind.subscription,
                        recordID: recordID,
                        knownRecordsByRecordName: knownRecordLookup.recordsByRecordName
                    )
                    populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
                    records.append(record)
                }
            } else {
                stale.append(contentsOf: subscriptionRecordIDs.map { .saveRecord($0) })
            }
        }


        let subscriptionTombstoneRecordIDs = materializableRecordIDs.filter {
            $0.recordName.hasPrefix(RecordPrefix.subscriptionTombstone)
        }
        if !subscriptionTombstoneRecordIDs.isEmpty {
            if snapshot.subscriptionsSyncEnabled {
                for recordID in subscriptionTombstoneRecordIDs {
                    guard let entry = localOutboxEntriesByRecordName[recordID.recordName],
                          entry.category == localOutboxSubscriptionCategory,
                          entry.operation == localOutboxSaveOperation,
                          !entry.acknowledged,
                          var payload = entry.payloadDictionary() else {
                        stale.append(.saveRecord(recordID))
                        continue
                    }
                    payload["updatedAt"] = entry.changedAt
                    payload[localMutationRevisionPayloadKey] = entry.revision
                    let record = mutableRecordForSyncEngineCallback(recordType: RecordKind.subscriptionTombstone,
                                                                    recordID: recordID,
                                                                    knownRecordsByRecordName: knownRecordLookup.recordsByRecordName)
                    populateForSyncEngineCallback(record, payload: payload,
                                                  updatedAt: entry.changedAt,
                                                  deviceID: snapshot.deviceID)
                    records.append(record)
                }
            } else {
                stale.append(contentsOf: subscriptionTombstoneRecordIDs.map { .saveRecord($0) })
            }
        }

        // Device / settings / scroll records — only a handful per batch.
        for recordID in materializableRecordIDs
        where !recordID.recordName.hasPrefix(RecordPrefix.episode)
            && !recordID.recordName.hasPrefix(RecordPrefix.subscription)
            && !recordID.recordName.hasPrefix(RecordPrefix.subscriptionTombstone) {
            if recordID.recordName == RecordPrefix.subscriptionListSettings,
               let entry = localOutboxEntriesByRecordName[recordID.recordName] {
                guard let singletonIntent = snapshot.pendingSingletonUploadIntents[recordID.recordName],
                      singletonIntent.revision == entry.revision,
                      singletonIntent.modifiedAt == entry.changedAt else {
                    deferred.append(recordID)
                    continue
                }
                guard entry.category == localOutboxSubscriptionListSettingsCategory,
                      entry.operation == localOutboxSaveOperation,
                      !entry.acknowledged else {
                    stale.append(.saveRecord(recordID))
                    continue
                }
                guard var payload = entry.payloadDictionary() else {
                    unresolved.append(recordID)
                    continue
                }
                payload["updatedAt"] = entry.changedAt
                payload[localMutationRevisionPayloadKey] = entry.revision
                let record = mutableRecordForSyncEngineCallback(
                    recordType: RecordKind.subscriptionListSettings,
                    recordID: recordID,
                    knownRecordsByRecordName: knownRecordLookup.recordsByRecordName
                )
                populateForSyncEngineCallback(
                    record,
                    payload: payload,
                    updatedAt: entry.changedAt,
                    deviceID: snapshot.deviceID
                )
                records.append(record)
                continue
            }
            if let record = recordToSaveForSyncEngineCallback(
                for: recordID,
                snapshot: snapshot,
                knownRecordsByRecordName: knownRecordLookup.recordsByRecordName
            ) {
                records.append(record)
            } else {
                stale.append(.saveRecord(recordID))
            }
        }
        return (records, stale, unresolved, deferred)
    }

    nonisolated static func knownRecordSystemFieldsForSyncEngineCallback(
        _ recordIDs: [CKRecord.ID],
        accountRecordName: String?
    ) -> KnownRecordSystemFieldsLookup {
        guard !recordIDs.isEmpty else {
            return KnownRecordSystemFieldsLookup(
                recordsByRecordName: [:],
                invalidRecordNames: [],
                succeeded: true
            )
        }
        let recordIDsByRecordName = Dictionary(
            recordIDs.map { ($0.recordName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard recordIDsByRecordName.count <= maximumRecordZoneChangesPerBatch,
              let accountRecordName, !accountRecordName.isEmpty,
              let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            return KnownRecordSystemFieldsLookup(
                recordsByRecordName: [:],
                invalidRecordNames: [],
                succeeded: false
            )
        }
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: knownRecordSystemFieldsEntityName)
            request.predicate = NSPredicate(
                format: "accountRecordName == %@ AND recordName IN %@",
                accountRecordName,
                Array(recordIDsByRecordName.keys)
            )
            request.includesSubentities = false
            request.fetchLimit = maximumRecordZoneChangesPerBatch
            request.fetchBatchSize = maximumRecordZoneChangesPerBatch
            do {
                var recordsByRecordName: [String: CKRecord] = [:]
                var invalidRecordNames = Set<String>()
                for entry in try context.fetch(request) {
                    guard let storedAccountRecordName = entry.value(forKey: "accountRecordName") as? String,
                          storedAccountRecordName == accountRecordName,
                          let recordName = entry.value(forKey: "recordName") as? String,
                          let expectedRecordID = recordIDsByRecordName[recordName] else {
                        context.reset()
                        return KnownRecordSystemFieldsLookup(
                            recordsByRecordName: [:],
                            invalidRecordNames: [],
                            succeeded: false
                        )
                    }
                    guard recordsByRecordName[recordName] == nil,
                          !invalidRecordNames.contains(recordName) else {
                        invalidRecordNames.insert(recordName)
                        recordsByRecordName.removeValue(forKey: recordName)
                        continue
                    }
                    let data: Data
                    if let storedData = entry.value(forKey: "systemFieldsData") as? Data {
                        data = storedData
                    } else if let storedData = entry.value(forKey: "systemFieldsData") as? NSData {
                        data = storedData as Data
                    } else {
                        invalidRecordNames.insert(recordName)
                        continue
                    }
                    do {
                        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
                        unarchiver.requiresSecureCoding = true
                        defer { unarchiver.finishDecoding() }
                        guard let record = CKRecord(coder: unarchiver),
                              record.recordID == expectedRecordID,
                              expectedRecordTypeForSyncEngineRecordName(recordName) == record.recordType else {
                            invalidRecordNames.insert(recordName)
                            continue
                        }
                        recordsByRecordName[recordName] = record
                    } catch {
                        invalidRecordNames.insert(recordName)
                    }
                }
                context.reset()
                if !invalidRecordNames.isEmpty {
                    logSyncEvent("Lokale CloudKit-Systemfelder sind beschädigt", metadata: [
                        "recordCount": invalidRecordNames.count,
                    ])
                }
                return KnownRecordSystemFieldsLookup(
                    recordsByRecordName: recordsByRecordName,
                    invalidRecordNames: invalidRecordNames,
                    succeeded: true
                )
            } catch {
                logSyncEvent("Lokale CloudKit-Systemfelder konnten für Upload nicht gelesen werden", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                context.reset()
                return KnownRecordSystemFieldsLookup(
                    recordsByRecordName: [:],
                    invalidRecordNames: [],
                    succeeded: false
                )
            }
        }
    }

    nonisolated static func expectedRecordTypeForSyncEngineRecordName(
        _ recordName: String
    ) -> CKRecord.RecordType? {
        if recordName.hasPrefix(RecordPrefix.episode) { return RecordKind.episodeState }
        if recordName.hasPrefix(RecordPrefix.subscriptionTombstone) {
            return RecordKind.subscriptionTombstone
        }
        if recordName.hasPrefix(RecordPrefix.subscription) { return RecordKind.subscription }
        if recordName.hasPrefix(RecordPrefix.device) { return RecordKind.device }
        if recordName == RecordPrefix.appSettings { return RecordKind.appSettings }
        if recordName == RecordPrefix.listScrollPositions { return RecordKind.listScrollPositions }
        if recordName == RecordPrefix.subscriptionListSettings {
            return RecordKind.subscriptionListSettings
        }
        return nil
    }

    nonisolated static func syncItemMetadataByRecordNameForSyncEngineCallback(
        _ recordNames: Set<String>,
        accountRecordName: String?
    ) -> SyncItemMetadataLookup {
        guard !recordNames.isEmpty else {
            return SyncItemMetadataLookup(values: [:], succeeded: true)
        }
        guard recordNames.count <= maximumRecordZoneChangesPerBatch,
              let accountRecordName, !accountRecordName.isEmpty,
              let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            return SyncItemMetadataLookup(values: [:], succeeded: false)
        }
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: syncItemMetadataEntityName)
            request.predicate = NSPredicate(
                format: "accountRecordName == %@ AND recordName IN %@",
                accountRecordName,
                Array(recordNames)
            )
            request.includesSubentities = false
            request.fetchLimit = maximumRecordZoneChangesPerBatch
            request.fetchBatchSize = maximumRecordZoneChangesPerBatch
            do {
                var values: [String: ICCloudSyncItemMetadataSnapshot] = [:]
                for entry in try context.fetch(request) {
                    let snapshot = try syncItemMetadataSnapshot(from: entry)
                    values[snapshot.recordName] = snapshot
                }
                context.reset()
                return SyncItemMetadataLookup(values: values, succeeded: true)
            } catch {
                logSyncEvent("Lokale iCloud-Sync-Metadaten konnten für Upload nicht gelesen werden", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                context.reset()
                return SyncItemMetadataLookup(values: [:], succeeded: false)
            }
        }
    }

    nonisolated static func localOutboxEntriesByRecordName(_ recordNames: Set<String>,
                                                            accountRecordName: String?) -> SyncOutboxLookup {
        guard !recordNames.isEmpty else { return SyncOutboxLookup(values: [:], succeeded: true) }
        guard let accountRecordName, !accountRecordName.isEmpty,
              let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            return SyncOutboxLookup(values: [:], succeeded: false)
        }
        return context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: localOutboxEntityName)
            request.predicate = NSPredicate(format: "accountRecordName == %@ AND recordName IN %@",
                                            accountRecordName, Array(recordNames))
            request.fetchBatchSize = pendingChangeQueueChunkSize
            let entries: [NSManagedObject]
            do {
                entries = try context.fetch(request)
            } catch {
                logSyncEvent("Lokale iCloud-Outbox konnte für Upload nicht gelesen werden", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                return SyncOutboxLookup(values: [:], succeeded: false)
            }
            var result: [String: ICCloudSyncOutboxSnapshot] = [:]
            var succeeded = true
            for entry in entries {
                guard let accountRecordName = entry.value(forKey: "accountRecordName") as? String,
                      let recordName = entry.value(forKey: "recordName") as? String,
                      let category = entry.value(forKey: "category") as? String,
                      let operation = entry.value(forKey: "operation") as? String,
                      let revision = entry.value(forKey: "revision") as? String,
                      let changedAt = entry.value(forKey: "changedAt") as? Date else {
                    succeeded = false
                    continue
                }
                let payloadData: Data
                if let data = entry.value(forKey: "payloadData") as? Data {
                    payloadData = data
                } else if let data = entry.value(forKey: "payloadData") as? NSData {
                    payloadData = data as Data
                } else {
                    succeeded = false
                    continue
                }
                result[recordName] = ICCloudSyncOutboxSnapshot(accountRecordName: accountRecordName,
                                                                recordName: recordName,
                                                                category: category,
                                                                operation: operation,
                                                                acknowledged: localOutboxEntryIsAcknowledged(entry),
                                                                revision: revision,
                                                                changedAt: changedAt,
                                                                payloadData: payloadData)
            }
            return SyncOutboxLookup(values: result, succeeded: succeeded)
        }
    }

    nonisolated static func logStaleUserDataSaveChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange], snapshot: SyncEngineCallbackSnapshot, pendingRecordZoneChanges: Int) {
        let recordNames = changes.compactMap { change -> String? in
            if case .saveRecord(let recordID) = change {
                return recordID.recordName
            }
            return nil
        }
        logSyncEvent("iCloud Upload-Nutzerdaten nicht materialisiert", snapshot: snapshot, pendingRecordZoneChanges: pendingRecordZoneChanges, metadata: [
            "staleUserDataSaveChanges": recordNames.count,
            "recordNames": recordNames.prefix(8).joined(separator: ","),
        ])
    }

    // One fetch (with the properties relationship prefetched) for the whole batch instead of
    // a context + fetch + property faults per subscription record.
    nonisolated static func subscriptionPayloadsByFeedURL(_ feedURLs: [String], deviceID: String) -> SyncPayloadLookup {
        guard !feedURLs.isEmpty else { return SyncPayloadLookup(values: [:], succeeded: true) }
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            return SyncPayloadLookup(values: [:], succeeded: false)
        }
        return context.performAndWait {
            let request = NSFetchRequest<CDFeed>(entityName: "Feed")
            request.predicate = NSPredicate(format: "sourceURL_ IN %@ AND subscribed == YES", feedURLs)
            request.includesSubentities = false
            request.relationshipKeyPathsForPrefetching = ["properties"]
            let feeds: [CDFeed]
            do {
                feeds = try context.fetch(request)
            } catch {
                logSyncEvent("Lokale Abonnements konnten für iCloud Upload nicht gelesen werden", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                return SyncPayloadLookup(values: [:], succeeded: false)
            }
            var result: [String: [String: Any]] = [:]
            for feed in feeds {
                guard let feedURL = feed.value(forKey: "sourceURL_") as? String else { continue }
                result[feedURL] = subscriptionPayload(for: feed, feedURL: feedURL, deviceID: deviceID)
            }
            return SyncPayloadLookup(values: result, succeeded: true)
        }
    }

    // The caller stamps "updatedAt" before populating the record.
    nonisolated static func subscriptionPayload(for feed: CDFeed, feedURL: String, deviceID: String) -> [String: Any] {
        let feedUID = feed.uid
        var properties: [[String: Any]] = []
        for property in feed.properties as? Set<CDFeedProperty> ?? [] {
            guard let key = property.key, !internalFeedPropertyKeys.contains(key) else { continue }
            var propertyPayload: [String: Any] = [
                "key": stableFeedPropertyKey(key, feedUID: feedUID),
                "valueType": Self.feedPropertyValueType(for: property),
                "boolValue": property.boolValue,
                "int32Value": Int(property.int32Value),
                "doubleValue": property.doubleValue,
            ]
            if let stringValue = property.stringValue {
                propertyPayload["stringValue"] = stringValue
            }
            properties.append(propertyPayload)
        }

        return [
            "feedURL": feedURL,
            "title": feed.title ?? "",
            "rank": Int(feed.rank),
            "parked": feed.parked,
            "username": feed.username ?? "",
            "password": feed.password ?? "",
            "properties": properties,
            "deviceID": deviceID,
        ]
    }

    nonisolated static func episodeStatesByObjectHash(_ objectHashes: [String]) -> SyncPayloadLookup {
        guard !objectHashes.isEmpty else { return SyncPayloadLookup(values: [:], succeeded: true) }
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            return SyncPayloadLookup(values: [:], succeeded: false)
        }
        return context.performAndWait {
            let request = NSFetchRequest<CDEpisode>(entityName: "Episode")
            request.predicate = NSPredicate(format: "objectHash IN %@", objectHashes)
            request.includesSubentities = false
            let episodes: [CDEpisode]
            do {
                episodes = try context.fetch(request)
            } catch {
                logSyncEvent("Lokale Episoden konnten für iCloud Upload nicht gelesen werden", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                return SyncPayloadLookup(values: [:], succeeded: false)
            }
            var result: [String: [String: Any]] = [:]
            for episode in episodes {
                guard let objectHash = episode.objectHash else { continue }
                result[objectHash] = [
                    "objectHash": objectHash,
                    "played": episode.consumed,
                    "position": Int(episode.position),
                    "starred": episode.starred,
                ]
            }
            return SyncPayloadLookup(values: result, succeeded: true)
        }
    }

    struct SyncEngineCallbackSnapshot {
        let episodesSyncEnabled: Bool
        let subscriptionsSyncEnabled: Bool
        let settingsSyncEnabled: Bool
        let initialSettingsBackfillPending: Bool
        let initialSettingsChoicePending: Bool
        let hasIncompletePendingSubscriptionFetch: Bool
        let requiresInitialBackfillFetchBeforeUpload: Bool
        let anySyncEnabled: Bool
        let deviceID: String
        let accountUserRecordName: String?
        let deviceRecordShouldStampSyncDate: Bool
        let settingsLocalModifiedDate: Date?
        let scrollPositionsLocalModifiedDate: Date?
        let lastSyncDate: Date?
        let pendingDeviceControlIntents: [String: PendingDeviceControlIntent]
        let pendingSingletonUploadIntents: [String: PendingSingletonUploadIntent]
    }

    nonisolated static func syncEngineCallbackSnapshot() -> SyncEngineCallbackSnapshot? {
        let defaults = UserDefaults.standard
        let episodesEnabled = defaults.bool(forKey: ICiCloudSyncEpisodesEnabled)
        let subscriptionsEnabled = defaults.bool(forKey: ICiCloudSyncSubscriptionsEnabled)
        let settingsEnabled = defaults.bool(forKey: ICiCloudSyncSettingsEnabled)
        let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey)
        let fetchGateAccount = defaults.string(forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
        let fetchGateCategories = Set(
            defaults.stringArray(forKey: Self.initialBackfillFetchBeforeUploadCategoriesKey) ?? []
        )
        let requiresFetchBeforeUpload = fetchGateAccount == accountRecordName
            && ((episodesEnabled
                    && fetchGateCategories.contains("episodes"))
                || (subscriptionsEnabled
                    && fetchGateCategories.contains("subscriptions")))
        let pendingSubscriptionFetchComplete = (syncMetadataValue(forKey: Self.pendingSubscriptionFetchCompleteKey) as? NSNumber)?.boolValue == true
        var singletonIntents: [String: PendingSingletonUploadIntent] = [:]
        for intent in pendingSingletonUploadIntents() where intent.accountRecordName == accountRecordName {
            singletonIntents[intent.recordName] = intent
        }
        var deviceControlIntents: [String: PendingDeviceControlIntent] = [:]
        for intent in pendingDeviceControlIntents() where intent.accountRecordName == accountRecordName {
            deviceControlIntents[intent.targetDeviceID] = intent
        }
        guard let deviceID = deviceIDForSyncEngineCallback() else { return nil }
        return SyncEngineCallbackSnapshot(
            episodesSyncEnabled: episodesEnabled,
            subscriptionsSyncEnabled: subscriptionsEnabled,
            settingsSyncEnabled: settingsEnabled,
            initialSettingsBackfillPending: defaults.bool(forKey: Self.initialSettingsBackfillPendingKey),
            initialSettingsChoicePending: syncMetadataValue(forKey: Self.pendingInitialSettingsPayloadKey) != nil,
            hasIncompletePendingSubscriptionFetch: subscriptionsEnabled
                && !pendingSubscriptionFetchComplete,
            requiresInitialBackfillFetchBeforeUpload: requiresFetchBeforeUpload,
            anySyncEnabled: episodesEnabled || subscriptionsEnabled || settingsEnabled,
            deviceID: deviceID,
            accountUserRecordName: accountRecordName,
            deviceRecordShouldStampSyncDate: defaults.bool(forKey: Self.deviceRecordShouldStampSyncDateKey),
            settingsLocalModifiedDate: defaults.object(forKey: Self.settingsLocalModifiedDateKey) as? Date,
            scrollPositionsLocalModifiedDate: defaults.object(forKey: Self.scrollPositionsLocalModifiedDateKey) as? Date,
            lastSyncDate: defaults.object(forKey: Self.lastSyncDateKey) as? Date,
            pendingDeviceControlIntents: deviceControlIntents,
            pendingSingletonUploadIntents: singletonIntents
        )
    }

    // Episode and subscription records are materialized in batches with a single fetch —
    // see materializeRecordsForSyncEngineCallback. This handles only the singleton records.
    nonisolated static func recordToSaveForSyncEngineCallback(
        for recordID: CKRecord.ID,
        snapshot: SyncEngineCallbackSnapshot,
        knownRecordsByRecordName: [String: CKRecord]
    ) -> CKRecord? {
        if recordID.recordName.hasPrefix(RecordPrefix.device) {
            return deviceRecordForSyncEngineCallback(
                for: recordID,
                snapshot: snapshot,
                knownRecordsByRecordName: knownRecordsByRecordName
            )
        }
        if recordID.recordName == RecordPrefix.appSettings {
            guard snapshot.settingsSyncEnabled,
                  !snapshot.initialSettingsBackfillPending,
                  !snapshot.initialSettingsChoicePending else { return nil }
            return appSettingsRecordForSyncEngineCallback(
                for: recordID,
                snapshot: snapshot,
                knownRecordsByRecordName: knownRecordsByRecordName
            )
        }
        if recordID.recordName == RecordPrefix.listScrollPositions {
            guard snapshot.episodesSyncEnabled else { return nil }
            return listScrollPositionsRecordForSyncEngineCallback(
                for: recordID,
                snapshot: snapshot,
                knownRecordsByRecordName: knownRecordsByRecordName
            )
        }
        if recordID.recordName == RecordPrefix.subscriptionListSettings {
            guard snapshot.subscriptionsSyncEnabled else { return nil }
            return subscriptionListSettingsRecordForSyncEngineCallback(
                for: recordID,
                snapshot: snapshot,
                knownRecordsByRecordName: knownRecordsByRecordName
            )
        }
        return nil
    }

    // The feed-list sort mode and the saved manual order belong to the SUBSCRIPTIONS:
    // they sync with subscription sync (not settings sync), so a device that only has
    // subscriptions enabled shows the same list the same way. Without the saved manual
    // order, "Manual" was not even offered in the receiving device's sort menu.
    nonisolated static func subscriptionListSettingsRecordForSyncEngineCallback(
        for recordID: CKRecord.ID,
        snapshot: SyncEngineCallbackSnapshot,
        knownRecordsByRecordName: [String: CKRecord]
    ) -> CKRecord {
        let intent = snapshot.pendingSingletonUploadIntents[recordID.recordName]
        let updatedAt = intent?.modifiedAt
            ?? UserDefaults.standard.object(forKey: Self.subscriptionListSettingsLocalModifiedDateKey) as? Date
            ?? Date()
        var payload = intent?.payloadDictionary()
            ?? subscriptionListSettingsPayloadForSyncEngineCallback(
                episodeListPayloads: episodeListPayloadsForSyncEngineCallback()
            )
        payload["updatedAt"] = updatedAt
        if let revision = intent?.revision {
            payload[localMutationRevisionPayloadKey] = revision
        }
        let record = mutableRecordForSyncEngineCallback(
            recordType: RecordKind.subscriptionListSettings,
            recordID: recordID,
            knownRecordsByRecordName: knownRecordsByRecordName
        )
        populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    // The "v2:" format prefix makes migrated baselines recognizable: on a baseline
    // written by an older build, checkAndQueueSettingsChange decides between a one-time
    // repair re-publish (device owns a manual order) and silently recording the baseline
    // (sort-mode-only device — publishing would race the real state under LWW; exactly
    // that race flipped the iPhone off "manual" once).
    nonisolated static let subscriptionListSettingsFingerprintPrefix = "v3:"
    nonisolated static let mainMenuListUIDsSchemaVersion = 1

    nonisolated static func subscriptionListSettingsFingerprint() -> String {
        subscriptionListSettingsFingerprint(
            episodeListPayloads: episodeListPayloadsForSyncEngineCallback()
        )
    }

    nonisolated static func subscriptionListSettingsFingerprint(
        episodeListPayloads: [[String: Any]]
    ) -> String {
        subscriptionListSettingsFingerprint(
            payload: subscriptionListSettingsPayloadForSyncEngineCallback(
                episodeListPayloads: episodeListPayloads
            )
        )
    }

    nonisolated static func subscriptionListSettingsPayloadForSyncEngineCallback(
        episodeListPayloads: [[String: Any]]
    ) -> [String: Any] {
        let defaults = UserDefaults.standard
        var payload: [String: Any] = [
            "sortMode": defaults.string(forKey: FeedListSortMode) ?? "",
            "episodeLists": episodeListPayloads,
            "mainMenuListUIDs": mainMenuListUIDsForSyncEngineCallback(),
            "mainMenuListUIDsSchemaVersion": mainMenuListUIDsSchemaVersion,
        ]
        if let manualOrder = defaults.array(forKey: manualFeedOrderDefaultsKey) as? [String],
           !manualOrder.isEmpty {
            payload["manualOrder"] = manualOrder
        }
        return payload
    }

    nonisolated static func subscriptionListSettingsFingerprint(
        payload: [String: Any]
    ) -> String {
        let sortMode = payload["sortMode"] as? String ?? ""
        let manualOrder = payload["manualOrder"] as? [String] ?? []
        var components = ["sortMode=\(sortMode)", "manualOrder=\(manualOrder.joined(separator: "\u{1}"))"]
        let mainMenuListUIDs = payload["mainMenuListUIDs"] as? [String] ?? []
        components.append("mainMenuListUIDs=\(mainMenuListUIDs.joined(separator: "\u{1}"))")
        let mainMenuSchemaVersion = payload["mainMenuListUIDsSchemaVersion"] as? Int ?? 0
        components.append("mainMenuListUIDsSchemaVersion=\(mainMenuSchemaVersion)")
        let episodeListPayloads = payload["episodeLists"] as? [[String: Any]] ?? []
        components.append(contentsOf: episodeListPayloads.map { episodeListFingerprintComponent($0) })
        return subscriptionListSettingsFingerprintPrefix + sha256Hex(components.joined(separator: "\u{2}"))
    }

    nonisolated static func episodeListPayloadsForSyncEngineCallback() -> [[String: Any]] {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else { return [] }
        return context.performAndWait {
            let request = NSFetchRequest<CDEpisodeList>(entityName: "EpisodeList")
            request.includesSubentities = false
            request.relationshipKeyPathsForPrefetching = ["includedFeeds"]
            request.sortDescriptors = [
                NSSortDescriptor(key: "rank", ascending: true),
                NSSortDescriptor(key: "uid", ascending: true),
            ]
            let lists = (try? context.fetch(request)) ?? []
            return lists.compactMap { episodeListPayloadForSyncEngineCallback($0) }
        }
    }

    nonisolated static func episodeListPayloadForSyncEngineCallback(_ list: CDEpisodeList) -> [String: Any]? {
        guard let uid = list.uid, !uid.isEmpty else { return nil }
        let includedFeedURLs = ((list.includedFeeds as? Set<CDFeed>) ?? [])
            .compactMap { $0.value(forKey: "sourceURL_") as? String }
            .sorted()
        return [
            "uid": uid,
            "name": list.name ?? "",
            "icon": list.icon ?? "",
            "rank": Int(list.rank),
            "query": list.query ?? "",
            "audio": list.audio,
            "video": list.video,
            "downloaded": list.downloaded,
            "downloading": list.downloading,
            "notDownloaded": list.notDownloaded,
            "unplayed": list.unplayed,
            "unfinished": list.unfinished,
            "played": list.played,
            "starred": list.starred,
            "notStarred": list.notStarred,
            "orderBy": list.orderBy ?? "",
            "descending": list.descending,
            "groupByPodcast": list.groupByPodcast,
            "continuousPlayback": list.continuousPlayback,
            "usePodcastArtwork": list.usePodcastArtwork,
            "includedFeedURLs": includedFeedURLs,
        ]
    }

    nonisolated static func mainMenuListUIDsForSyncEngineCallback() -> [String] {
        if let storedUIDs = UserDefaults.standard.array(forKey: "MainMenuListUIDs") as? [String] {
            return storedUIDs
        }
        return defaultMainMenuListUIDs()
    }

    nonisolated static func episodeListFingerprintComponent(_ payload: [String: Any]) -> String {
        let keys = [
            "uid", "name", "icon", "rank", "query", "audio", "video", "downloaded",
            "downloading", "notDownloaded", "unplayed", "unfinished", "played",
            "starred", "notStarred", "orderBy", "descending", "groupByPodcast",
            "continuousPlayback", "usePodcastArtwork",
        ]
        var components = keys.map { key in "\(key)=\(payload[key] ?? "")" }
        let includedFeedURLs = payload["includedFeedURLs"] as? [String] ?? []
        components.append("includedFeedURLs=\(includedFeedURLs.joined(separator: "\u{1}"))")
        return components.joined(separator: "\u{1}")
    }

    // A device without any list sort state (fresh install, sort menu never used) has
    // nothing to publish — and must never defend that emptiness under last-writer-wins.
    nonisolated static func hasLocalSubscriptionListSettings() -> Bool {
        let defaults = UserDefaults.standard
        if let sortMode = defaults.string(forKey: FeedListSortMode), !sortMode.isEmpty { return true }
        if let manualOrder = defaults.array(forKey: manualFeedOrderDefaultsKey) as? [String], !manualOrder.isEmpty { return true }
        if hasLocalEpisodeListSettings() { return true }
        if hasLocalMainMenuListSettings() { return true }
        return false
    }

    nonisolated static func hasLocalManualFeedOrder() -> Bool {
        let manualOrder = UserDefaults.standard.array(forKey: manualFeedOrderDefaultsKey) as? [String]
        return manualOrder?.isEmpty == false
    }

    nonisolated static func hasLocalSubscriptionListSettingsForInitialBackfill() -> Bool {
        hasLocalManualFeedOrder() || hasLocalEpisodeListSettings() || hasLocalMainMenuListSettings()
    }

    nonisolated static func hasLocalEpisodeListSettings() -> Bool {
        for payload in episodeListPayloadsForSyncEngineCallback() {
            guard let uid = payload["uid"] as? String else { continue }
            guard let defaultPayload = defaultEpisodeListPayload(uid: uid) else { return true }
            if episodeListFingerprintComponent(payload) != episodeListFingerprintComponent(defaultPayload) {
                return true
            }
        }
        return false
    }

    nonisolated static func hasLocalMainMenuListSettings() -> Bool {
        guard UserDefaults.standard.object(forKey: "MainMenuListUIDs") != nil else { return false }
        return mainMenuListUIDsForSyncEngineCallback() != defaultMainMenuListUIDs()
    }

    nonisolated static func defaultMainMenuListUIDs() -> [String] {
        ["default.favorites", "default.unplayed", "default.started", "default.downloaded"]
    }

    nonisolated static func defaultEpisodeListPayload(uid: String) -> [String: Any]? {
        let defaults: [String: [String: Any]] = [
            "default.favorites": [
                "uid": "default.favorites",
                "name": NSLocalizedString("Favorites", comment: ""),
                "icon": "List Favorites",
                "rank": 0,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": true,
                "unfinished": true,
                "played": true,
                "starred": true,
                "notStarred": false,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "usePodcastArtwork": false,
                "includedFeedURLs": [],
            ],
            "default.unplayed": [
                "uid": "default.unplayed",
                "name": NSLocalizedString("Unplayed", comment: ""),
                "icon": "List Unplayed",
                "rank": 1,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": true,
                "unfinished": true,
                "played": false,
                "starred": true,
                "notStarred": true,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "usePodcastArtwork": false,
                "includedFeedURLs": [],
            ],
            "default.started": [
                "uid": "default.started",
                "name": NSLocalizedString("Started", comment: ""),
                "icon": "List Partially Played",
                "rank": 2,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": false,
                "unfinished": true,
                "played": false,
                "starred": true,
                "notStarred": true,
                "orderBy": "lastPlayed",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "usePodcastArtwork": false,
                "includedFeedURLs": [],
            ],
            "default.downloaded": [
                "uid": "default.downloaded",
                "name": NSLocalizedString("Downloaded", comment: ""),
                "icon": "List Downloaded",
                "rank": 3,
                "query": "",
                "audio": true,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": false,
                "unplayed": true,
                "unfinished": true,
                "played": true,
                "starred": true,
                "notStarred": true,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "usePodcastArtwork": false,
                "includedFeedURLs": [],
            ],
            "default.video": [
                "uid": "default.video",
                "name": NSLocalizedString("Videos", comment: ""),
                "icon": "List Video",
                "rank": 4,
                "query": "",
                "audio": false,
                "video": true,
                "downloaded": true,
                "downloading": true,
                "notDownloaded": true,
                "unplayed": true,
                "unfinished": true,
                "played": true,
                "starred": true,
                "notStarred": true,
                "orderBy": "pubDate",
                "descending": true,
                "groupByPodcast": false,
                "continuousPlayback": true,
                "usePodcastArtwork": false,
                "includedFeedURLs": [],
            ],
        ]
        return defaults[uid]
    }

    nonisolated static func deviceRecordForSyncEngineCallback(
        for recordID: CKRecord.ID,
        snapshot: SyncEngineCallbackSnapshot,
        knownRecordsByRecordName: [String: CKRecord]
    ) -> CKRecord? {
        let targetDeviceID = String(recordID.recordName.dropFirst(RecordPrefix.device.count))
        guard targetDeviceID == snapshot.deviceID,
              let intent = snapshot.pendingDeviceControlIntents[targetDeviceID],
              intent.operation == localOutboxSaveOperation,
              var payload = intent.payloadDictionary() else { return nil }
        let updatedAt = payload["updatedAt"] as? Date ?? intent.createdAt
        payload[localMutationRevisionPayloadKey] = intent.revision
        let record = mutableRecordForSyncEngineCallback(
            recordType: RecordKind.device,
            recordID: recordID,
            knownRecordsByRecordName: knownRecordsByRecordName
        )
        populateForSyncEngineCallback(
            record,
            payload: payload,
            updatedAt: updatedAt,
            deviceID: snapshot.deviceID
        )
        record["deviceID"] = targetDeviceID as CKRecordValue
        return record
    }


    // Some feed-property keys embed the feed's `uid`, e.g. "<uid>_auto_skip_chapter_name" (the
    // auto-skip chapter terms + per-chapter offsets). `uid` is a *per-device* random UUID, so a
    // literal key would never match on another device. We translate the local uid prefix to a
    // stable marker on upload and back to the receiving device's own uid on apply, so these
    // settings actually sync. (Feeds themselves sync by URL hash, episodes by content hash —
    // those were already device-stable; only these uid-prefixed properties were broken.)
    nonisolated static let feedUIDKeyMarker = "@@FEEDUID@@"

    nonisolated static func stableFeedPropertyKey(_ key: String, feedUID: String?) -> String {
        guard let feedUID, !feedUID.isEmpty, key.hasPrefix(feedUID + "_") else { return key }
        return feedUIDKeyMarker + key.dropFirst(feedUID.count)
    }

    nonisolated static func localFeedPropertyKey(_ key: String, feedUID: String?) -> String {
        guard key.hasPrefix(feedUIDKeyMarker) else { return key }
        let suffix = key.dropFirst(feedUIDKeyMarker.count)
        guard let feedUID, !feedUID.isEmpty else { return String(suffix) }
        return feedUID + suffix
    }

    nonisolated static func appSettingsRecordForSyncEngineCallback(
        for recordID: CKRecord.ID,
        snapshot: SyncEngineCallbackSnapshot,
        knownRecordsByRecordName: [String: CKRecord]
    ) -> CKRecord {
        let intent = snapshot.pendingSingletonUploadIntents[recordID.recordName]
        let updatedAt = intent?.modifiedAt ?? snapshot.settingsLocalModifiedDate ?? Date()
        var payload = intent?.payloadDictionary()
            ?? appSettingsPayloadForSyncEngineCallback(
                updatedAt: updatedAt,
                deviceID: snapshot.deviceID
            )
        payload["updatedAt"] = updatedAt
        if let revision = intent?.revision {
            payload[localMutationRevisionPayloadKey] = revision
        }
        let record = mutableRecordForSyncEngineCallback(
            recordType: RecordKind.appSettings,
            recordID: recordID,
            knownRecordsByRecordName: knownRecordsByRecordName
        )
        populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    nonisolated static func listScrollPositionsRecordForSyncEngineCallback(
        for recordID: CKRecord.ID,
        snapshot: SyncEngineCallbackSnapshot,
        knownRecordsByRecordName: [String: CKRecord]
    ) -> CKRecord {
        let intent = snapshot.pendingSingletonUploadIntents[recordID.recordName]
        let updatedAt = intent?.modifiedAt
            ?? snapshot.scrollPositionsLocalModifiedDate
            ?? ICListScrollPositionsLastModifiedDate()
            ?? Date()
        var payload = intent?.payloadDictionary() ?? [
            "positions": ICListScrollPositionsSnapshot() ?? [:],
            "lastModified": updatedAt,
            "deviceID": snapshot.deviceID,
            "updatedAt": updatedAt,
        ]
        payload["lastModified"] = updatedAt
        payload["updatedAt"] = updatedAt
        if let revision = intent?.revision {
            payload[localMutationRevisionPayloadKey] = revision
        }
        let record = mutableRecordForSyncEngineCallback(
            recordType: RecordKind.listScrollPositions,
            recordID: recordID,
            knownRecordsByRecordName: knownRecordsByRecordName
        )
        populateForSyncEngineCallback(record, payload: payload, updatedAt: updatedAt, deviceID: snapshot.deviceID)
        return record
    }

    nonisolated static func mutableRecordForSyncEngineCallback(
        recordType: CKRecord.RecordType,
        recordID: CKRecord.ID,
        knownRecordsByRecordName: [String: CKRecord]
    ) -> CKRecord {
        if let knownRecord = knownRecordsByRecordName[recordID.recordName] {
            return knownRecord
        }
        return CKRecord(recordType: recordType, recordID: recordID)
    }

    nonisolated static func populateForSyncEngineCallback(_ record: CKRecord, payload: [String: Any], updatedAt: Date, deviceID: String) {
        record["schemaVersion"] = Self.schemaVersion as CKRecordValue
        record["updatedAt"] = updatedAt as CKRecordValue
        record["deviceID"] = deviceID as CKRecordValue
        if let data = propertyListDataForSyncEngineCallback(from: payload) {
            record.encryptedValues["payload"] = data as CKRecordValue
        }
    }

    nonisolated static func localDevicePayloadForSyncEngineCallback(snapshot: SyncEngineCallbackSnapshot) -> [String: Any] {
        devicePayload(deviceID: snapshot.deviceID,
                      episodesEnabled: snapshot.episodesSyncEnabled,
                      subscriptionsEnabled: snapshot.subscriptionsSyncEnabled,
                      settingsEnabled: snapshot.settingsSyncEnabled,
                      lastSyncDate: snapshot.lastSyncDate)
    }

    // Single builder for this device's payload — used for both the uploaded record and the
    // locally merged device-list entry. There used to be two near-duplicates (one UIDevice-,
    // one ProcessInfo-based), so the local list showed different values than other devices
    // received for the same device.
    nonisolated static func devicePayload(deviceID: String,
                                                  episodesEnabled: Bool,
                                                  subscriptionsEnabled: Bool,
                                                  settingsEnabled: Bool,
                                                  lastSyncDate: Date?) -> [String: Any] {
        let marketingName = deviceMarketingNameForSyncEngineCallback()
        var payload: [String: Any] = [
            "deviceID": deviceID,
            "name": marketingName,
            "model": marketingName,
            "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": appVersionStringForSyncEngineCallback(),
            "episodesEnabled": episodesEnabled,
            "subscriptionsEnabled": subscriptionsEnabled,
            "settingsEnabled": settingsEnabled,
        ]
        if let lastSyncDate {
            payload["lastSyncDate"] = lastSyncDate
        }
        return payload
    }

    nonisolated static func appSettingsPayloadForSyncEngineCallback(updatedAt: Date, deviceID: String) -> [String: Any] {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        let values = syncableNonDefaultSettingsValuesForSyncEngineCallback(domain)
        let registeredDefaults = defaults.volatileDomain(forName: UserDefaults.registrationDomain)
        let defaultKeys = registeredDefaults.compactMap { key, value -> String? in
            guard shouldSyncSettingsKeyForSyncEngineCallback(key),
                  isValidSettingsValueForSyncEngineCallback(value),
                  values[key] == nil else { return nil }
            return key
        }.sorted()

        let credentials = ICRemoteChapterCredentialStore.backupCredentialValues()
        return [
            "values": values,
            "defaultKeys": defaultKeys,
            "credentials": credentials,
            "deviceID": deviceID,
            "updatedAt": updatedAt,
        ]
    }

    nonisolated static func syncableNonDefaultSettingsValuesForSyncEngineCallback(_ domain: [String: Any]) -> [String: Any] {
        let registeredDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        var values: [String: Any] = [:]
        for (key, value) in domain {
            guard shouldSyncSettingsKeyForSyncEngineCallback(key),
                  isValidSettingsValueForSyncEngineCallback(value) else { continue }
            if let registeredDefault = registeredDefaults[key],
               let valueObject = value as? NSObject,
               let defaultObject = registeredDefault as? NSObject,
               valueObject.isEqual(defaultObject) {
                continue
            }
            values[key] = value
        }
        return values
    }

    nonisolated static func shouldSyncSettingsKeyForSyncEngineCallback(_ key: String) -> Bool {
        if syncMetadataKeysForSyncEngineCallback().contains(key) { return false }
        if key.hasPrefix("ICiCloudSync") { return false }
        if transientSettingsKeysForSyncEngineCallback().contains(key) { return false }
        if nonSettingsUserDefaultsKeysForSyncEngineCallback().contains(key) { return false }
        return true
    }

    nonisolated static func syncMetadataKeysForSyncEngineCallback() -> Set<String> {
        [
            Self.deviceIDKey,
            Self.engineStateKey,
            Self.knownRecordsKey,
            Self.deviceCacheKey,
            Self.pendingEpisodeStatesKey,
            Self.pendingSubscriptionPayloadsKey,
            Self.settingsLocalModifiedDateKey,
            Self.settingsSyncedHashKey,
            Self.scrollPositionsLocalModifiedDateKey,
            Self.lastSyncDateKey,
            Self.lastStatusKey,
            Self.lastErrorKey,
            Self.deviceRecordShouldStampSyncDateKey,
        ]
    }

    nonisolated static func transientSettingsKeysForSyncEngineCallback() -> Set<String> {
        [
            LastRefreshSubscriptionDate,
            FirstLaunchDate,
            kUIPersistenceMainSidebarItem,
            kUIPersistenceSubscriptionsSelectedFeedUID,
            kUIPersistenceSubscriptionsSearchTerm,
            kUIPersistencePlaylistsSelectedPlaylistUID,
            kUIPersistenceBookmarkSelectedEpisodeGUID,
            kUIPersistenceDirectorySearchSearchString,
            kUIPersistenceDirectorySearchSelectedScopeIndex,
            UIStateSelectedFeed,
            UIStateSelectedEpisode,
            kUIPersistenceListScrollPositions,
            kUIPersistenceListScrollPositionsLastModified,
            UncompletedSleepTimeInterval,
            "TranscriptionBackgroundTaskActive",
            "TranscriptionBackgroundTaskRequested",
            // Device-local playback restore state (AudioSession kPlaybackState* keys).
            // Syncing PlaybackEpisode dirtied the settings hash on EVERY episode change
            // (one settings upload per switch) and made another device restore this
            // device's episode after a restart. Positions sync via episode states.
            "PlaybackEpisode",
            "PlaybackPlaylist",
            "PlaybackSourceList",
            // Per-device statistics counters (User-Entscheid 08.07.: Statistiken bleiben
            // lokal). Synced as settings, last-writer-wins overwrote one device's counts
            // with another's on every settings apply.
            "TotalEpisodesPlayedCount",
            "TotalListeningTime",
            "SleepTimerFellAsleepCount",
            // Travels with subscription sync (ICSubscriptionListSettings), not settings sync.
            FeedListSortMode,
            "MainMenuListUIDs",
            "MainMenuListUIDsMigratedDefaults",
            "MainMenuListUIDsEmptyRepairV1",
            "MainMenuListUIDsEmptyRepairPendingUploadV1",
        ]
    }

    nonisolated static func nonSettingsUserDefaultsKeysForSyncEngineCallback() -> Set<String> {
        [
            "DownloadResumeInfos",
            "DownloadResumeInfos_NSURLSession",
            "EpisodeLoadingQueueKey",
            "ICDiagnosticPreviousSessionEndedInBackground",
            "ICDiagnosticPreviousSessionEndedUnexpectedly",
            "ICDiagnosticPreviousSessionState",
            // This is the version of the device-local SQLite FTS file. Every device must
            // rebuild its own index; syncing the flag can make another device skip repair.
            "FTSIndexVersion",
            "FTSMigrationDone",
            // Per-device WatchConnectivity transport bookkeeping. A remote settings apply
            // refreshes appearance, which sends a fresh Watch manifest and advances these
            // revisions. Syncing them as settings therefore echoed settings_app forever.
            "ICAppleWatchManifestRevision",
            "ICAppleWatchPendingManifestRevision",
            "ICAppleWatchReceivedManifestAcknowledgementRevision",
        ]
    }

    // Feed properties that are device-local bookkeeping and never synced.
    nonisolated static let internalFeedPropertyKeys: Set<String> = [
        "episodeLoadingComplete",
        "loadedEpisodeCount",
        "totalExpectedEpisodes",
        "cachedPlayerTintColor",
        "durationMetadataRefreshAttempted",
    ]

    nonisolated static func isValidSettingsValueForSyncEngineCallback(_ value: Any) -> Bool {
        switch value {
        case is String, is NSNumber, is Date:
            return true
        default:
            return false
        }
    }

    nonisolated static func propertyListDataForSyncEngineCallback(from dictionary: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
    }

    nonisolated static func deviceIDForSyncEngineCallback() -> String? {
        do {
            return try resolveInstallationDeviceID()
        } catch {
            logSyncEvent("Lokale iCloud-Geräteidentität konnte nicht gelesen werden", metadata: [
                "errorDomain": (error as NSError).domain,
                "errorCode": (error as NSError).code,
            ])
            return nil
        }
    }

    nonisolated static func deviceMarketingNameForSyncEngineCallback() -> String {
        let identifier = deviceHardwareIdentifierForSyncEngineCallback()
        if let name = deviceMarketingNamesForSyncEngineCallback()[identifier] {
            return name
        }
        return identifier.isEmpty ? "Unknown Device" : identifier
    }

    nonisolated static func deviceHardwareIdentifierForSyncEngineCallback() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0) ?? ""
            }
        }
    }

    nonisolated static func appVersionStringForSyncEngineCallback() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if version.isEmpty { return build }
        if build.isEmpty { return version }
        return "\(version) (\(build))"
    }

    nonisolated static func deviceMarketingNamesForSyncEngineCallback() -> [String: String] {
        [
            "iPhone12,1": "iPhone 11",
            "iPhone12,3": "iPhone 11 Pro",
            "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd generation)",
            "iPhone13,1": "iPhone 12 mini",
            "iPhone13,2": "iPhone 12",
            "iPhone13,3": "iPhone 12 Pro",
            "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro",
            "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone14,4": "iPhone 13 mini",
            "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd generation)",
            "iPhone14,7": "iPhone 14",
            "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro",
            "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
        ]
    }

    nonisolated static func date(from timeInterval: TimeInterval?) -> Date? {
        guard let timeInterval, timeInterval > 0 else { return nil }
        return Date(timeIntervalSince1970: timeInterval)
    }

    nonisolated static func logSyncEvent(_ message: String, snapshot: SyncEngineCallbackSnapshot, pendingRecordZoneChanges: Int, metadata: [String: Any] = [:]) {
        var details = metadata
        details["episodesSyncEnabled"] = snapshot.episodesSyncEnabled
        details["subscriptionsSyncEnabled"] = snapshot.subscriptionsSyncEnabled
        details["settingsSyncEnabled"] = snapshot.settingsSyncEnabled
        details["anySyncEnabled"] = snapshot.anySyncEnabled
        details["pendingRecordZoneChanges"] = pendingRecordZoneChanges
        details["isMainThread"] = Thread.isMainThread
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }
}
