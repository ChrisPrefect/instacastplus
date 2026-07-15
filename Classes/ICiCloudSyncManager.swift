//
//  ICiCloudSyncManager.swift
//  Instacast
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Darwin
import Foundation
import Security
import UIKit

final class ICiCloudSyncEngineCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var engineIdentifier: ObjectIdentifier?
    private var generation = 0
    private var isSignedOut = false
    private var isAccountIdentityVerified = false
    private var episodesSyncEnabled = false
    private var subscriptionsSyncEnabled = false
    private var episodeApplyEpoch: UInt64 = 0
    private var subscriptionApplyEpoch: UInt64 = 0
    private var activeRemoteApplyCommitLeases: [UUID: ICiCloudRemoteApplyCommitLease] = [:]
    private var remoteApplyAccountTransitionDepth = 0
    private var remoteApplyCommitLeaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var localCaptureAccountRecordName: String?
    private var deleteAttemptRevisionsByRecordName: [String: [String]] = [:]
    private var resolvedInitialUploadRecordNames: Set<String> = []
    private var localUploadReadFailed = false
    private var localChangesDeferred = false

    func update(syncEngine: CKSyncEngine?, generation: Int, isSignedOut: Bool,
                isAccountIdentityVerified: Bool, accountRecordName: String?,
                episodesSyncEnabled: Bool, subscriptionsSyncEnabled: Bool) {
        lock.lock()
        let engineChanged = engineIdentifier != syncEngine.map(ObjectIdentifier.init)
            || self.generation != generation
        engineIdentifier = syncEngine.map(ObjectIdentifier.init)
        self.generation = generation
        self.isSignedOut = isSignedOut
        self.isAccountIdentityVerified = isAccountIdentityVerified
        if self.episodesSyncEnabled != episodesSyncEnabled {
            episodeApplyEpoch &+= 1
        }
        self.episodesSyncEnabled = episodesSyncEnabled
        if self.subscriptionsSyncEnabled != subscriptionsSyncEnabled {
            subscriptionApplyEpoch &+= 1
        }
        self.subscriptionsSyncEnabled = subscriptionsSyncEnabled
        if !isSignedOut && isAccountIdentityVerified {
            localCaptureAccountRecordName = accountRecordName
        } else {
            localCaptureAccountRecordName = nil
        }
        if engineChanged || isSignedOut || !isAccountIdentityVerified {
            deleteAttemptRevisionsByRecordName = [:]
            resolvedInitialUploadRecordNames = []
            localUploadReadFailed = false
            localChangesDeferred = false
        }
        lock.unlock()
    }

    func beginEpisodeApply(generation: Int, accountRecordName: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard remoteApplyIsValid(
            category: .episodes,
            generation: generation,
            accountRecordName: accountRecordName,
            epoch: episodeApplyEpoch
        ) else { return nil }
        return episodeApplyEpoch
    }

    func episodeApplyIsValid(
        generation: Int,
        accountRecordName: String,
        epoch: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return remoteApplyIsValid(
            category: .episodes,
            generation: generation,
            accountRecordName: accountRecordName,
            epoch: epoch
        )
    }

    func beginSubscriptionApply(generation: Int, accountRecordName: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut,
              isAccountIdentityVerified,
              subscriptionsSyncEnabled,
              self.generation == generation,
              localCaptureAccountRecordName == accountRecordName else { return nil }
        return subscriptionApplyEpoch
    }

    func subscriptionApplyIsValid(
        generation: Int,
        accountRecordName: String,
        epoch: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isSignedOut
            && isAccountIdentityVerified
            && subscriptionsSyncEnabled
            && self.generation == generation
            && localCaptureAccountRecordName == accountRecordName
            && subscriptionApplyEpoch == epoch
    }

    func acquireEpisodeApplyCommitLease(
        generation: Int,
        accountRecordName: String,
        epoch: UInt64
    ) -> ICiCloudRemoteApplyCommitLease? {
        acquireRemoteApplyCommitLease(
            category: .episodes,
            generation: generation,
            accountRecordName: accountRecordName,
            epoch: epoch
        )
    }

    func acquireSubscriptionApplyCommitLease(
        generation: Int,
        accountRecordName: String,
        epoch: UInt64
    ) -> ICiCloudRemoteApplyCommitLease? {
        acquireRemoteApplyCommitLease(
            category: .subscriptions,
            generation: generation,
            accountRecordName: accountRecordName,
            epoch: epoch
        )
    }

    func acquireLocalCaptureCommitLease(
        accountRecordName: String
    ) -> ICiCloudRemoteApplyCommitLease? {
        lock.lock()
        defer { lock.unlock() }
        guard remoteApplyAccountTransitionDepth == 0,
              !accountRecordName.isEmpty,
              localCaptureAccountRecordName == nil
                || localCaptureAccountRecordName == accountRecordName else { return nil }
        let lease = ICiCloudRemoteApplyCommitLease(
            identifier: UUID(),
            category: .localCapture,
            generation: generation,
            accountRecordName: accountRecordName,
            epoch: 0
        )
        activeRemoteApplyCommitLeases[lease.identifier] = lease
        return lease
    }

    func remoteApplyCommitLeaseIsActive(_ lease: ICiCloudRemoteApplyCommitLease) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRemoteApplyCommitLeases[lease.identifier] == lease
    }

    func releaseRemoteApplyCommitLease(_ lease: ICiCloudRemoteApplyCommitLease) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if activeRemoteApplyCommitLeases[lease.identifier] == lease {
            activeRemoteApplyCommitLeases.removeValue(forKey: lease.identifier)
            if activeRemoteApplyCommitLeases.isEmpty {
                waiters = remoteApplyCommitLeaseWaiters
                remoteApplyCommitLeaseWaiters.removeAll()
            }
        }
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func beginRemoteApplyAccountTransition() {
        lock.lock()
        remoteApplyAccountTransitionDepth += 1
        lock.unlock()
    }

    func awaitRemoteApplyCommitLeases() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if activeRemoteApplyCommitLeases.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                remoteApplyCommitLeaseWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func endRemoteApplyAccountTransition() {
        lock.lock()
        precondition(remoteApplyAccountTransitionDepth > 0)
        remoteApplyAccountTransitionDepth -= 1
        lock.unlock()
    }

    private func acquireRemoteApplyCommitLease(
        category: ICiCloudRemoteApplyCategory,
        generation: Int,
        accountRecordName: String,
        epoch: UInt64
    ) -> ICiCloudRemoteApplyCommitLease? {
        lock.lock()
        defer { lock.unlock() }
        guard remoteApplyAccountTransitionDepth == 0,
              remoteApplyIsValid(
                category: category,
                generation: generation,
                accountRecordName: accountRecordName,
                epoch: epoch
              ) else { return nil }
        let lease = ICiCloudRemoteApplyCommitLease(
            identifier: UUID(),
            category: category,
            generation: generation,
            accountRecordName: accountRecordName,
            epoch: epoch
        )
        activeRemoteApplyCommitLeases[lease.identifier] = lease
        return lease
    }

    private func remoteApplyIsValid(
        category: ICiCloudRemoteApplyCategory,
        generation: Int,
        accountRecordName: String,
        epoch: UInt64
    ) -> Bool {
        let categoryIsValid: Bool
        switch category {
        case .episodes:
            categoryIsValid = episodesSyncEnabled && episodeApplyEpoch == epoch
        case .subscriptions:
            categoryIsValid = subscriptionsSyncEnabled && subscriptionApplyEpoch == epoch
        case .localCapture:
            categoryIsValid = false
        }
        return !isSignedOut
            && isAccountIdentityVerified
            && categoryIsValid
            && self.generation == generation
            && localCaptureAccountRecordName == accountRecordName
    }

    func verifiedAccountRecordNameForLocalCapture() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut else { return nil }
        return localCaptureAccountRecordName
    }

    func beginVerifiedAccountCapture(_ accountRecordName: String, generation: Int) {
        guard !accountRecordName.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation, !isSignedOut else { return }
        localCaptureAccountRecordName = accountRecordName
    }

    func currentGeneration(for syncEngine: CKSyncEngine) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut, isAccountIdentityVerified,
              engineIdentifier == ObjectIdentifier(syncEngine) else { return nil }
        return generation
    }

    func recordDeleteAttempts(_ revisionsByRecordName: [String: String],
                              generation: Int,
                              for syncEngine: CKSyncEngine) {
        guard !revisionsByRecordName.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut, isAccountIdentityVerified,
              self.generation == generation,
              engineIdentifier == ObjectIdentifier(syncEngine) else { return }
        for (recordName, revision) in revisionsByRecordName {
            var revisions = deleteAttemptRevisionsByRecordName[recordName] ?? []
            if revisions.last != revision {
                revisions.append(revision)
            }
            deleteAttemptRevisionsByRecordName[recordName] = revisions
        }
    }

    func pendingDeleteAttempt(for recordName: String, syncEngine: CKSyncEngine) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard engineIdentifier == ObjectIdentifier(syncEngine),
              let revisions = deleteAttemptRevisionsByRecordName[recordName],
              !revisions.isEmpty else { return nil }
        return revisions[0]
    }

    func acknowledgeDeleteAttempts(_ revisionsByRecordName: [String: String],
                                   generation: Int,
                                   for syncEngine: CKSyncEngine) {
        guard !revisionsByRecordName.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut, isAccountIdentityVerified,
              self.generation == generation,
              engineIdentifier == ObjectIdentifier(syncEngine) else { return }
        for (recordName, acknowledgedRevision) in revisionsByRecordName {
            guard var revisions = deleteAttemptRevisionsByRecordName[recordName],
                  revisions.first == acknowledgedRevision else { continue }
            revisions.removeFirst()
            if revisions.isEmpty {
                deleteAttemptRevisionsByRecordName.removeValue(forKey: recordName)
            } else {
                deleteAttemptRevisionsByRecordName[recordName] = revisions
            }
        }
    }

    func recordInitialUploadOutcome(resolvedRecordNames: [String],
                                    localReadFailed: Bool,
                                    localChangesDeferred: Bool = false,
                                    generation: Int,
                                    for syncEngine: CKSyncEngine) {
        guard !resolvedRecordNames.isEmpty || localReadFailed || localChangesDeferred else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut, isAccountIdentityVerified,
              self.generation == generation,
              engineIdentifier == ObjectIdentifier(syncEngine) else { return }
        resolvedInitialUploadRecordNames.formUnion(resolvedRecordNames)
        self.localUploadReadFailed = self.localUploadReadFailed || localReadFailed
        self.localChangesDeferred = self.localChangesDeferred || localChangesDeferred
    }

    func takeInitialUploadOutcome(generation: Int,
                                  for syncEngine: CKSyncEngine) -> (resolvedRecordNames: Set<String>, localReadFailed: Bool, localChangesDeferred: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut, isAccountIdentityVerified,
              self.generation == generation,
              engineIdentifier == ObjectIdentifier(syncEngine) else { return ([], false, false) }
        let outcome = (resolvedInitialUploadRecordNames, localUploadReadFailed, localChangesDeferred)
        resolvedInitialUploadRecordNames = []
        localUploadReadFailed = false
        localChangesDeferred = false
        return outcome
    }
}

@available(iOS 17.0, *)
@MainActor
@objcMembers final class ICiCloudSyncManager: NSObject, CKSyncEngineDelegate {
    @objc(sharedManager) static let shared = ICiCloudSyncManager()

    @objc static var isAvailable: Bool {
        if #available(iOS 17.0, *) {
            return true
        }
        return false
    }

    nonisolated static let containerIdentifier = "iCloud.com.iteconomy.instacastplus"
    nonisolated static let zoneName = "InstacastSync"
    nonisolated static let schemaVersion = 1

    nonisolated static let deviceIDKey = "ICiCloudSyncDeviceID"
    nonisolated static let installationDeviceIdentityKeychainService = "com.iteconomy.instacastplus.icloud-device-identity"
    nonisolated static let installationDeviceIdentityKeychainAccount = "current-installation"
    nonisolated static let installationDeviceMarkerFileName = "installationDeviceMarker"
    nonisolated static let installationDeviceIdentityLock = NSLock()
    nonisolated(unsafe) static var resolvedInstallationDeviceID: String?
    nonisolated static let engineStateKey = "ICiCloudSyncEngineState"
    nonisolated static let knownRecordsKey = "ICiCloudSyncKnownRecords"
    nonisolated static let deviceCacheKey = "ICiCloudSyncDeviceCache"
    nonisolated static let subscriptionRecordURLsKey = "ICiCloudSyncSubscriptionRecordURLs"
    nonisolated static let pendingEpisodeStatesKey = "ICiCloudSyncPendingEpisodeStates"
    nonisolated static let pendingSubscriptionPayloadsKey = "ICiCloudSyncPendingSubscriptionPayloads"
    nonisolated static let pendingSubscriptionFetchCompleteKey = "ICiCloudSyncPendingSubscriptionFetchComplete"
    nonisolated static let episodeLocalModifiedDatesKey = "ICiCloudSyncEpisodeLocalModifiedDates"
    nonisolated static let subscriptionLocalModifiedDatesKey = "ICiCloudSyncSubscriptionLocalModifiedDates"
    nonisolated static let subscriptionLocalStatesKey = "ICiCloudSyncSubscriptionLocalStates"
    nonisolated static let subscriptionPayloadHashesKey = "ICiCloudSyncSubscriptionPayloadHashes"
    nonisolated static let initialEpisodeBackfillOffsetKey = "ICiCloudSyncInitialEpisodeBackfillOffset"
    nonisolated static let initialSubscriptionBackfillOffsetKey = "ICiCloudSyncInitialSubscriptionBackfillOffset"
    nonisolated static let initialEpisodeBackfillCursorKey = "ICiCloudSyncInitialEpisodeBackfillCursor"
    nonisolated static let initialSubscriptionBackfillCursorKey = "ICiCloudSyncInitialSubscriptionBackfillCursor"
    nonisolated static let initialEpisodeBackfillCheckpointKey = "ICiCloudSyncInitialEpisodeBackfillCheckpoint"
    nonisolated static let initialSubscriptionBackfillCheckpointKey = "ICiCloudSyncInitialSubscriptionBackfillCheckpoint"
    nonisolated static let initialEpisodeBackfillAccountKey = "ICiCloudSyncInitialEpisodeBackfillAccount"
    nonisolated static let initialSubscriptionBackfillAccountKey = "ICiCloudSyncInitialSubscriptionBackfillAccount"
    nonisolated static let initialEpisodeBackfillTotalKey = "ICiCloudSyncInitialEpisodeBackfillTotal"
    nonisolated static let initialSubscriptionBackfillTotalKey = "ICiCloudSyncInitialSubscriptionBackfillTotal"
    nonisolated static let initialEpisodeBackfillTotalAccountKey = "ICiCloudSyncInitialEpisodeBackfillTotalAccount"
    nonisolated static let initialSubscriptionBackfillTotalAccountKey = "ICiCloudSyncInitialSubscriptionBackfillTotalAccount"
    nonisolated static let initialEpisodeBackfillCompletedAccountKey = "ICiCloudSyncInitialEpisodeBackfillCompletedAccount"
    nonisolated static let initialSubscriptionBackfillCompletedAccountKey = "ICiCloudSyncInitialSubscriptionBackfillCompletedAccount"
    nonisolated static let initialBackfillAccountMigrationCompletedKey = "ICiCloudSyncInitialBackfillAccountMigrationCompleted"
    nonisolated static let initialBackfillFetchBeforeUploadAccountKey = "ICiCloudSyncInitialBackfillFetchBeforeUploadAccount"
    nonisolated static let initialBackfillFetchBeforeUploadCategoriesKey = "ICiCloudSyncInitialBackfillFetchBeforeUploadCategories"
    nonisolated static let initialSettingsBackfillPendingKey = "ICiCloudSyncInitialSettingsBackfillPending"
    nonisolated static let pendingInitialSettingsPayloadKey = "ICiCloudSyncPendingInitialSettingsPayload"
    @objc static let initialSettingsChoiceNeededNotification = "ICiCloudSyncInitialSettingsChoiceNeeded"
    nonisolated static let settingsLocalModifiedDateKey = "ICiCloudSyncSettingsLocalModifiedDate"
    nonisolated static let settingsSyncedHashKey = "ICiCloudSyncSettingsSyncedHash"
    nonisolated static let suppressSubscriptionDeletionsKey = "ICiCloudSyncSuppressSubscriptionDeletions"
    nonisolated static let cloudInventoryKey = "ICiCloudSyncCloudInventory"
    nonisolated static let cloudInventoryPayloadScanCompletedKey = "ICiCloudSyncCloudInventoryPayloadScanCompleted"
    nonisolated static let knownRecordSystemFieldsPruneVersionsKey = "ICiCloudSyncKnownRecordSystemFieldsPruneVersions"
    nonisolated static let knownRecordSystemFieldsPruneVersion = 1
    nonisolated static let transitionalSubscriptionInventoryRecordsKey = "ICiCloudSyncTransitionalSubscriptionInventoryRecords"
    nonisolated static let subscriptionListSettingsLocalModifiedDateKey = "ICiCloudSyncSubscriptionListSettingsLocalModifiedDate"
    nonisolated static let subscriptionListSettingsBaselineKey = "ICiCloudSyncSubscriptionListSettingsBaseline"
    // Mirrors the file-private kManualFeedOrderKey in DatabaseManager.m.
    nonisolated static let manualFeedOrderDefaultsKey = "ManualFeedOrder"
    nonisolated static let scrollPositionsLocalModifiedDateKey = "ICiCloudSyncScrollPositionsLocalModifiedDate"
    nonisolated static let lastSyncDateKey = "ICiCloudSyncLastSyncDate"
    nonisolated static let lastStatusKey = "ICiCloudSyncLastStatus"
    nonisolated static let lastErrorKey = "ICiCloudSyncLastError"
    nonisolated static let localSubscriptionCleanupStatusKey =
        "ICiCloudSyncLocalSubscriptionCleanupStatus"
    nonisolated static let deviceRecordShouldStampSyncDateKey = "ICiCloudSyncDeviceRecordShouldStampSyncDate"
    nonisolated static let finalDeviceRecordUpdatePendingKey = "ICiCloudSyncFinalDeviceRecordUpdatePending"
    nonisolated static let pendingDeviceControlIntentsKey = "ICiCloudSyncPendingDeviceControlIntents"
    nonisolated static let pendingSingletonUploadIntentsKey = "ICiCloudSyncPendingSingletonUploadIntents"
    nonisolated static let singletonClockFloorsKey = "ICiCloudSyncSingletonClockFloors"
    nonisolated static let accountSignedOutKey = "ICiCloudSyncAccountSignedOut"
    nonisolated static let accountUserRecordNameKey = "ICiCloudSyncAccountUserRecordName"
    nonisolated static let accountResetRequiredKey = "ICiCloudSyncAccountResetRequired"
    nonisolated static let localOutboxHasVerifiedAccountKey = "ICiCloudSyncLocalOutboxHasVerifiedAccount"
    nonisolated static let localOutboxUnboundAccountRecordName = "__unbound__"
    nonisolated static let localOutboxPendingAccountRecordName = "__pending_account__"
    nonisolated static let localOutboxPendingScopeKey = "ICiCloudSyncLocalOutboxPendingScope"
    nonisolated static let localOutboxAwaitingAccountSwitchKey = "ICiCloudSyncLocalOutboxAwaitingAccountSwitch"
    nonisolated static let episodesSyncHasParticipatedKey = "ICiCloudSyncEpisodesHasParticipated"
    nonisolated static let subscriptionsSyncHasParticipatedKey = "ICiCloudSyncSubscriptionsHasParticipated"
    nonisolated static let localOutboxEntityName = "ICCloudSyncOutboxEntry"
    nonisolated static let pendingEpisodeStateEntityName = "ICCloudPendingEpisodeState"
    nonisolated static let pendingSubscriptionStateEntityName = "ICCloudPendingSubscriptionState"
    nonisolated static let localOutboxEpisodeCategory = "episode"
    nonisolated static let localOutboxSubscriptionCategory = "subscription"
    nonisolated static let localOutboxSubscriptionListSettingsCategory = "subscriptionListSettings"
    nonisolated static let subscriptionListSettingsDirtyMarkerPayloadKey = "requiresCommittedSnapshot"
    nonisolated static var subscriptionListSettingsDirtyMarkerPayload: [String: Any] {
        [subscriptionListSettingsDirtyMarkerPayloadKey: true]
    }
    nonisolated static let localOutboxSaveOperation = "save"
    nonisolated static let localOutboxDeleteOperation = "delete"
    nonisolated static let localMutationRevisionPayloadKey = "_icLocalMutationRevision"
    // CloudKit accepts at most 250 saves + deletes per request. CKSyncEngine can request
    // several of these bounded batches during one sendChanges() call.
    nonisolated static let maximumRecordZoneChangesPerBatch = 250
    nonisolated static let pendingChangeQueueChunkSize = 250
    nonisolated static let initialUploadPreparedPageWindowSize = 4
    nonisolated static let remoteApplyBatchSize = 100
    nonisolated static let startupCleanupProtectionBatchSize = 64
    nonisolated static let syncMetadataDirectoryName = "iCloudSyncMetadata"
    nonisolated static let legacyKnownRecordSystemFieldsDirectoryName = "KnownRecords"
    nonisolated static let legacySyncItemMetadataErrorDomain = "ICiCloudSyncLegacyMetadata"

    nonisolated static var fileBackedSyncMetadataKeys: Set<String> {
        [
            Self.engineStateKey,
            Self.knownRecordsKey,
            Self.accountResetRequiredKey,
            Self.finalDeviceRecordUpdatePendingKey,
            Self.pendingDeviceControlIntentsKey,
            Self.pendingSingletonUploadIntentsKey,
            Self.singletonClockFloorsKey,
            Self.deviceCacheKey,
            Self.pendingEpisodeStatesKey,
            Self.pendingSubscriptionPayloadsKey,
            Self.pendingSubscriptionFetchCompleteKey,
            Self.transitionalSubscriptionInventoryRecordsKey,
        ]
    }

    enum RecordKind {
        static let device = "ICDevice"
        static let episodeState = "ICEpisodeState"
        static let subscription = "ICSubscription"
        static let subscriptionTombstone = "ICSubscriptionTombstone"
        static let appSettings = "ICAppSettings"
        static let listScrollPositions = "ICListScrollPositions"
        static let subscriptionListSettings = "ICSubscriptionListSettings"
    }

    enum RecordPrefix {
        static let device = "device_"
        static let episode = "episode_"
        static let subscription = "subscription_"
        static let subscriptionTombstone = "subscriptionTombstone_"
        static let appSettings = "settings_app"
        static let listScrollPositions = "settings_listScrollPositions"
        static let subscriptionListSettings = "settings_subscriptionList"
    }

    struct PendingSingletonUploadIntent: Sendable {
        let recordName: String
        let accountRecordName: String
        let revision: String
        let sequence: Int64
        let modifiedAt: Date
        let payloadData: Data?

        func payloadDictionary() -> [String: Any]? {
            guard let payloadData else { return nil }
            return (try? PropertyListSerialization.propertyList(
                from: payloadData,
                options: [],
                format: nil
            )) as? [String: Any]
        }
    }

    struct PendingDeviceControlIntent: Sendable {
        let accountRecordName: String
        let targetDeviceID: String
        let operation: String
        let revision: String
        let payloadData: Data?
        let pendingCleanupDeviceIDs: [String]
        let createdAt: Date

        func payloadDictionary() -> [String: Any]? {
            guard let payloadData else { return nil }
            return (try? PropertyListSerialization.propertyList(
                from: payloadData,
                options: [],
                format: nil
            )) as? [String: Any]
        }
    }

    let defaults = UserDefaults.standard
    let container = CKContainer(identifier: ICiCloudSyncManager.containerIdentifier)
    let zoneID = CKRecordZone.ID(zoneName: ICiCloudSyncManager.zoneName)
    nonisolated static let sharedSyncEngineCallbackGate = ICiCloudSyncEngineCallbackGate()
    nonisolated var syncEngineCallbackGate: ICiCloudSyncEngineCallbackGate {
        Self.sharedSyncEngineCallbackGate
    }
    nonisolated let remoteOriginGate = ICiCloudRemoteEpisodeOriginGate()
    nonisolated let remoteSubscriptionOriginGate = ICiCloudRemoteEpisodeOriginGate()
    nonisolated static let sharedRemoteEpisodeClockGate = ICiCloudRemoteEpisodeClockGate()
    nonisolated var remoteEpisodeClockGate: ICiCloudRemoteEpisodeClockGate {
        Self.sharedRemoteEpisodeClockGate
    }
    var syncEngine: CKSyncEngine?
    var isStarted = false
    var isDeletingAllICloudData = false
    var isApplyingRemoteChange = false
    var isWritingSyncMetadata = false
    var hasUnresolvedSyncFailures = false
    var requiresSyncEngineStateRollbackAfterPersistenceFailure = false
    var settingsDebounceWorkItem: DispatchWorkItem?
    var settingsChangeCheckRevision: UInt64 = 0
    var scrollDebounceWorkItem: DispatchWorkItem?
    var applyPendingDebounceWorkItem: DispatchWorkItem?
    var cachedSyncTotalCounts: (episodes: Int, subscriptions: Int, settings: Int, timestamp: Date)?
    var isRefreshingSyncTotalCounts = false
    // Object IDs that were just mutated by applying remote records. The objects-did-change
    // notification for those mutations arrives in batches (at processPendingChanges time),
    // possibly only after the whole fetch-apply pass is over — a time-window flag like
    // `isApplyingRemoteChange` cannot tell remote applies from genuine local edits there,
    // which systematically echoed the last batch of every fetch back up (with a fresh
    // `updatedAt`, weakening last-writer-wins). Only IDs whose apply REALLY changed a value
    // are recorded, and each ID absolves exactly one observer pass, so a later genuine
    // local edit of the same object still syncs.
    var remoteAppliedObjectIDs: Set<NSManagedObjectID> = []
    // Successful saves can be returned by the following zone fetch. Track only records
    // acknowledged by this running process so their identical echo does not get applied
    // to Core Data again. This is intentionally in-memory: after a relaunch or local reset,
    // CloudKit remains authoritative and records must be applied normally.
    var recentlyUploadedRecordVersions: [String: String] = [:]
    var lastForegroundSyncDate: Date?
    var didPruneEpisodeLocalModifiedDates = false
    var isApplyingPendingSubscriptions = false
    var isFetchingCloudInventory = false
    var cloudInventoryRefreshGeneration: UInt64 = 0
    var cloudInventoryCancellationToken: ICCloudInventoryCancellationToken?
    var cloudInventoryOperation: CKFetchRecordZoneChangesOperation?
    private(set) var cloudInventoryRefreshErrorText: String?
    var cloudInventoryRefreshInProgress: Bool { isFetchingCloudInventory }
    var pendingCloudInventoryRefreshReason: String?
    var requestedCloudInventoryRefreshReason: String?
    var requestedCloudInventoryRefreshMustRun = false
    var cloudAccountGeneration = 0
    var isICloudAccountSignedOut = UserDefaults.standard.bool(forKey: ICiCloudSyncManager.accountSignedOutKey)
    var isICloudAccountIdentityVerified = false
    var isHydratingStubFeeds = false
    var hydrationCompletedCount = 0
    var hydrationTotalCount = 0
    var hydrationFailedFeedIDs: Set<NSManagedObjectID> = []
    var isWaitingForEpisodeLoader = false
    var episodeLoaderWaitingFeedID: NSManagedObjectID?
    var needsSubscriptionListSortApply = false
    var pendingInitialUploadBatches: [InitialUploadBatch] = []
    var isPreparingInitialUploadPage = false
    var initialQueueTask: Task<Void, Never>?
    var initialQueueTaskGeneration = 0
    var lowPrioritySyncTask: Task<Void, Never>?
    var accountVerificationTask: Task<Void, Never>?
    var manualSyncTask: Task<Void, Never>?
    var backgroundSyncTask: Task<Void, Never>?
    var finalDeviceRecordUpdateTask: Task<Void, Never>?
    var startupCleanupProtectionTask: Task<NSError?, Never>?
    var startupRecoveryTask: Task<Void, Never>?
    var startupRecoveryTaskIdentifier: UUID?
    var localAppResetSyncOptions: (episodes: Bool, subscriptions: Bool, settings: Bool)?
    var foregroundSyncTask: Task<Void, Never>?
    var foregroundSyncTaskIdentifier: UUID?
    var requiresImmediateFinalDeviceRecordResend = false
    var requiresImmediateSingletonRecordResend = false
    var isICloudAccountTransitionRunning = false
    var iCloudAccountTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    var iCloudAccountTransitionToken = 0
    var localCredentialReplayTask: Task<Bool, Never>?
    var localSubscriptionCommitTasks: [UUID: Task<Void, Never>] = [:]
    var localSubscriptionCleanupTask: Task<ICCloudSubscriptionCleanupDrainResult, Never>?
    var localSubscriptionCleanupTaskIdentifier: UUID?
    var localSubscriptionCleanupRequestedGeneration: UInt64 = 0
    var localSubscriptionCleanupCompletedGeneration: UInt64 = 0
    var localSubscriptionCleanupEpoch: UInt64 = 0
    var localOutboxDrainTask: Task<Void, Never>?
    var localOutboxDrainRequested = false
    var localOutboxBatchDepth = 0
    var localOutboxDrainDeferred = false
    var localOutboxSnapshotCache: [String: ICCloudSyncOutboxSnapshot] = [:]
    var localOutboxRevisionsToDelete: [String: String] = [:]
    var localOutboxRevisionsToAcknowledge: [String: String] = [:]
    var localOutboxRevisionsToRearm: [String: String] = [:]
    var finalDeviceRecordUpdateGeneration = 0
    var activeSyncCycleCounts: [Int: Int] = [:]
    var activeSyncCycleCount: Int { activeSyncCycleCounts[cloudAccountGeneration] ?? 0 }
    var isPerformingManualSync = false
    var syncRetryAttempt = 0
    var syncRetryWorkItem: DispatchWorkItem?
    var syncRetryRequiresAccountVerification = false
    var syncRetryGeneration = 0
    enum SyncActivityDirection { case up, down, verifying }
    var syncActivityDirection: SyncActivityDirection?
    var syncActivityRecordCount = 0
    var deviceRecordShouldStampSyncDate = false
    var syncedUserDataInCurrentRun = false

    var databaseManager: DatabaseManager {
        DatabaseManager.shared()!
    }

    var subscriptionManager: SubscriptionManager {
        SubscriptionManager.shared()!
    }

    @objc var episodesSyncEnabled: Bool {
        defaults.bool(forKey: ICiCloudSyncEpisodesEnabled)
    }

    @objc var subscriptionsSyncEnabled: Bool {
        defaults.bool(forKey: ICiCloudSyncSubscriptionsEnabled)
    }

    @objc var settingsSyncEnabled: Bool {
        defaults.bool(forKey: ICiCloudSyncSettingsEnabled)
    }

    @objc var anySyncEnabled: Bool {
        episodesSyncEnabled || subscriptionsSyncEnabled || settingsSyncEnabled
    }

    var hasPendingLegacyFinalDeviceRecordUpdate: Bool {
        (Self.syncMetadataValue(forKey: Self.finalDeviceRecordUpdatePendingKey) as? NSNumber)?.boolValue == true
    }

    var hasPendingDeviceControlIntents: Bool {
        let intents = Self.pendingDeviceControlIntents()
        guard isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else {
            return hasPendingLegacyFinalDeviceRecordUpdate || !intents.isEmpty
        }
        return hasPendingLegacyFinalDeviceRecordUpdate
            || intents.contains { $0.accountRecordName == accountRecordName }
    }

    var hasPendingFinalDeviceRecordUpdate: Bool {
        hasPendingDeviceControlIntents
    }

    var isCheckingInitialCloudSettings: Bool {
        settingsSyncEnabled
            && defaults.bool(forKey: Self.initialSettingsBackfillPendingKey)
            && !hasPendingInitialSettingsChoice
    }

    @objc var syncInProgress: Bool {
        guard anySyncEnabled || hasPendingFinalDeviceRecordUpdate else { return false }
        let hasVisibleError = defaults.string(forKey: Self.lastErrorKey)?.isEmpty == false
        return activeSyncCycleCount > 0
            || accountVerificationTask != nil
            || manualSyncTask != nil
            || backgroundSyncTask != nil
            || isPerformingManualSync
            || lowPrioritySyncTask != nil
            || isApplyingRemoteChange
            || syncActivityDirection != nil
            || (!isICloudAccountIdentityVerified && !hasVisibleError)
            || (hasInitialUploadBackfillWork && !hasVisibleError)
            || (isCheckingInitialCloudSettings && !hasVisibleError)
    }

    @objc var lastSyncDate: Date? {
        defaults.object(forKey: Self.lastSyncDateKey) as? Date
    }

    @objc var syncCounts: ICiCloudSyncCounts {
        let totals = syncTotalCounts()
        let episodeTotal = episodesSyncEnabled
            ? (initialEpisodeBackfillFrozenTotal ?? totals.episodes)
            : 0
        let subscriptionTotal = subscriptionsSyncEnabled
            ? (initialSubscriptionBackfillFrozenTotal ?? totals.subscriptions)
            : 0
        return ICiCloudSyncCounts(
            episodesSynced: episodesSyncEnabled ? syncedCount(
                backfillKey: Self.initialEpisodeBackfillOffsetKey,
                checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
                total: episodeTotal,
                acknowledgedCount: acknowledgedInitialUploadCount(episodes: true)
            ) : 0,
            episodesTotal: episodeTotal,
            subscriptionsSynced: subscriptionsSyncEnabled ? syncedCount(
                backfillKey: Self.initialSubscriptionBackfillOffsetKey,
                checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
                total: subscriptionTotal,
                acknowledgedCount: acknowledgedInitialUploadCount(episodes: false)
            ) : 0,
            subscriptionsTotal: subscriptionTotal,
            settings: settingsSyncEnabled ? totals.settings : 0,
            countsAvailable: cachedSyncTotalCounts != nil
                || initialEpisodeBackfillFrozenTotal != nil
                || initialSubscriptionBackfillFrozenTotal != nil)
    }

    var initialEpisodeBackfillFrozenTotal: Int? {
        frozenInitialBackfillTotal(
            backfillKey: Self.initialEpisodeBackfillOffsetKey,
            checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
            totalKey: Self.initialEpisodeBackfillTotalKey,
            accountKey: Self.initialEpisodeBackfillTotalAccountKey
        )
    }

    var initialSubscriptionBackfillFrozenTotal: Int? {
        frozenInitialBackfillTotal(
            backfillKey: Self.initialSubscriptionBackfillOffsetKey,
            checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
            totalKey: Self.initialSubscriptionBackfillTotalKey,
            accountKey: Self.initialSubscriptionBackfillTotalAccountKey
        )
    }

    func frozenInitialBackfillTotal(
        backfillKey: String,
        checkpointKey: String,
        totalKey: String,
        accountKey: String
    ) -> Int? {
        guard isICloudAccountIdentityVerified,
              hasStoredInitialBackfill(checkpointKey: checkpointKey, offsetKey: backfillKey),
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              defaults.string(forKey: accountKey) == accountRecordName,
              let total = (defaults.object(forKey: totalKey) as? NSNumber)?.intValue else {
            return nil
        }
        return max(0, total)
    }

    // How many of `total` are already synced: the durable cursor covers complete pages,
    // while the in-memory acknowledgement count makes partial CloudKit batches visible.
    // Once the cursor is cleared, the whole set is synced.
    func syncedCount(
        backfillKey: String,
        checkpointKey: String,
        total: Int,
        acknowledgedCount: Int
    ) -> Int {
        guard let offset = storedInitialBackfillOffset(
            checkpointKey: checkpointKey,
            offsetKey: backfillKey
        ) else {
            return total
        }
        return min(max(offset + acknowledgedCount, 0), total)
    }

    func storedInitialBackfillOffset(checkpointKey: String, offsetKey: String) -> Int? {
        if let checkpoint = defaults.dictionary(forKey: checkpointKey),
           let offset = (checkpoint["offset"] as? NSNumber)?.intValue {
            return max(0, offset)
        }
        return (defaults.object(forKey: offsetKey) as? NSNumber)?.intValue
    }

    func hasStoredInitialBackfill(checkpointKey: String, offsetKey: String) -> Bool {
        storedInitialBackfillOffset(checkpointKey: checkpointKey, offsetKey: offsetKey) != nil
    }

    var initialBackfillFetchBeforeUploadCategories: Set<String> {
        Set(defaults.stringArray(forKey: Self.initialBackfillFetchBeforeUploadCategoriesKey) ?? [])
    }

    var requiresInitialBackfillFetchBeforeUpload: Bool {
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              defaults.string(forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
                == accountRecordName else {
            return false
        }
        let categories = initialBackfillFetchBeforeUploadCategories
        return (categories.contains("episodes") && episodesSyncEnabled)
            || (categories.contains("subscriptions") && subscriptionsSyncEnabled)
    }

    func prepareInitialEpisodeFetchBeforeUploadIfNeeded(accountRecordName: String) {
        guard !accountRecordName.isEmpty,
              defaults.string(forKey: Self.initialEpisodeBackfillCompletedAccountKey)
                != accountRecordName else { return }
        let resumesPreparedBackfill = defaults.string(forKey: Self.initialEpisodeBackfillAccountKey)
                == accountRecordName
            && hasStoredInitialBackfill(
                checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
                offsetKey: Self.initialEpisodeBackfillOffsetKey
            )
        guard !resumesPreparedBackfill else { return }

        var categories = defaults.string(forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
                == accountRecordName
            ? initialBackfillFetchBeforeUploadCategories
            : []
        categories.insert("episodes")
        defaults.set(categories.sorted(), forKey: Self.initialBackfillFetchBeforeUploadCategoriesKey)
        defaults.set(accountRecordName, forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
    }

    func completeInitialBackfillFetchBeforeUploadIfNeeded() {
        guard requiresInitialBackfillFetchBeforeUpload,
              !hasUnresolvedSyncFailures else { return }
        var categories = initialBackfillFetchBeforeUploadCategories
        if episodesSyncEnabled,
           hasStoredInitialBackfill(
            checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
            offsetKey: Self.initialEpisodeBackfillOffsetKey
           ) {
            categories.remove("episodes")
        }
        if subscriptionsSyncEnabled,
           hasStoredInitialBackfill(
            checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
            offsetKey: Self.initialSubscriptionBackfillOffsetKey
           ) {
            categories.remove("subscriptions")
        }
        if categories.isEmpty {
            defaults.removeObject(forKey: Self.initialBackfillFetchBeforeUploadCategoriesKey)
            defaults.removeObject(forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
        } else {
            defaults.set(categories.sorted(), forKey: Self.initialBackfillFetchBeforeUploadCategoriesKey)
        }
        scheduleCurrentEnabledDataForUpload()
    }

    func fetchChangesForInitialBackfillMigration(_ syncEngine: CKSyncEngine) async throws {
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        try await syncEngine.fetchChanges()
    }

    func acknowledgedInitialUploadCount(episodes: Bool) -> Int {
        pendingInitialUploadBatches.reduce(0) { result, batch in
            if episodes {
                guard batch.hasEpisodeBackfill else { return result }
                return result + max(batch.episodeRecordCount - batch.episodeRecordNames.count, 0)
            }
            guard batch.hasSubscriptionBackfill else { return result }
            // Each logical subscription resolves two CloudKit changes: save the active
            // record and delete its inverse tombstone. Pair them by feed identity: two
            // acknowledgements from different feeds must not combine into one completed feed.
            let unresolvedSubscriptionIdentities = Set(batch.subscriptionRecordNames.compactMap {
                recordName -> String? in
                if recordName.hasPrefix(RecordPrefix.subscriptionTombstone) {
                    return String(recordName.dropFirst(RecordPrefix.subscriptionTombstone.count))
                }
                if recordName.hasPrefix(RecordPrefix.subscription) {
                    return String(recordName.dropFirst(RecordPrefix.subscription.count))
                }
                return nil
            })
            return result + max(
                batch.subscriptionRecordCount - unresolvedSubscriptionIdentities.count,
                0
            )
        }
    }

    // Stable totals of what's kept in iCloud, counted directly in Core Data so the number is
    // the real total (e.g. "4490 episodes with play state") instead of a sync-progress figure.
    // The count itself runs on a BACKGROUND context — never the main thread — because a
    // count on the main context can block for seconds waiting on the SQLite store lock that
    // the background backfill/refresh holds (this was a multi-second UI freeze when toggling a
    // switch). The UI shows the last computed value and refreshes when a new one is ready.
    func syncTotalCounts() -> (episodes: Int, subscriptions: Int, settings: Int) {
        let cached = cachedSyncTotalCounts
        if hasInitialUploadBackfillWork {
            return (
                initialEpisodeBackfillFrozenTotal ?? cached?.episodes ?? 0,
                initialSubscriptionBackfillFrozenTotal ?? cached?.subscriptions ?? 0,
                cached?.settings ?? 0
            )
        }
        // 15 s TTL: the settings screen reloads on a 10 s timer plus every state change;
        // a 2 s TTL re-ran the COUNT queries (a full episode-table scan) almost every time.
        if cached == nil || Date().timeIntervalSince(cached!.timestamp) >= 15.0 {
            refreshSyncTotalCountsInBackground()
        }
        return (cached?.episodes ?? 0, cached?.subscriptions ?? 0, cached?.settings ?? 0)
    }

    func refreshSyncTotalCountsInBackground() {
        guard !isRefreshingSyncTotalCounts else { return }
        isRefreshingSyncTotalCounts = true
        let episodesEnabled = episodesSyncEnabled
        let subscriptionsEnabled = subscriptionsSyncEnabled
        let settingsEnabled = settingsSyncEnabled
        Task.detached(priority: .utility) { [weak self] in
            do {
                let counts = try await Self.computeSyncTotalCounts(
                    episodesEnabled: episodesEnabled,
                    subscriptionsEnabled: subscriptionsEnabled,
                    settingsEnabled: settingsEnabled
                )
                await MainActor.run {
                    guard let self else { return }
                    guard episodesEnabled == self.episodesSyncEnabled,
                          subscriptionsEnabled == self.subscriptionsSyncEnabled,
                          settingsEnabled == self.settingsSyncEnabled else {
                        self.isRefreshingSyncTotalCounts = false
                        self.refreshSyncTotalCountsInBackground()
                        return
                    }
                    self.cachedSyncTotalCounts = (counts.episodes, counts.subscriptions, counts.settings, Date())
                    self.captureInitialBackfillTotalsIfNeeded(
                        episodes: counts.episodes,
                        subscriptions: counts.subscriptions
                    )
                    self.isRefreshingSyncTotalCounts = false
                    self.postStateChanged()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isRefreshingSyncTotalCounts = false
                    guard episodesEnabled == self.episodesSyncEnabled,
                          subscriptionsEnabled == self.subscriptionsSyncEnabled,
                          settingsEnabled == self.settingsSyncEnabled else {
                        self.refreshSyncTotalCountsInBackground()
                        return
                    }
                    self.handleLocalPersistenceFailure(error)
                }
            }
        }
    }

    func captureInitialBackfillTotalsFromCachedCountsIfNeeded() {
        guard let cachedSyncTotalCounts else {
            refreshSyncTotalCountsInBackground()
            return
        }
        captureInitialBackfillTotalsIfNeeded(
            episodes: cachedSyncTotalCounts.episodes,
            subscriptions: cachedSyncTotalCounts.subscriptions
        )
    }

    func captureInitialBackfillTotalsIfNeeded(episodes: Int, subscriptions: Int) {
        guard isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else { return }
        if episodesSyncEnabled,
           hasStoredInitialBackfill(
            checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
            offsetKey: Self.initialEpisodeBackfillOffsetKey
           ) {
            persistInitialBackfillTotalIfNeeded(
                episodes,
                totalKey: Self.initialEpisodeBackfillTotalKey,
                accountKey: Self.initialEpisodeBackfillTotalAccountKey,
                accountRecordName: accountRecordName
            )
        }
        if subscriptionsSyncEnabled,
           hasStoredInitialBackfill(
            checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
            offsetKey: Self.initialSubscriptionBackfillOffsetKey
           ) {
            persistInitialBackfillTotalIfNeeded(
                subscriptions,
                totalKey: Self.initialSubscriptionBackfillTotalKey,
                accountKey: Self.initialSubscriptionBackfillTotalAccountKey,
                accountRecordName: accountRecordName
            )
        }
    }

    func persistInitialBackfillTotalIfNeeded(
        _ total: Int,
        totalKey: String,
        accountKey: String,
        accountRecordName: String
    ) {
        guard defaults.string(forKey: accountKey) != accountRecordName
                || defaults.object(forKey: totalKey) == nil else { return }
        // The account marker is the commit marker. If the process stops between these
        // writes, the next run sees no matching marker and safely captures the total again.
        defaults.removeObject(forKey: accountKey)
        defaults.set(max(0, total), forKey: totalKey)
        defaults.set(accountRecordName, forKey: accountKey)
    }

    nonisolated static func computeSyncTotalCounts(episodesEnabled: Bool, subscriptionsEnabled: Bool, settingsEnabled: Bool) async throws -> (episodes: Int, subscriptions: Int, settings: Int) {
        // The settings count copies and filters the whole defaults domain — do that here,
        // off the main thread, together with the Core Data counts.
        let settings = settingsEnabled ? syncedSettingsValueCount() : 0
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw NSError(
                domain: "ICiCloudSyncCount",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Der lokale iCloud-Zählerspeicher konnte nicht geöffnet werden."]
            )
        }
        return try await context.perform {
            var episodes = 0
            var subscriptions = 0
            if episodesEnabled {
                let request = NSFetchRequest<NSDictionary>(entityName: "Episode")
                request.resultType = .dictionaryResultType
                request.includesSubentities = false
                request.propertiesToFetch = ["objectHash"]
                request.returnsDistinctResults = true
                request.predicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND objectHash != nil AND (consumed == YES OR starred == YES OR position > 0)")
                episodes = try context.fetch(request).count
            }
            if subscriptionsEnabled {
                let request = NSFetchRequest<NSDictionary>(entityName: "Feed")
                request.resultType = .dictionaryResultType
                request.includesSubentities = false
                request.propertiesToFetch = ["sourceURL_"]
                request.returnsDistinctResults = true
                request.predicate = NSPredicate(format: "subscribed == YES AND sourceURL_ != nil")
                subscriptions = try context.fetch(request).count
            }
            return (episodes, subscriptions, settings)
        }
    }

    nonisolated static func syncedSettingsValueCount() -> Int {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier.flatMap { defaults.persistentDomain(forName: $0) } ?? [:]
        var count = 0
        for (key, value) in domain where shouldSyncSettingsKeyForSyncEngineCallback(key) && isValidSettingsValueForSyncEngineCallback(value) {
            count += 1
        }
        return count
    }

    @objc var statusText: String {
        if let cleanupStatus = defaults.string(
            forKey: Self.localSubscriptionCleanupStatusKey
        ), !cleanupStatus.isEmpty {
            return cleanupStatus
        }
        if !anySyncEnabled {
            guard hasPendingFinalDeviceRecordUpdate else {
                return NSLocalizedString("Aus", comment: "")
            }
            if let error = defaults.string(forKey: Self.lastErrorKey), !error.isEmpty {
                return error
            }
            return NSLocalizedString("iCloud prüfen…", comment: "")
        }
        if let error = defaults.string(forKey: Self.lastErrorKey), !error.isEmpty {
            return error
        }
        if hasPendingInitialSettingsChoice {
            return NSLocalizedString("Choose which iCloud settings should be used.", comment: "")
        }
        if requiresInitialBackfillFetchBeforeUpload {
            return NSLocalizedString("Vorhandene iCloud-Daten werden vor dem Hochladen geprüft…", comment: "")
        }
        // The cursor advances only after CloudKit acknowledges a complete page. Compute
        // this text live so every acknowledgement moves the same monotone X / Y display;
        // a saved string stayed at 0 / Y until the entire upload suddenly completed.
        if hasInitialUploadBackfillWork {
            return backfillProgressStatusText()
        }
        if isCheckingInitialCloudSettings {
            return NSLocalizedString("Prüft, ob in iCloud bereits Einstellungen vorhanden sind…", comment: "")
        }
        if let activity = syncActivityStatusText() {
            return activity
        }
        if isHydratingStubFeeds, hydrationTotalCount > 0 {
            return String(format: NSLocalizedString("Lade Podcast-Folgen… %ld/%ld", comment: ""), hydrationCompletedCount, hydrationTotalCount)
        }
        if let status = defaults.string(forKey: Self.lastStatusKey), !status.isEmpty {
            return status
        }
        return NSLocalizedString("Bereit", comment: "")
    }

    @objc var devices: [ICiCloudSyncDeviceInfo] {
        let currentDeviceID = deviceID
        let currentDevicePayload = localDevicePayload()
        return deviceCache().compactMap { key, value in
            let value = key == currentDeviceID
                ? value.merging(currentDevicePayload ?? [:]) { _, current in current }
                : value
            guard deviceParticipates(value) else { return nil }
            let name = value["name"] as? String ?? NSLocalizedString("Unbekanntes Gerät", comment: "")
            let model = value["model"] as? String ?? ""
            let systemVersion = value["systemVersion"] as? String ?? ""
            let appVersion = value["appVersion"] as? String ?? ""
            let lastSyncDate = value["lastSyncDate"] as? Date
            return ICiCloudSyncDeviceInfo(deviceID: key,
                                          name: name,
                                          model: model,
                                          systemVersion: systemVersion,
                                          appVersion: appVersion,
                                          lastSyncDate: lastSyncDate,
                                          episodesEnabled: (value["episodesEnabled"] as? Bool) ?? false,
                                          subscriptionsEnabled: (value["subscriptionsEnabled"] as? Bool) ?? false,
                                          settingsEnabled: (value["settingsEnabled"] as? Bool) ?? false,
                                          isCurrentDevice: key == currentDeviceID)
        }.sorted { first, second in
            if first.isCurrentDevice != second.isCurrentDevice {
                return first.isCurrentDevice
            }
            let firstDate = first.lastSyncDate ?? Date(timeIntervalSince1970: 0)
            let secondDate = second.lastSyncDate ?? Date(timeIntervalSince1970: 0)
            return firstDate.compare(secondDate) == .orderedDescending
        }
    }

    override init() {
        super.init()
    }

    @objc nonisolated static func logSyncMetadataStorageSnapshot(_ reason: String) {
        Task.detached(priority: .utility) {
            let metadata = syncMetadataStorageSnapshot(reason: reason)
            ICDiagnosticLogger.shared.logEvent("icloud-sync-metadata",
                                               message: "iCloud-Sync-Metadaten-Snapshot",
                                               metadata: metadata as NSDictionary)
        }
    }

    @objc func start() {
        guard !isStarted else { return }
        isStarted = true

        discardStaleICloudAccountEngineStateIfNeeded()

        let hasLegacyEpisodeSyncState = Self.hasLegacyEpisodeSyncItemMetadata()
        let hasLegacySubscriptionSyncState = Self.hasLegacySubscriptionSyncItemMetadata()
        if episodesSyncEnabled || hasLegacyEpisodeSyncState {
            defaults.set(true, forKey: Self.episodesSyncHasParticipatedKey)
        }
        if subscriptionsSyncEnabled || hasLegacySubscriptionSyncState {
            defaults.set(true, forKey: Self.subscriptionsSyncHasParticipatedKey)
        }
        // The account ID persisted from a previous process is not session verification.
        // Arm a transition-specific scope before observing edits so a cold start with all
        // sync categories off cannot journal resets/tombstones under a stale Apple ID.
        if defaults.bool(forKey: Self.localOutboxHasVerifiedAccountKey)
            || defaults.bool(forKey: Self.localOutboxAwaitingAccountSwitchKey) {
            ensurePendingLocalOutboxScope()
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(defaultsDidChange(_:)), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(coreDataDidChange(_:)), name: .NSManagedObjectContextObjectsDidChange, object: databaseManager.objectContext)
        center.addObserver(self, selector: #selector(coreDataDidSave(_:)), name: .NSManagedObjectContextDidSave, object: databaseManager.objectContext)
        center.addObserver(self, selector: #selector(listScrollPositionsDidChange(_:)), name: NSNotification.Name.ICListScrollPositionsDidChange, object: nil)
        center.addObserver(self, selector: #selector(episodesWereAdded(_:)), name: NSNotification.Name.SubscriptionManagerDidAddEpisodes, object: nil)
        center.addObserver(self, selector: #selector(episodeLoadingDidFinish(_:)), name: NSNotification.Name.EpisodeLoadingManagerDidFinishLoading, object: nil)
        center.addObserver(self, selector: #selector(episodeLoadingDidFail(_:)), name: NSNotification.Name.EpisodeLoadingManagerDidFailLoading, object: nil)
        center.addObserver(self, selector: #selector(episodeLoadingDidCancel(_:)), name: NSNotification.Name.EpisodeLoadingManagerDidCancelLoading, object: nil)

        startPostInitializationRecoveryLifecycle()
    }

    func startPostInitializationRecoveryLifecycle() {
        guard isStarted, startupRecoveryTask == nil else { return }
        let startupEpoch = localSubscriptionCleanupEpoch
        let cleanupProtectionTask = Task { @MainActor [weak self] () -> NSError? in
            guard let self else { return Self.localSubscriptionCleanupCancellationError() }
            do {
                try await self.protectPendingSubscriptionCleanupAutoDownloads()
                return nil
            } catch {
                return error as NSError
            }
        }
        startupCleanupProtectionTask = cleanupProtectionTask
        let taskIdentifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if startupRecoveryTaskIdentifier == taskIdentifier {
                    startupRecoveryTask = nil
                    startupRecoveryTaskIdentifier = nil
                }
            }
            let protectionError = await cleanupProtectionTask.value
            self.startupCleanupProtectionTask = nil
            guard startupEpoch == localSubscriptionCleanupEpoch, isStarted else { return }
            if let protectionError {
                handleLocalSubscriptionCleanupFailure(protectionError)
                return
            }
            if let error = await self.drainPendingSubscriptionCleanupIntentsIfNeeded() {
                self.handleLocalSubscriptionCleanupFailure(error)
            }
            guard startupEpoch == localSubscriptionCleanupEpoch, isStarted else { return }
            _ = await self.resolvePendingLocalCredentialIntentsIfNeeded()
            guard startupEpoch == localSubscriptionCleanupEpoch, self.isStarted else { return }

            if self.anySyncEnabled || self.hasPendingDeviceControlIntents {
                self.initializeSyncEngineIfNeeded()
                if self.anySyncEnabled {
                    self.queueDeviceRecordForPendingUserDataIfNeeded()
                    if self.hasInitialUploadBackfillWork,
                       !self.isICloudAccountSignedOut,
                       self.isICloudAccountIdentityVerified {
                        self.scheduleCurrentEnabledDataForUpload()
                    }
                    // Retry payloads that arrived before their episode/feed existed locally and
                    // whose normal trigger (new episodes added) didn't fire again before the app
                    // was quit — without this they could sit in the pending store indefinitely.
                    self.scheduleApplyPendingPayloads()
                    // Publishes the sort mode/settings if their fingerprint baseline is missing
                    // (devices that enabled subscription sync before this record type existed).
                    self.scheduleSettingsChangeCheck()
                    self.hydrateStubFeedsIfNeeded()
                }
                await self.refreshAccountStatus()
                guard startupEpoch == localSubscriptionCleanupEpoch,
                      self.isStarted,
                      self.isICloudAccountIdentityVerified else { return }
                self.resumePendingDeviceControlIntentsForVerifiedAccount()
                if self.anySyncEnabled {
                    await self.continueEnabledSyncAfterAccountVerification()
                }
            }
        }
        startupRecoveryTaskIdentifier = taskIdentifier
        startupRecoveryTask = task
    }

    // CKSyncEngine runs with automaticallySync = false, so nothing syncs on its own:
    // remote changes only arrive via push (best effort — often dropped after a force
    // quit), after a local change, or via manual sync. Without this hook a device could
    // stay on a stale state indefinitely while showing "Bereit". Called on launch and on
    // foreground entry, throttled like the feed auto-refresh.
    @objc func performForegroundSyncIfNeeded() {
        guard isStarted, foregroundSyncTask == nil else { return }
        let foregroundEpoch = localSubscriptionCleanupEpoch
        let taskIdentifier = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if foregroundSyncTaskIdentifier == taskIdentifier {
                    foregroundSyncTask = nil
                    foregroundSyncTaskIdentifier = nil
                }
            }
            if let error = await self.drainPendingSubscriptionCleanupIntentsIfNeeded() {
                self.handleLocalSubscriptionCleanupFailure(error)
            }
            guard foregroundEpoch == localSubscriptionCleanupEpoch,
                  self.isStarted,
                  self.anySyncEnabled else { return }
            let now = Date()
            if let last = self.lastForegroundSyncDate,
               now.timeIntervalSince(last) < 15 * 60 {
                return
            }
            self.lastForegroundSyncDate = now
            self.logSyncEvent("Foreground-Sync angestoßen")
            self.setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
            await self.refreshAccountStatus()
            guard foregroundEpoch == localSubscriptionCleanupEpoch,
                  self.isStarted,
                  self.isICloudAccountIdentityVerified else { return }
            await self.continueEnabledSyncAfterAccountVerification()
            guard foregroundEpoch == localSubscriptionCleanupEpoch,
                  self.isStarted else { return }
            // Resume any interrupted episode loading for stub feeds; feeds that failed in
            // the previous session/run get one fresh attempt per foreground entry.
            self.hydrationFailedFeedIDs.removeAll()
            self.hydrateStubFeedsIfNeeded()
        }
        foregroundSyncTaskIdentifier = taskIdentifier
        foregroundSyncTask = task
    }

    @objc func setEpisodesSyncEnabled(_ enabled: Bool) {
        guard applyEpisodesSyncEnabled(enabled) else { return }
        updateSyncEngineCallbackGate()
        logSyncEvent("Episode Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @discardableResult
    private func applyEpisodesSyncEnabled(_ enabled: Bool) -> Bool {
        guard episodesSyncEnabled != enabled else { return false }
        if enabled, isICloudAccountIdentityVerified,
           let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) {
            prepareInitialEpisodeFetchBeforeUploadIfNeeded(
                accountRecordName: accountRecordName
            )
        }
        defaults.set(enabled, forKey: ICiCloudSyncEpisodesEnabled)
        if enabled {
            defaults.set(true, forKey: Self.episodesSyncHasParticipatedKey)
            if isICloudAccountIdentityVerified {
                prepareInitialBackfillsForVerifiedAccount()
            }
        } else {
            discardInitialUploadCheckpoints(episodes: true, subscriptions: false)
        }
        return true
    }

    @objc func setSubscriptionsSyncEnabled(_ enabled: Bool) {
        guard applySubscriptionsSyncEnabled(enabled) else { return }
        updateSyncEngineCallbackGate()
        logSyncEvent("Abo Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @discardableResult
    private func applySubscriptionsSyncEnabled(_ enabled: Bool) -> Bool {
        guard subscriptionsSyncEnabled != enabled else { return false }
        defaults.set(enabled, forKey: ICiCloudSyncSubscriptionsEnabled)
        if enabled {
            defaults.set(true, forKey: Self.subscriptionsSyncHasParticipatedKey)
            if isICloudAccountIdentityVerified {
                prepareInitialBackfillsForVerifiedAccount()
            }
            // Enabling must NEVER delete local subscriptions: deletions that piled up in
            // the cloud while sync was off arrive in the catch-up fetch and are suppressed
            // until the first complete fetch has run (union semantics — the local copy is
            // re-uploaded by the backfill). Only live deletions after that are applied.
            defaults.set(true, forKey: Self.suppressSubscriptionDeletionsKey)
        } else {
            discardInitialUploadCheckpoints(episodes: false, subscriptions: true)
            defaults.removeObject(forKey: Self.suppressSubscriptionDeletionsKey)
        }
        return true
    }

    @objc func setSettingsSyncEnabled(_ enabled: Bool) {
        guard applySettingsSyncEnabled(enabled) else { return }
        logSyncEvent("Einstellungs-Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @discardableResult
    private func applySettingsSyncEnabled(_ enabled: Bool) -> Bool {
        guard settingsSyncEnabled != enabled else { return false }
        defaults.set(enabled, forKey: ICiCloudSyncSettingsEnabled)
        if enabled {
            defaults.set(true, forKey: Self.initialSettingsBackfillPendingKey)
        } else {
            defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
            setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
            setStoredSyncedSettingsHash(nil)
        }
        return true
    }

    @objc(restoreSyncOptionsWithEpisodes:subscriptions:settings:)
    func restoreSyncOptions(episodes: NSNumber?, subscriptions: NSNumber?, settings: NSNumber?) {
        var changed = false
        if let episodes {
            changed = applyEpisodesSyncEnabled(episodes.boolValue) || changed
        }
        if let subscriptions {
            changed = applySubscriptionsSyncEnabled(subscriptions.boolValue) || changed
        }
        if let settings {
            changed = applySettingsSyncEnabled(settings.boolValue) || changed
        }
        guard changed else { return }
        updateSyncEngineCallbackGate()
        logSyncEvent("iCloud Sync-Schalter aus Backup wiederhergestellt", metadata: [
            "episodesPresent": episodes != nil,
            "subscriptionsPresent": subscriptions != nil,
            "settingsPresent": settings != nil,
        ])
        syncOptionsChanged()
    }

    @objc func syncOptionsChanged() {
        if !anySyncEnabled {
            cancelLowPrioritySyncTask()
        }
        guard persistFinalDeviceRecordUpdateIntent() else {
            postStateChanged()
            return
        }
        cachedSyncTotalCounts = nil
        refreshSyncTotalCountsInBackground()
        guard isStarted else { return }
        let optionsGeneration = cloudAccountGeneration

        logSyncEvent("Sync-Optionen geändert")
        if anySyncEnabled {
            clearError()
            setStatus(hasInitialUploadBackfillWork
                ? backfillProgressStatusText()
                : NSLocalizedString("iCloud prüfen…", comment: ""))
            Task { @MainActor in
                if !isICloudAccountIdentityVerified {
                    await refreshAccountStatus()
                }
                guard isStarted,
                      optionsGeneration == cloudAccountGeneration,
                      !Task.isCancelled,
                      isICloudAccountIdentityVerified else { return }
                queueDeviceRecord(scheduleSync: false)
                await continueEnabledSyncAfterAccountVerification()
            }
            postStateChanged()
            return
        }

        logSyncEvent("iCloud Sync deaktiviert")
        clearError()
        cancelInitialQueueTask()
        if isICloudAccountSignedOut {
            setStatus(NSLocalizedString("Aus", comment: ""))
            postStateChanged()
            return
        }
        setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
        Task { @MainActor in
            await refreshAccountStatus()
            guard isStarted,
                  optionsGeneration == cloudAccountGeneration,
                  !Task.isCancelled,
                  isICloudAccountIdentityVerified else { return }
            resumePendingFinalDeviceRecordUpdateIfNeeded()
            postStateChanged()
        }
        postStateChanged()
    }

    func continueEnabledSyncAfterAccountVerification() async {
        guard isStarted, anySyncEnabled, !isDeletingAllICloudData,
              !isICloudAccountSignedOut, isICloudAccountIdentityVerified else { return }
        let generation = cloudAccountGeneration
        prepareInitialBackfillsForVerifiedAccount()
        captureInitialBackfillTotalsFromCachedCountsIfNeeded()
        let resumedSingletonUploads = await resumePendingSingletonUploadsForVerifiedAccount()
        guard isStarted,
              generation == cloudAccountGeneration,
              !Task.isCancelled,
              anySyncEnabled,
              !isDeletingAllICloudData else { return }
        if hasInitialUploadBackfillWork {
            if requiresInitialBackfillFetchBeforeUpload {
                setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
                scheduleLowPrioritySync()
                return
            }
            setStatus(backfillProgressStatusText())
            scheduleCurrentEnabledDataForUpload()
            return
        }
        let drainedLocalOutbox = await drainLocalOutbox()
        guard isStarted,
              generation == cloudAccountGeneration,
              !Task.isCancelled,
              anySyncEnabled,
              !isDeletingAllICloudData else { return }
        if resumedSingletonUploads || drainedLocalOutbox {
            scheduleLowPrioritySync()
        }
    }

    nonisolated static func pendingDeviceControlIntents() -> [PendingDeviceControlIntent] {
        guard let rows = syncMetadataValue(forKey: pendingDeviceControlIntentsKey) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let accountRecordName = row["accountRecordName"] as? String,
                  let targetDeviceID = row["targetDeviceID"] as? String,
                  let operation = row["operation"] as? String,
                  let revision = row["revision"] as? String,
                  let createdAt = row["createdAt"] as? Date,
                  !accountRecordName.isEmpty, !targetDeviceID.isEmpty,
                  !operation.isEmpty, !revision.isEmpty else { return nil }
            return PendingDeviceControlIntent(
                accountRecordName: accountRecordName,
                targetDeviceID: targetDeviceID,
                operation: operation,
                revision: revision,
                payloadData: row["payloadData"] as? Data,
                pendingCleanupDeviceIDs: row["pendingCleanupDeviceIDs"] as? [String] ?? [],
                createdAt: createdAt
            )
        }
    }

    nonisolated static func pendingDeviceControlIntentRows(
        _ intents: [PendingDeviceControlIntent]
    ) -> [[String: Any]] {
        intents.map { intent in
            var row: [String: Any] = [
                "accountRecordName": intent.accountRecordName,
                "targetDeviceID": intent.targetDeviceID,
                "operation": intent.operation,
                "revision": intent.revision,
                "pendingCleanupDeviceIDs": intent.pendingCleanupDeviceIDs,
                "createdAt": intent.createdAt,
            ]
            if let payloadData = intent.payloadData {
                row["payloadData"] = payloadData
            }
            return row
        }
    }

    func writePendingDeviceControlIntents(_ intents: [PendingDeviceControlIntent]) throws {
        _ = try Self.writeSyncMetadataValue(
            Self.pendingDeviceControlIntentRows(intents),
            forKey: Self.pendingDeviceControlIntentsKey
        )
        defaults.removeObject(forKey: Self.pendingDeviceControlIntentsKey)
    }

    func pendingDeviceControlIntent(
        accountRecordName: String,
        targetDeviceID: String
    ) -> PendingDeviceControlIntent? {
        Self.pendingDeviceControlIntents().last {
            $0.accountRecordName == accountRecordName
                && $0.targetDeviceID == targetDeviceID
        }
    }

    func deviceControlCaptureAccountRecordName() -> String? {
        if let verifiedAccountRecordName = syncEngineCallbackGate
            .verifiedAccountRecordNameForLocalCapture(),
           !verifiedAccountRecordName.isEmpty {
            return verifiedAccountRecordName
        }
        if defaults.bool(forKey: Self.localOutboxHasVerifiedAccountKey)
            || defaults.bool(forKey: Self.localOutboxAwaitingAccountSwitchKey) {
            return ensurePendingLocalOutboxScope()
        }
        return Self.localOutboxUnboundAccountRecordName
    }

    @discardableResult
    func persistPendingDeviceControlSaveIntent(
        accountRecordName explicitAccountRecordName: String? = nil,
        stampLastSyncDate: Bool = false
    ) -> PendingDeviceControlIntent? {
        guard let accountRecordName = explicitAccountRecordName
                ?? deviceControlCaptureAccountRecordName(),
              let deviceID,
              var payload = localDevicePayload() else { return nil }
        let revision = UUID().uuidString
        let createdAt = Date()
        if stampLastSyncDate {
            payload["lastSyncDate"] = createdAt
        }
        payload["updatedAt"] = createdAt
        payload[Self.localMutationRevisionPayloadKey] = revision
        do {
            let payloadData = try PropertyListSerialization.data(
                fromPropertyList: payload,
                format: .binary,
                options: 0
            )
            var intents = Self.pendingDeviceControlIntents()
            var pendingCleanupDeviceIDs = Set(
                try Self.pendingInstallationDeviceCleanupIDs(
                    accountRecordName: accountRecordName,
                    currentDeviceID: deviceID
                )
            )
            for intent in intents where intent.accountRecordName == accountRecordName
                && intent.operation == Self.localOutboxSaveOperation
                && intent.targetDeviceID != deviceID {
                pendingCleanupDeviceIDs.insert(intent.targetDeviceID)
            }
            pendingCleanupDeviceIDs.remove(deviceID)
            let intent = PendingDeviceControlIntent(
                accountRecordName: accountRecordName,
                targetDeviceID: deviceID,
                operation: Self.localOutboxSaveOperation,
                revision: revision,
                payloadData: payloadData,
                pendingCleanupDeviceIDs: pendingCleanupDeviceIDs.sorted(),
                createdAt: createdAt
            )
            intents.removeAll {
                $0.accountRecordName == accountRecordName
                    && $0.operation == Self.localOutboxSaveOperation
            }
            intents.append(intent)
            try writePendingDeviceControlIntents(intents)
            return intent
        } catch {
            handleLocalPersistenceFailure(error)
            return nil
        }
    }

    @discardableResult
    func persistPendingDeviceControlDeleteIntent(
        targetDeviceID: String,
        accountRecordName explicitAccountRecordName: String? = nil
    ) -> PendingDeviceControlIntent? {
        guard !targetDeviceID.isEmpty,
              let currentDeviceID = deviceID,
              targetDeviceID != currentDeviceID,
              let accountRecordName = explicitAccountRecordName
                ?? deviceControlCaptureAccountRecordName(),
              !accountRecordName.isEmpty else { return nil }
        let intent = PendingDeviceControlIntent(
            accountRecordName: accountRecordName,
            targetDeviceID: targetDeviceID,
            operation: Self.localOutboxDeleteOperation,
            revision: UUID().uuidString,
            payloadData: nil,
            pendingCleanupDeviceIDs: [],
            createdAt: Date()
        )
        var intents = Self.pendingDeviceControlIntents()
        intents.removeAll {
            $0.accountRecordName == accountRecordName
                && $0.targetDeviceID == targetDeviceID
        }
        intents.append(intent)
        do {
            try writePendingDeviceControlIntents(intents)
            return intent
        } catch {
            handleLocalPersistenceFailure(error)
            return nil
        }
    }

    @discardableResult
    func clearPendingDeviceControlIntent(_ intent: PendingDeviceControlIntent) -> Bool {
        var intents = Self.pendingDeviceControlIntents()
        let previousCount = intents.count
        intents.removeAll {
            $0.accountRecordName == intent.accountRecordName
                && $0.targetDeviceID == intent.targetDeviceID
                && $0.operation == intent.operation
                && $0.revision == intent.revision
        }
        guard intents.count != previousCount else { return false }
        do {
            try writePendingDeviceControlIntents(intents)
            return true
        } catch {
            handleLocalPersistenceFailure(error)
            return false
        }
    }

    func removePendingDeviceControlIntents(accountRecordName: String) throws {
        var intents = Self.pendingDeviceControlIntents()
        let previousCount = intents.count
        intents.removeAll { $0.accountRecordName == accountRecordName }
        guard intents.count != previousCount else { return }
        try writePendingDeviceControlIntents(intents)
    }

    func bindPendingDeviceControlIntents(
        from sourceAccountRecordName: String,
        to accountRecordName: String
    ) throws {
        guard !sourceAccountRecordName.isEmpty,
              !accountRecordName.isEmpty,
              sourceAccountRecordName != accountRecordName else { return }
        var intents = Self.pendingDeviceControlIntents()
        let sourceIntents = intents.filter { $0.accountRecordName == sourceAccountRecordName }
        guard !sourceIntents.isEmpty else { return }
        intents.removeAll { $0.accountRecordName == sourceAccountRecordName }
        for sourceIntent in sourceIntents {
            let destinationIntent = intents.last {
                $0.accountRecordName == accountRecordName
                    && $0.targetDeviceID == sourceIntent.targetDeviceID
            }
            guard destinationIntent == nil
                    || sourceIntent.createdAt >= destinationIntent!.createdAt else { continue }
            intents.removeAll {
                $0.accountRecordName == accountRecordName
                    && $0.targetDeviceID == sourceIntent.targetDeviceID
            }
            intents.append(PendingDeviceControlIntent(
                accountRecordName: accountRecordName,
                targetDeviceID: sourceIntent.targetDeviceID,
                operation: sourceIntent.operation,
                revision: sourceIntent.revision,
                payloadData: sourceIntent.payloadData,
                pendingCleanupDeviceIDs: sourceIntent.pendingCleanupDeviceIDs,
                createdAt: sourceIntent.createdAt
            ))
        }
        try writePendingDeviceControlIntents(intents)
    }

    @discardableResult
    func migrateLegacyFinalDeviceRecordUpdateIntentIfNeeded(
        accountRecordName: String
    ) -> Bool {
        guard hasPendingLegacyFinalDeviceRecordUpdate else { return true }
        guard persistPendingDeviceControlSaveIntent(
            accountRecordName: accountRecordName
        ) != nil else { return false }
        clearPendingFinalDeviceRecordUpdateIntent()
        return true
    }

    func pendingDeviceControlSaveIntentMatchesCurrentState(
        _ intent: PendingDeviceControlIntent
    ) -> Bool {
        guard let storedPayload = intent.payloadDictionary(),
              let currentPayload = localDevicePayload() else { return false }
        for key in [
            "deviceID", "name", "model", "systemVersion", "appVersion",
            "episodesEnabled", "subscriptionsEnabled", "settingsEnabled",
        ] {
            let storedValue = storedPayload[key] as? NSObject
            let currentValue = currentPayload[key] as? NSObject
            if storedValue?.isEqual(currentValue) != true {
                return false
            }
        }
        return true
    }

    func resumePendingDeviceControlIntentsForVerifiedAccount() {
        guard isICloudAccountIdentityVerified,
              !isICloudAccountSignedOut,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty,
              migrateLegacyFinalDeviceRecordUpdateIntentIfNeeded(
                accountRecordName: accountRecordName
              ),
              let deviceID else { return }
        let staleSaveIntents = Self.pendingDeviceControlIntents().filter {
            $0.accountRecordName == accountRecordName
                && $0.operation == Self.localOutboxSaveOperation
                && $0.targetDeviceID != deviceID
        }
        if !staleSaveIntents.isEmpty,
           persistPendingDeviceControlSaveIntent(accountRecordName: accountRecordName) == nil {
            return
        }
        if let currentSaveIntent = pendingDeviceControlIntent(
            accountRecordName: accountRecordName,
            targetDeviceID: deviceID
        ), currentSaveIntent.operation == Self.localOutboxSaveOperation,
           !pendingDeviceControlSaveIntentMatchesCurrentState(currentSaveIntent),
           persistPendingDeviceControlSaveIntent(accountRecordName: accountRecordName) == nil {
            return
        }
        let intents = Self.pendingDeviceControlIntents().filter {
            $0.accountRecordName == accountRecordName
                && ($0.operation == Self.localOutboxDeleteOperation
                    || $0.targetDeviceID == deviceID)
        }
        guard !intents.isEmpty else { return }
        initializeSyncEngineIfNeeded()
        var pendingKeys = pendingRecordZoneChangeKeys()
        let changes = intents.compactMap { intent -> CKSyncEngine.PendingRecordZoneChange? in
            let recordID = deviceRecordID(for: intent.targetDeviceID)
            let change: CKSyncEngine.PendingRecordZoneChange = intent.operation
                == Self.localOutboxDeleteOperation ? .deleteRecord(recordID) : .saveRecord(recordID)
            let key = pendingChangeKey(change)
            guard !pendingKeys.contains(key) else { return nil }
            pendingKeys.insert(key)
            return change
        }
        if !changes.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: changes)
        }
        if anySyncEnabled {
            scheduleLowPrioritySync()
        } else {
            sendPendingDeviceControlIntents()
        }
    }

    @discardableResult
    func promotePendingDeviceCleanupAfterSaveAcknowledgement(
        _ intent: PendingDeviceControlIntent
    ) -> Bool {
        guard intent.operation == Self.localOutboxSaveOperation else { return false }
        for pendingCleanupDeviceID in intent.pendingCleanupDeviceIDs {
            guard persistPendingDeviceControlDeleteIntent(
                targetDeviceID: pendingCleanupDeviceID,
                accountRecordName: intent.accountRecordName
            ) != nil else { return false }
        }
        return clearPendingDeviceControlIntent(intent)
    }

    @discardableResult
    func acknowledgePendingDeviceControlSave(
        _ record: CKRecord,
        accountRecordName: String
    ) -> Bool {
        guard !accountRecordName.isEmpty,
              let deviceID,
              record.recordID.recordName.hasPrefix(RecordPrefix.device) else { return false }
        let targetDeviceID = String(
            record.recordID.recordName.dropFirst(RecordPrefix.device.count)
        )
        guard targetDeviceID == deviceID,
              let payload = payloadDictionary(from: record),
              let sentRevision = payload[Self.localMutationRevisionPayloadKey] as? String,
              let intent = pendingDeviceControlIntent(
                accountRecordName: accountRecordName,
                targetDeviceID: targetDeviceID
              ),
              intent.operation == Self.localOutboxSaveOperation else { return false }
        let currentRevision = intent.revision
        guard currentRevision == sentRevision else {
            var pendingKeys = pendingRecordZoneChangeKeys()
            addPendingSaves(
                [deviceRecordID(for: targetDeviceID)],
                pendingKeys: &pendingKeys,
                stampDeviceRecordForUserData: false,
                scheduleSync: false
            )
            requiresImmediateFinalDeviceRecordResend = true
            return false
        }
        guard promotePendingDeviceCleanupAfterSaveAcknowledgement(intent) else {
            return false
        }
        let cleanupIntents = Self.pendingDeviceControlIntents().filter {
            $0.accountRecordName == accountRecordName
                && $0.operation == Self.localOutboxDeleteOperation
                && intent.pendingCleanupDeviceIDs.contains($0.targetDeviceID)
        }
        if !cleanupIntents.isEmpty {
            var pendingKeys = pendingRecordZoneChangeKeys()
            addPendingDeletes(
                cleanupIntents.map { deviceRecordID(for: $0.targetDeviceID) },
                pendingKeys: &pendingKeys
            )
            requiresImmediateFinalDeviceRecordResend = true
        } else {
            requiresImmediateFinalDeviceRecordResend = false
        }
        return true
    }

    func acknowledgePendingDeviceControlDeletes(
        _ revisionsByRecordName: [String: String],
        accountRecordName: String
    ) {
        var installationCleanupDeviceIDs = Set<String>()
        if let currentDeviceID = deviceID {
            do {
                installationCleanupDeviceIDs = Set(
                    try Self.pendingInstallationDeviceCleanupIDs(
                        accountRecordName: accountRecordName,
                        currentDeviceID: currentDeviceID
                    )
                )
            } catch {
                handleLocalPersistenceFailure(error)
            }
        }
        var acknowledgedInstallationCleanup = false
        for (recordName, sentRevision) in revisionsByRecordName
        where recordName.hasPrefix(RecordPrefix.device) {
            let targetDeviceID = String(recordName.dropFirst(RecordPrefix.device.count))
            guard let intent = pendingDeviceControlIntent(
                accountRecordName: accountRecordName,
                targetDeviceID: targetDeviceID
            ), intent.operation == Self.localOutboxDeleteOperation else { continue }
            let currentRevision = intent.revision
            guard currentRevision == sentRevision else {
                var pendingKeys = pendingRecordZoneChangeKeys()
                addPendingDeletes(
                    [deviceRecordID(for: targetDeviceID)],
                    pendingKeys: &pendingKeys
                )
                requiresImmediateFinalDeviceRecordResend = true
                continue
            }
            guard clearPendingDeviceControlIntent(intent) else { continue }
            removeDeviceFromCache(targetDeviceID)
            if installationCleanupDeviceIDs.contains(targetDeviceID) {
                acknowledgedInstallationCleanup = true
            }
        }
        if acknowledgedInstallationCleanup {
            completeInstallationDeviceCleanupIfPossible(
                accountRecordName: accountRecordName
            )
        }
    }

    func completeInstallationDeviceCleanupIfPossible(accountRecordName: String) {
        guard let deviceID else { return }
        do {
            let cleanupDeviceIDs = Set(
                try Self.pendingInstallationDeviceCleanupIDs(
                    accountRecordName: accountRecordName,
                    currentDeviceID: deviceID
                )
            )
            guard !cleanupDeviceIDs.isEmpty else { return }
            let stillPending = Self.pendingDeviceControlIntents().contains { intent in
                guard intent.accountRecordName == accountRecordName else { return false }
                if intent.operation == Self.localOutboxDeleteOperation {
                    return cleanupDeviceIDs.contains(intent.targetDeviceID)
                }
                return !cleanupDeviceIDs.isDisjoint(
                    with: intent.pendingCleanupDeviceIDs
                )
            }
            guard !stillPending else { return }
            try Self.markInstallationDeviceCleanupCompleted(
                accountRecordName: accountRecordName,
                currentDeviceID: deviceID
            )
        } catch {
            handleLocalPersistenceFailure(error)
        }
    }

    nonisolated static func pendingSingletonUploadIntents() -> [PendingSingletonUploadIntent] {
        guard let rows = syncMetadataValue(forKey: pendingSingletonUploadIntentsKey) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let recordName = row["recordName"] as? String,
                  let accountRecordName = row["accountRecordName"] as? String,
                  let revision = row["revision"] as? String,
                  let modifiedAt = row["modifiedAt"] as? Date,
                  !recordName.isEmpty, !accountRecordName.isEmpty, !revision.isEmpty else {
                return nil
            }
            return PendingSingletonUploadIntent(
                recordName: recordName,
                accountRecordName: accountRecordName,
                revision: revision,
                sequence: (row["sequence"] as? NSNumber)?.int64Value ?? 0,
                modifiedAt: modifiedAt,
                payloadData: row["payloadData"] as? Data
            )
        }
    }

    nonisolated static func pendingSingletonUploadIntentRows(
        _ intents: [PendingSingletonUploadIntent]
    ) -> [[String: Any]] {
        intents.map { intent in
            var row: [String: Any] = [
                "recordName": intent.recordName,
                "accountRecordName": intent.accountRecordName,
                "revision": intent.revision,
                "sequence": intent.sequence,
                "modifiedAt": intent.modifiedAt,
            ]
            if let payloadData = intent.payloadData {
                row["payloadData"] = payloadData
            }
            return row
        }
    }

    func writePendingSingletonUploadIntents(_ intents: [PendingSingletonUploadIntent]) throws {
        // Keep the empty state as an atomic plist too. File removal used to swallow errors,
        // so ACK/remote-winner paths could report success while the old intent survived and
        // was uploaded again after the next launch.
        _ = try Self.writeSyncMetadataValue(
            Self.pendingSingletonUploadIntentRows(intents),
            forKey: Self.pendingSingletonUploadIntentsKey
        )
        defaults.removeObject(forKey: Self.pendingSingletonUploadIntentsKey)
    }

    func pendingSingletonUploadIntent(
        recordName: String,
        accountRecordName: String
    ) -> PendingSingletonUploadIntent? {
        Self.pendingSingletonUploadIntents().last {
            $0.recordName == recordName && $0.accountRecordName == accountRecordName
        }
    }

    func nextPendingSingletonSequence(
        _ intents: [PendingSingletonUploadIntent]
    ) -> Int64 {
        (intents.map(\.sequence).max() ?? 0) + 1
    }

    nonisolated static func singletonClockFloors() -> [String: [String: Date]] {
        syncMetadataValue(forKey: singletonClockFloorsKey) as? [String: [String: Date]] ?? [:]
    }

    func writeSingletonClockFloors(_ floors: [String: [String: Date]]) throws {
        if floors.isEmpty {
            Self.removeSyncMetadataValue(forKey: Self.singletonClockFloorsKey)
        } else {
            _ = try Self.writeSyncMetadataValue(
                floors,
                forKey: Self.singletonClockFloorsKey
            )
        }
        defaults.removeObject(forKey: Self.singletonClockFloorsKey)
    }

    func singletonClockFloor(
        recordName: String,
        accountRecordName: String
    ) -> Date? {
        Self.singletonClockFloors()[accountRecordName]?[recordName]
    }

    func persistSingletonClockFloor(
        _ date: Date,
        recordName: String,
        accountRecordName: String
    ) throws {
        var floors = Self.singletonClockFloors()
        var accountFloors = floors[accountRecordName] ?? [:]
        if date > (accountFloors[recordName] ?? .distantPast) {
            accountFloors[recordName] = date
            floors[accountRecordName] = accountFloors
            try writeSingletonClockFloors(floors)
        }
    }

    func bindSingletonClockFloors(
        from sourceAccountRecordName: String,
        to accountRecordName: String
    ) throws {
        guard !sourceAccountRecordName.isEmpty,
              !accountRecordName.isEmpty,
              sourceAccountRecordName != accountRecordName else { return }
        var floors = Self.singletonClockFloors()
        guard let sourceFloors = floors.removeValue(forKey: sourceAccountRecordName) else { return }
        var destinationFloors = floors[accountRecordName] ?? [:]
        for (recordName, sourceDate) in sourceFloors
        where sourceDate > (destinationFloors[recordName] ?? .distantPast) {
            destinationFloors[recordName] = sourceDate
        }
        floors[accountRecordName] = destinationFloors
        try writeSingletonClockFloors(floors)
    }

    func singletonMetadataClockFloor(recordName: String) -> Date? {
        switch recordName {
        case RecordPrefix.appSettings:
            return settingsLocalModifiedDate()
        case RecordPrefix.listScrollPositions:
            return scrollPositionsLocalModifiedDate()
        case RecordPrefix.subscriptionListSettings:
            return defaults.object(
                forKey: Self.subscriptionListSettingsLocalModifiedDateKey
            ) as? Date
        default:
            return nil
        }
    }

    func singletonListOutboxClockFloor(
        recordName: String,
        revision: String,
        accountRecordName: String
    ) throws -> (floor: Date?, exactRevisionDate: Date?) {
        guard recordName == RecordPrefix.subscriptionListSettings else { return (nil, nil) }
        guard let context = databaseManager.objectContext else {
            throw Self.localOutboxStoreError(
                code: 1,
                description: "Die lokale iCloud-Outbox konnte nicht geöffnet werden."
            )
        }
        let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(
                format: "accountRecordName IN %@",
                Array(causalLocalOutboxScopes(for: accountRecordName))
            ),
            NSPredicate(format: "recordName == %@", recordName),
        ])
        let entries = try context.fetch(request)
        let floor = entries.compactMap { $0.value(forKey: "changedAt") as? Date }.max()
        let exactRevisionDate = entries.first {
            $0.value(forKey: "revision") as? String == revision
        }?.value(forKey: "changedAt") as? Date
        return (floor, exactRevisionDate)
    }

    func nextSingletonModifiedAt(
        proposed: Date,
        recordName: String,
        revision: String,
        accountRecordName: String,
        intents: [PendingSingletonUploadIntent]
    ) throws -> Date {
        let listOutboxClock = try singletonListOutboxClockFloor(
            recordName: recordName,
            revision: revision,
            accountRecordName: accountRecordName
        )
        let causalScopes = causalLocalOutboxScopes(for: accountRecordName)
        let durableFloor = causalScopes.compactMap {
            singletonClockFloor(recordName: recordName, accountRecordName: $0)
        }.max()
        let currentIntentDate = intents
            .filter {
                $0.recordName == recordName
                    && causalScopes.contains($0.accountRecordName)
            }
            .map(\.modifiedAt)
            .max()
        let metadataFloor = syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
            == accountRecordName ? singletonMetadataClockFloor(recordName: recordName) : nil
        let floor = [
            durableFloor,
            metadataFloor,
            currentIntentDate,
            listOutboxClock.floor,
        ].compactMap { $0 }.max()
        if listOutboxClock.exactRevisionDate == proposed,
           proposed >= (floor ?? .distantPast) {
            return proposed
        }
        return Self.nextCloudKitSafeDate(proposed: proposed, after: floor)
    }

    @discardableResult
    func persistPendingSingletonUploadIntent(
        for recordID: CKRecord.ID,
        revision: String = UUID().uuidString,
        modifiedAt: Date = Date(),
        payload: [String: Any]? = nil
    ) -> PendingSingletonUploadIntent? {
        guard recordID.recordName == RecordPrefix.appSettings
                || recordID.recordName == RecordPrefix.listScrollPositions
                || recordID.recordName == RecordPrefix.subscriptionListSettings else {
            handleLocalPersistenceFailure(NSError(
                domain: "ICiCloudSyncSingletonIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The pending singleton record type is invalid."]
            ))
            return nil
        }
        let verifiedAccountRecordName = syncEngineCallbackGate.verifiedAccountRecordNameForLocalCapture()
        guard let accountRecordName = Self.localOutboxCaptureAccountRecordName(
                defaults: defaults,
                verifiedAccountRecordName: verifiedAccountRecordName
              ),
              !accountRecordName.isEmpty else {
            let error = NSError(
                domain: "ICiCloudSyncSingletonIntent",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The iCloud account for the pending singleton upload is unavailable."]
            )
            handleLocalPersistenceFailure(error)
            return nil
        }
        var intents = Self.pendingSingletonUploadIntents()
        if let existing = intents.last(where: {
            $0.recordName == recordID.recordName
                && $0.accountRecordName == accountRecordName
                && $0.revision == revision
        }), existing.modifiedAt == modifiedAt {
            return existing
        }
        let effectiveModifiedAt: Date
        do {
            effectiveModifiedAt = try nextSingletonModifiedAt(
                proposed: modifiedAt,
                recordName: recordID.recordName,
                revision: revision,
                accountRecordName: accountRecordName,
                intents: intents
            )
        } catch {
            handleLocalPersistenceFailure(error)
            return nil
        }
        guard var capturedPayload = payload
                ?? singletonUploadPayload(for: recordID, modifiedAt: effectiveModifiedAt) else {
            handleLocalPersistenceFailure(NSError(
                domain: "ICiCloudSyncSingletonIntent",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The pending singleton payload could not be captured."]
            ))
            return nil
        }
        capturedPayload["updatedAt"] = effectiveModifiedAt
        capturedPayload[Self.localMutationRevisionPayloadKey] = revision
        if recordID.recordName == RecordPrefix.listScrollPositions {
            capturedPayload["lastModified"] = effectiveModifiedAt
        }
        let payloadData: Data
        do {
            payloadData = try PropertyListSerialization.data(
                fromPropertyList: capturedPayload,
                format: .binary,
                options: 0
            )
        } catch {
            handleLocalPersistenceFailure(error)
            return nil
        }
        let intent = PendingSingletonUploadIntent(
            recordName: recordID.recordName,
            accountRecordName: accountRecordName,
            revision: revision,
            sequence: nextPendingSingletonSequence(intents),
            modifiedAt: effectiveModifiedAt,
            payloadData: payloadData
        )
        intents.removeAll {
            $0.recordName == intent.recordName && $0.accountRecordName == intent.accountRecordName
        }
        intents.append(intent)
        do {
            // The retryable payload/revision must reach disk before its derived clock floor.
            // A kill between these writes then leaves a complete upload intent, never a
            // floor-only state whose corresponding mutation can no longer be reconstructed.
            try writePendingSingletonUploadIntents(intents)
            try persistSingletonClockFloor(
                effectiveModifiedAt,
                recordName: recordID.recordName,
                accountRecordName: accountRecordName
            )
            return intent
        } catch {
            handleLocalPersistenceFailure(error)
            return nil
        }
    }

    func singletonUploadPayload(
        for recordID: CKRecord.ID,
        modifiedAt: Date
    ) -> [String: Any]? {
        guard let deviceID else { return nil }
        switch recordID.recordName {
        case RecordPrefix.appSettings:
            return Self.appSettingsPayloadForSyncEngineCallback(
                updatedAt: modifiedAt,
                deviceID: deviceID
            )
        case RecordPrefix.listScrollPositions:
            return [
                "positions": ICListScrollPositionsSnapshot() ?? [:],
                "lastModified": modifiedAt,
                "deviceID": deviceID,
                "updatedAt": modifiedAt,
            ]
        case RecordPrefix.subscriptionListSettings:
            guard let context = databaseManager.objectContext else { return nil }
            return subscriptionListSettingsPayload(in: context)
        default:
            return nil
        }
    }

    @discardableResult
    func clearPendingSingletonUploadIntent(_ intent: PendingSingletonUploadIntent) -> Bool {
        var intents = Self.pendingSingletonUploadIntents()
        let previousCount = intents.count
        intents.removeAll {
            $0.recordName == intent.recordName
                && $0.accountRecordName == intent.accountRecordName
                && $0.revision == intent.revision
        }
        guard intents.count != previousCount else { return false }
        do {
            // Cleanup is the inverse crash-safe order: retain the exact causal timestamp
            // before removing the only retryable copy of the acknowledged mutation.
            try persistSingletonClockFloor(
                intent.modifiedAt,
                recordName: intent.recordName,
                accountRecordName: intent.accountRecordName
            )
            try writePendingSingletonUploadIntents(intents)
            return true
        } catch {
            handleLocalPersistenceFailure(error)
            return false
        }
    }

    nonisolated static func payloadDataByReplacingSingletonDates(
        _ payloadData: Data?,
        recordName: String,
        modifiedAt: Date
    ) throws -> Data? {
        guard let payloadData else { return nil }
        guard var payload = try PropertyListSerialization.propertyList(
            from: payloadData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw NSError(
                domain: "ICiCloudSyncSingletonIntent",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The pending singleton payload is invalid."]
            )
        }
        payload["updatedAt"] = modifiedAt
        if recordName == RecordPrefix.listScrollPositions {
            payload["lastModified"] = modifiedAt
        }
        return try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: .binary,
            options: 0
        )
    }

    func bindPendingSingletonUploadIntents(
        from sourceAccountRecordName: String,
        to accountRecordName: String
    ) async throws {
        guard !sourceAccountRecordName.isEmpty,
              !accountRecordName.isEmpty,
              sourceAccountRecordName != accountRecordName else { return }
        guard Self.pendingSingletonUploadIntents().contains(where: {
            $0.accountRecordName == sourceAccountRecordName
        }) else { return }
        let listOutboxEntries = try await Self.localOutboxEntries(
            accountRecordName: accountRecordName,
            categories: [Self.localOutboxSubscriptionListSettingsCategory],
            recordNames: [RecordPrefix.subscriptionListSettings]
        )
        let listOutboxEntry = listOutboxEntries.first
        // Local captures may run while the outbox fetch is suspended. Re-read after the
        // await so the binding rewrite cannot erase a newer target-account revision.
        var intents = Self.pendingSingletonUploadIntents()
        let sourceIntents = intents.filter {
            $0.accountRecordName == sourceAccountRecordName
        }
        guard !sourceIntents.isEmpty else { return }
        intents.removeAll { $0.accountRecordName == sourceAccountRecordName }
        for sourceIntent in sourceIntents {
            let destinationIntent = intents.last {
                $0.accountRecordName == accountRecordName
                    && $0.recordName == sourceIntent.recordName
            }
            let winner: PendingSingletonUploadIntent
            if let destinationIntent,
               destinationIntent.sequence > sourceIntent.sequence {
                winner = destinationIntent
            } else {
                let exactOutboxDate = sourceIntent.recordName
                    == RecordPrefix.subscriptionListSettings
                    && listOutboxEntry?.revision == sourceIntent.revision
                    ? listOutboxEntry?.changedAt : nil
                let floor = [
                    singletonClockFloor(
                        recordName: sourceIntent.recordName,
                        accountRecordName: accountRecordName
                    ),
                    destinationIntent?.modifiedAt,
                    sourceIntent.modifiedAt,
                ].compactMap { $0 }.max()
                let modifiedAt: Date
                if let exactOutboxDate,
                   exactOutboxDate >= (floor ?? .distantPast) {
                    modifiedAt = exactOutboxDate
                } else {
                    modifiedAt = Self.nextCloudKitSafeDate(
                        proposed: sourceIntent.modifiedAt,
                        after: floor
                    )
                }
                let payloadData = try Self.payloadDataByReplacingSingletonDates(
                    sourceIntent.payloadData,
                    recordName: sourceIntent.recordName,
                    modifiedAt: modifiedAt
                )
                try persistSingletonClockFloor(
                    modifiedAt,
                    recordName: sourceIntent.recordName,
                    accountRecordName: accountRecordName
                )
                winner = PendingSingletonUploadIntent(
                    recordName: sourceIntent.recordName,
                    accountRecordName: accountRecordName,
                    revision: sourceIntent.revision,
                    sequence: sourceIntent.sequence,
                    modifiedAt: modifiedAt,
                    payloadData: payloadData
                )
            }
            intents.removeAll {
                $0.accountRecordName == accountRecordName
                    && $0.recordName == sourceIntent.recordName
            }
            intents.append(winner)
        }
        try writePendingSingletonUploadIntents(intents)
    }

    @discardableResult
    func discardPendingSingletonUploadIntent(recordName: String) -> Bool {
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else {
            handleLocalPersistenceFailure(NSError(
                domain: "ICiCloudSyncSingletonIntent",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The iCloud account for the superseded singleton upload is unavailable."]
            ))
            return false
        }
        var intents = Self.pendingSingletonUploadIntents()
        let removedIntents = intents.filter {
            $0.recordName == recordName && $0.accountRecordName == accountRecordName
        }
        if !removedIntents.isEmpty {
            intents.removeAll {
                $0.recordName == recordName && $0.accountRecordName == accountRecordName
            }
            do {
                for intent in removedIntents {
                    try persistSingletonClockFloor(
                        intent.modifiedAt,
                        recordName: intent.recordName,
                        accountRecordName: intent.accountRecordName
                    )
                }
                try writePendingSingletonUploadIntents(intents)
            } catch {
                handleLocalPersistenceFailure(error)
                return false
            }
        }
        removePendingRecordChanges(recordNames: [recordName])
        recordInitialUploadRecordNamesResolved([recordName])
        return true
    }

    func singletonUploadIsEnabled(recordName: String) -> Bool {
        switch recordName {
        case RecordPrefix.appSettings:
            return settingsSyncEnabled
        case RecordPrefix.listScrollPositions:
            return episodesSyncEnabled
        case RecordPrefix.subscriptionListSettings:
            return subscriptionsSyncEnabled
        default:
            return false
        }
    }

    @discardableResult
    func queuePendingSingletonUploadWithoutReplacingIntent(recordName: String) -> Bool {
        guard isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              pendingSingletonUploadIntent(
                recordName: recordName,
                accountRecordName: accountRecordName
              ) != nil,
              singletonUploadIsEnabled(recordName: recordName) else {
            return false
        }
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves(
            [CKRecord.ID(recordName: recordName, zoneID: zoneID)],
            pendingKeys: &pendingKeys,
            stampDeviceRecordForUserData: true,
            scheduleSync: false
        )
        return true
    }

    @discardableResult
    func resumePendingSingletonUploadsForVerifiedAccount() async -> Bool {
        guard isStarted,
              isICloudAccountIdentityVerified,
              !isICloudAccountSignedOut,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
            return false
        }
        let generation = cloudAccountGeneration
        let intents = Self.pendingSingletonUploadIntents().filter { intent in
            intent.accountRecordName == accountRecordName
                && singletonUploadIsEnabled(recordName: intent.recordName)
        }
        var subscriptionListSettingsPayload: [String: Any]?
        if intents.contains(where: { $0.recordName == RecordPrefix.subscriptionListSettings }) {
            do {
                subscriptionListSettingsPayload = try await Self.committedSubscriptionListSettingsPayload()
            } catch {
                guard generation == cloudAccountGeneration else { return false }
                handleLocalPersistenceFailure(error)
                return false
            }
            guard isStarted,
                  generation == cloudAccountGeneration,
                  !Task.isCancelled,
                  isICloudAccountIdentityVerified,
                  defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
                return false
            }
        }
        var effectiveIntents: [PendingSingletonUploadIntent] = []
        for intent in intents {
            guard let effectiveIntent = refreshPendingSingletonIntentForCurrentLocalState(
                intent,
                subscriptionListSettingsPayload: subscriptionListSettingsPayload
            ) else { return false }
            effectiveIntents.append(effectiveIntent)
        }
        for intent in effectiveIntents {
            restorePendingSingletonUploadMetadata(intent)
        }
        let recordNames = effectiveIntents.map { intent in
            intent.recordName
        }
        guard !recordNames.isEmpty else { return false }
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves(
            recordNames.map { CKRecord.ID(recordName: $0, zoneID: zoneID) },
            pendingKeys: &pendingKeys,
            stampDeviceRecordForUserData: true,
            scheduleSync: false
        )
        return true
    }

    func refreshPendingSingletonIntentForCurrentLocalState(
        _ intent: PendingSingletonUploadIntent,
        subscriptionListSettingsPayload: [String: Any]?
    ) -> PendingSingletonUploadIntent? {
        let modifiedAt = Date()
        let currentPayload: [String: Any]?
        if intent.recordName == RecordPrefix.subscriptionListSettings {
            currentPayload = subscriptionListSettingsPayload
        } else {
            currentPayload = singletonUploadPayload(
                for: CKRecord.ID(recordName: intent.recordName, zoneID: zoneID),
                modifiedAt: modifiedAt
            )
        }
        guard let currentPayload else { return nil }
        if singletonIntentPayloadMatchesCurrentState(
            intent,
            currentPayload: currentPayload
        ) {
            return intent
        }
        return persistPendingSingletonUploadIntent(
            for: CKRecord.ID(recordName: intent.recordName, zoneID: zoneID),
            modifiedAt: modifiedAt,
            payload: currentPayload
        )
    }

    func singletonIntentPayloadMatchesCurrentState(
        _ intent: PendingSingletonUploadIntent,
        currentPayload: [String: Any]
    ) -> Bool {
        guard let storedPayload = intent.payloadDictionary() else { return false }
        switch intent.recordName {
        case RecordPrefix.appSettings:
            let storedValues = storedPayload["values"] as? NSDictionary ?? NSDictionary()
            let currentValues = currentPayload["values"] as? NSDictionary ?? NSDictionary()
            let storedCredentials = storedPayload["credentials"] as? NSDictionary ?? NSDictionary()
            let currentCredentials = currentPayload["credentials"] as? NSDictionary ?? NSDictionary()
            return storedValues.isEqual(currentValues)
                && storedCredentials.isEqual(currentCredentials)
        case RecordPrefix.listScrollPositions:
            let storedPositions = storedPayload["positions"] as? NSDictionary ?? NSDictionary()
            let currentPositions = currentPayload["positions"] as? NSDictionary ?? NSDictionary()
            return storedPositions.isEqual(currentPositions)
        case RecordPrefix.subscriptionListSettings:
            return Self.subscriptionListSettingsFingerprint(payload: storedPayload)
                == Self.subscriptionListSettingsFingerprint(payload: currentPayload)
        default:
            return false
        }
    }

    func restorePendingSingletonUploadMetadata(_ intent: PendingSingletonUploadIntent) {
        switch intent.recordName {
        case RecordPrefix.appSettings:
            setSettingsLocalModifiedDate(intent.modifiedAt)
            if let payload = intent.payloadDictionary(),
               let hash = syncedSettingsHash(payload: payload) {
                setStoredSyncedSettingsHash(hash)
            }
        case RecordPrefix.listScrollPositions:
            setScrollPositionsLocalModifiedDate(intent.modifiedAt)
        case RecordPrefix.subscriptionListSettings:
            setSyncMetadata(
                intent.modifiedAt,
                forKey: Self.subscriptionListSettingsLocalModifiedDateKey
            )
            if let payload = intent.payloadDictionary() {
                setSyncMetadata(
                    Self.subscriptionListSettingsFingerprint(payload: payload),
                    forKey: Self.subscriptionListSettingsBaselineKey
                )
            }
        default:
            break
        }
    }

    @discardableResult
    func persistFinalDeviceRecordUpdateIntent() -> Bool {
        persistPendingDeviceControlSaveIntent() != nil
    }

    func clearPendingFinalDeviceRecordUpdateIntent() {
        Self.removeSyncMetadataValue(forKey: Self.finalDeviceRecordUpdatePendingKey)
        defaults.removeObject(forKey: Self.finalDeviceRecordUpdatePendingKey)
    }

    func resumePendingFinalDeviceRecordUpdateIfNeeded() {
        resumePendingDeviceControlIntentsForVerifiedAccount()
    }

    func sendPendingDeviceControlIntents() {
        sendFinalDeviceRecordUpdate()
    }

    func sendFinalDeviceRecordUpdate() {
        guard hasPendingFinalDeviceRecordUpdate,
              !isDeletingAllICloudData, isICloudAccountIdentityVerified,
              finalDeviceRecordUpdateTask == nil,
              let syncEngine else { return }
        finalDeviceRecordUpdateGeneration &+= 1
        let generation = finalDeviceRecordUpdateGeneration
        finalDeviceRecordUpdateTask = Task { @MainActor [weak self, syncEngine] in
            guard let self else { return }
            let cloudGeneration = self.cloudAccountGeneration
            let deferredLocalChanges: Bool
            do {
                deferredLocalChanges = try await self.sendChangesAndApplyCallbackOutcomes(
                    syncEngine,
                    generation: cloudGeneration
                )
            } catch {
                guard generation == self.finalDeviceRecordUpdateGeneration else { return }
                self.finalDeviceRecordUpdateTask = nil
                self.setError(error)
                self.scheduleSyncRetryAfterFailure(error: error, reason: "finalDeviceRecord")
                return
            }
            guard generation == self.finalDeviceRecordUpdateGeneration else { return }
            self.finalDeviceRecordUpdateTask = nil
            if deferredLocalChanges {
                if self.hasPendingSyncChanges {
                    self.scheduleLowPrioritySync()
                }
                return
            }
            if self.hasPendingFinalDeviceRecordUpdate {
                if !self.hasUnresolvedSyncFailures {
                    let error = NSError(
                        domain: "ICiCloudSyncFinalDeviceRecord",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("iCloud Sync konnte nicht abgeschlossen werden.", comment: "")]
                    )
                    self.setError(error)
                    self.scheduleSyncRetryAfterFailure(error: error, reason: "finalDeviceRecord")
                }
                return
            }
            if !self.anySyncEnabled {
                self.clearError()
                self.setStatus(NSLocalizedString("Aus", comment: ""))
                self.postStateChanged()
            } else if self.hasPendingSyncChanges {
                self.scheduleLowPrioritySync()
            }
            self.runRequestedCloudInventoryRefresh()
        }
    }

    func awaitFinalDeviceRecordUpdate() async {
        guard let task = finalDeviceRecordUpdateTask else { return }
        let generation = finalDeviceRecordUpdateGeneration
        task.cancel()
        await task.value
        if generation == finalDeviceRecordUpdateGeneration {
            finalDeviceRecordUpdateTask = nil
        }
    }

    func cancelFinalDeviceRecordUpdate() {
        finalDeviceRecordUpdateGeneration &+= 1
        finalDeviceRecordUpdateTask?.cancel()
        finalDeviceRecordUpdateTask = nil
    }

    @objc func performManualSyncWithCompletion(_ completion: @escaping (NSError?) -> Void) {
        guard !syncInProgress else {
            completion(nil)
            return
        }
        let preflightGeneration = cloudAccountGeneration
        Task { @MainActor in
            guard isStarted,
                  preflightGeneration == cloudAccountGeneration,
                  !isDeletingAllICloudData else {
                completion(nil)
                return
            }
            if isICloudAccountSignedOut || !isICloudAccountIdentityVerified {
                await refreshAccountStatus()
                guard isStarted,
                      preflightGeneration == cloudAccountGeneration,
                      !Task.isCancelled,
                      !isICloudAccountSignedOut,
                      isICloudAccountIdentityVerified else {
                    completion(nil)
                    return
                }
            }
            guard isStarted,
                  preflightGeneration == cloudAccountGeneration,
                  !Task.isCancelled,
                  !isDeletingAllICloudData,
                  manualSyncTask == nil, backgroundSyncTask == nil,
                  accountVerificationTask == nil else {
                completion(nil)
                return
            }

            let operation = Task { @MainActor [weak self] in
                guard let self else {
                    completion(nil)
                    return
                }
                let generation = self.cloudAccountGeneration
                guard self.isStarted, !Task.isCancelled else {
                    completion(nil)
                    return
                }
                self.isPerformingManualSync = true
                self.postStateChanged()
                defer {
                    self.manualSyncTask = nil
                    if generation == self.cloudAccountGeneration {
                        self.isPerformingManualSync = false
                        self.postStateChanged()
                    }
                    if self.isStarted,
                       generation == self.cloudAccountGeneration,
                       self.isICloudAccountIdentityVerified,
                       !self.hasUnresolvedSyncFailures,
                       self.hasPendingSyncChanges {
                        self.scheduleLowPrioritySync()
                    }
                }
                do {
                    try await self.performManualSync()
                    guard self.isStarted,
                          generation == self.cloudAccountGeneration,
                          self.isICloudAccountIdentityVerified else {
                        completion(nil)
                        return
                    }
                    completion(nil)
                } catch {
                    guard self.isStarted,
                          generation == self.cloudAccountGeneration,
                          self.isICloudAccountIdentityVerified else {
                        completion(nil)
                        return
                    }
                    self.setError(error)
                    self.scheduleSyncRetryAfterFailure(error: error, reason: "manualSync")
                    completion(error as NSError)
                }
            }
            manualSyncTask = operation
        }
    }

    // Deletes the entire CloudKit sync zone (all synced data, for every device) and wipes all
    // local sync bookkeeping. If any category is still enabled, a fresh full re-upload starts.
    @objc func deleteAllICloudDataWithCompletion(_ completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            guard !isDeletingAllICloudData else {
                completion(nil)
                return
            }
            isDeletingAllICloudData = true
            defer { isDeletingAllICloudData = false }

            await refreshAccountStatus()
            guard !isICloudAccountSignedOut, isICloudAccountIdentityVerified else {
                completion(nil)
                return
            }
            _ = await acquireICloudAccountTransition()
            defer { releaseICloudAccountTransition() }
            guard !isICloudAccountSignedOut, isICloudAccountIdentityVerified else {
                completion(nil)
                return
            }
            let generation = cloudAccountGeneration
            let activeInitialQueueTask = initialQueueTask
            cancelInitialQueueTask()
            if let activeInitialQueueTask {
                await activeInitialQueueTask.value
            }
            await cancelAndAwaitLowPrioritySync()
            await awaitFinalDeviceRecordUpdate()
            resetSyncRetryBackoff()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else {
                completion(nil)
                return
            }
            setStatus(NSLocalizedString("Lösche iCloud-Daten…", comment: ""))
            postStateChanged()

            do {
                _ = try await database.deleteRecordZone(withID: zoneID)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                // Already gone — treat as success.
            } catch {
                guard generation == cloudAccountGeneration else {
                    completion(nil)
                    return
                }
                setError(error)
                completion(error as NSError)
                return
            }
            guard generation == cloudAccountGeneration else {
                completion(nil)
                return
            }
            // The remote zone is gone at this point. Persist that fact before any
            // fallible local cleanup so a crash/error cannot retain a false completion
            // marker and suppress the next full seed into the empty zone.
            invalidateInitialBackfillParticipation()

            let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey)
            do {
                if let accountRecordName {
                    try await deleteLocalOutboxEntries(for: accountRecordName)
                    try removePendingDeviceControlIntents(
                        accountRecordName: accountRecordName
                    )
                }
                try await Self.deleteAllPendingEpisodeStates()
                try await Self.deleteAllPendingSubscriptionStates()
                _ = try await Self.deleteSyncItemMetadata()
                _ = try await Self.deleteKnownRecordSystemFields()
                try await Self.removeAllLegacySyncItemMetadataSources()
                try await Self.removeAllLegacyKnownRecordSystemFieldFiles()
            } catch {
                handleLocalPersistenceFailure(error)
                completion(error as NSError)
                return
            }
            syncEngine = nil
            updateSyncEngineCallbackGate()
            resetAllLocalSyncMetadata(
                preservePendingDeviceControlIntents: true
            )
            clearPendingFinalDeviceRecordUpdateIntent()
            isDeletingAllICloudData = false
            // The "On iCloud" rows kept showing the pre-delete counts (stale cache,
            // refreshed only every 30s) — reflect the now-empty zone immediately.
            storeCloudInventory([:], reason: "deleteAllICloudData")

            if anySyncEnabled {
                initializeSyncEngineIfNeeded()
                resetInitialBackfillCursorsForEnabledOptions()
                requestedCloudInventoryRefreshReason = "deleteAllReseed"
                captureInitialBackfillTotalsFromCachedCountsIfNeeded()
                scheduleCurrentEnabledDataForUpload()
                setStatus(NSLocalizedString("iCloud-Daten gelöscht.", comment: ""))
            } else {
                setStatus(NSLocalizedString("Aus", comment: ""))
            }
            postStateChanged()
            postDevicesChanged()
            completion(nil)
        }
    }

    // Factory reset is local-only: stop every producer before Core Data objects are deleted,
    // otherwise those deletions can be captured as CloudKit tombstones and erase other devices.
    nonisolated static func deleteAllLocalOutboxEntriesForLocalReset() async throws {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            throw NSError(
                domain: "ICiCloudSyncLocalReset",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The local iCloud outbox could not be opened."]
            )
        }
        try await context.perform {
            let fetchRequest = NSFetchRequest<NSFetchRequestResult>(
                entityName: Self.localOutboxEntityName
            )
            let deleteRequest = NSBatchDeleteRequest(fetchRequest: fetchRequest)
            try context.execute(deleteRequest)
            context.reset()
        }
    }

    func captureLocalAppResetSyncOptions() {
        localAppResetSyncOptions = (
            episodes: episodesSyncEnabled,
            subscriptions: subscriptionsSyncEnabled,
            settings: settingsSyncEnabled
        )
    }

    func restoreLocalAppResetSyncOptions() {
        guard let options = localAppResetSyncOptions else { return }
        defaults.set(options.episodes, forKey: ICiCloudSyncEpisodesEnabled)
        defaults.set(options.subscriptions, forKey: ICiCloudSyncSubscriptionsEnabled)
        defaults.set(options.settings, forKey: ICiCloudSyncSettingsEnabled)
        localAppResetSyncOptions = nil
        updateSyncEngineCallbackGate()
    }

    func restartAfterFailedLocalAppReset(_ error: Error) {
        restoreLocalAppResetSyncOptions()
        isStarted = true
        resetForICloudAccountTransition(
            reinitializeEngine: true,
            transferPendingChanges: false
        )
        startPostInitializationRecoveryLifecycle()
        handleLocalPersistenceFailure(error)
        postStateChanged()
    }

    func recoverAfterFailedLocalAppReset(
        _ error: Error,
        completion: @escaping (NSError?) -> Void
    ) {
        restartAfterFailedLocalAppReset(error)
        completion(error as NSError)
    }

    @objc func recoverAfterLocalAppResetFailure(_ error: NSError) {
        restartAfterFailedLocalAppReset(error)
    }

    @objc func completeLocalAppReset() {
        localAppResetSyncOptions = nil
    }

    @objc func prepareForLocalAppResetWithCompletion(_ completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            captureLocalAppResetSyncOptions()
            isStarted = false
            cancelCloudInventoryRefreshForSync()
            subscriptionManager.setUnsubscribeCleanupRecoveryBlocked(true)
            localSubscriptionCleanupEpoch &+= 1
            cloudAccountGeneration &+= 1
            updateSyncEngineCallbackGate()

            let subscriptionCommitTasks = Array(localSubscriptionCommitTasks.values)
            let startupCleanupProtectionTask = startupCleanupProtectionTask
            startupCleanupProtectionTask?.cancel()
            let startupRecoveryTask = startupRecoveryTask
            startupRecoveryTask?.cancel()
            let foregroundSyncTask = foregroundSyncTask
            foregroundSyncTask?.cancel()
            let credentialReplayTask = localCredentialReplayTask
            credentialReplayTask?.cancel()
            let cleanupTask = localSubscriptionCleanupTask
            cleanupTask?.cancel()
            let tasks = [initialQueueTask, lowPrioritySyncTask, accountVerificationTask,
                         manualSyncTask, backgroundSyncTask, finalDeviceRecordUpdateTask,
                         localOutboxDrainTask].compactMap { $0 }
            for task in tasks { task.cancel() }
            for task in subscriptionCommitTasks { await task.value }
            if let startupCleanupProtectionTask {
                _ = await startupCleanupProtectionTask.value
            }
            if let startupRecoveryTask {
                await startupRecoveryTask.value
            }
            if let foregroundSyncTask {
                await foregroundSyncTask.value
            }
            for task in tasks { await task.value }
            if let credentialReplayTask {
                _ = await credentialReplayTask.value
            }
            if let cleanupTask {
                _ = await cleanupTask.value
            }
            initialQueueTask = nil
            lowPrioritySyncTask = nil
            accountVerificationTask = nil
            manualSyncTask = nil
            backgroundSyncTask = nil
            finalDeviceRecordUpdateTask = nil
            self.startupCleanupProtectionTask = nil
            self.startupRecoveryTask = nil
            startupRecoveryTaskIdentifier = nil
            self.foregroundSyncTask = nil
            foregroundSyncTaskIdentifier = nil
            localCredentialReplayTask = nil
            localSubscriptionCommitTasks.removeAll()
            localSubscriptionCleanupTask = nil
            localSubscriptionCleanupTaskIdentifier = nil
            localSubscriptionCleanupRequestedGeneration = 0
            localSubscriptionCleanupCompletedGeneration = 0
            localOutboxDrainTask = nil

            _ = await acquireICloudAccountTransition()
            syncEngine = nil

            do {
                try await Self.deleteAllPendingEpisodeStates()
                try await Self.deleteAllPendingSubscriptionStates()
                _ = try await Self.deleteSyncItemMetadata()
                _ = try await Self.deleteKnownRecordSystemFields()
                try await Self.removeAllLegacySyncItemMetadataSources()
                try await Self.removeAllLegacyKnownRecordSystemFieldFiles()
            } catch {
                releaseICloudAccountTransition()
                recoverAfterFailedLocalAppReset(error, completion: completion)
                return
            }

            do {
                try await Self.deleteAllLocalOutboxEntriesForLocalReset()
            } catch {
                releaseICloudAccountTransition()
                recoverAfterFailedLocalAppReset(error, completion: completion)
                return
            }

            defaults.set(false, forKey: ICiCloudSyncEpisodesEnabled)
            defaults.set(false, forKey: ICiCloudSyncSubscriptionsEnabled)
            defaults.set(false, forKey: ICiCloudSyncSettingsEnabled)
            updateSyncEngineCallbackGate()
            subscriptionManager.resetUnsubscribeCleanupProtectionForLocalAppReset()
            resetAllLocalSyncMetadata()
            setSyncMetadata(nil, forKey: Self.singletonClockFloorsKey)
            setSyncMetadata(nil, forKey: Self.localSubscriptionCleanupStatusKey)
            clearPendingFinalDeviceRecordUpdateIntent()
            setStatus(NSLocalizedString("Aus", comment: ""))
            postStateChanged()
            releaseICloudAccountTransition()
            completion(nil)
        }
    }

    func resetAllLocalSyncMetadata(preserveInitialBackfillState: Bool = false,
                                   preserveSameAccountUserDataState: Bool = false,
                                   preservePendingSingletonIntents: Bool = false,
                                   preservePendingDeviceControlIntents: Bool = false) {
        if !preserveSameAccountUserDataState {
            preserveCurrentSingletonMetadataClockFloors()
        }
        settingsDebounceWorkItem?.cancel()
        settingsDebounceWorkItem = nil
        settingsChangeCheckRevision &+= 1
        scrollDebounceWorkItem?.cancel()
        scrollDebounceWorkItem = nil
        applyPendingDebounceWorkItem?.cancel()
        applyPendingDebounceWorkItem = nil
        localOutboxDrainTask?.cancel()
        localOutboxDrainTask = nil
        localOutboxDrainRequested = false
        localOutboxBatchDepth = 0
        localOutboxDrainDeferred = false
        resetSyncRetryBackoff()
        cancelFinalDeviceRecordUpdate()
        requiresImmediateFinalDeviceRecordResend = false
        requiresImmediateSingletonRecordResend = false

        cloudAccountGeneration &+= 1
        updateSyncEngineCallbackGate()
        cloudInventoryRefreshGeneration &+= 1
        cloudInventoryCancellationToken?.cancel()
        cloudInventoryCancellationToken = nil
        cloudInventoryOperation?.cancel()
        cloudInventoryOperation = nil
        isFetchingCloudInventory = false
        cloudInventoryRefreshErrorText = nil
        pendingCloudInventoryRefreshReason = nil
        requestedCloudInventoryRefreshReason = nil
        requestedCloudInventoryRefreshMustRun = false
        recentlyUploadedRecordVersions.removeAll()
        setSyncMetadata(nil, forKey: Self.engineStateKey)
        Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
        if !preservePendingDeviceControlIntents {
            Self.removeSyncMetadataValue(forKey: Self.pendingDeviceControlIntentsKey)
        }
        for key in [Self.deviceCacheKey, Self.pendingEpisodeStatesKey, Self.pendingSubscriptionPayloadsKey,
                    Self.pendingSubscriptionFetchCompleteKey,
                    Self.transitionalSubscriptionInventoryRecordsKey] {
            setSyncMetadata(nil, forKey: key)
        }
        for key in [Self.lastSyncDateKey, Self.deviceRecordShouldStampSyncDateKey, Self.cloudInventoryKey,
                    Self.cloudInventoryPayloadScanCompletedKey,
                    Self.knownRecordSystemFieldsPruneVersionsKey] {
            defaults.removeObject(forKey: key)
        }
        if !preserveSameAccountUserDataState {
            setSyncMetadata(nil, forKey: Self.pendingInitialSettingsPayloadKey)
            if !preservePendingSingletonIntents {
                setSyncMetadata(nil, forKey: Self.pendingSingletonUploadIntentsKey)
            }
            for key in [Self.settingsLocalModifiedDateKey, Self.settingsSyncedHashKey,
                        Self.scrollPositionsLocalModifiedDateKey, Self.suppressSubscriptionDeletionsKey,
                        Self.subscriptionListSettingsLocalModifiedDateKey,
                        Self.subscriptionListSettingsBaselineKey] {
                defaults.removeObject(forKey: key)
            }
        }
        cachedSyncTotalCounts = nil
        pendingInitialUploadBatches.removeAll()
        localOutboxSnapshotCache = [:]
        localOutboxRevisionsToDelete = [:]
        localOutboxRevisionsToAcknowledge = [:]
        localOutboxRevisionsToRearm = [:]
        remoteAppliedObjectIDs.removeAll()
        needsSubscriptionListSortApply = false
        didPruneEpisodeLocalModifiedDates = false
        lastForegroundSyncDate = nil
        hasUnresolvedSyncFailures = false
        requiresSyncEngineStateRollbackAfterPersistenceFailure = false
        isApplyingRemoteChange = false
        isPerformingManualSync = false
        deviceRecordShouldStampSyncDate = false
        syncedUserDataInCurrentRun = false
        if !preserveInitialBackfillState {
            clearInitialUploadCursors()
            invalidateInitialBackfillParticipation()
        }
        clearSyncActivity()
        clearError()
    }

    func preserveCurrentSingletonMetadataClockFloors() {
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else { return }
        for recordName in [
            RecordPrefix.appSettings,
            RecordPrefix.listScrollPositions,
            RecordPrefix.subscriptionListSettings,
        ] {
            guard let date = singletonMetadataClockFloor(recordName: recordName) else { continue }
            do {
                try persistSingletonClockFloor(
                    date,
                    recordName: recordName,
                    accountRecordName: accountRecordName
                )
            } catch {
                handleLocalPersistenceFailure(error)
                return
            }
        }
    }

    @objc func shouldHandleRemoteNotification(_ userInfo: NSDictionary) -> Bool {
        guard let notification = userInfo as? [AnyHashable: Any] else { return false }
        return CKNotification(fromRemoteNotificationDictionary: notification) != nil
    }

    @objc func performBackgroundSyncWithCompletion(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        let preflightGeneration = cloudAccountGeneration
        Task { @MainActor in
            guard isStarted,
                  preflightGeneration == cloudAccountGeneration,
                  !isDeletingAllICloudData else {
                completion(.noData)
                return
            }
            guard anySyncEnabled else {
                completion(.noData)
                return
            }
            await refreshAccountStatus()
            guard isStarted,
                  preflightGeneration == cloudAccountGeneration,
                  !Task.isCancelled,
                  !isDeletingAllICloudData,
                  !isICloudAccountSignedOut, isICloudAccountIdentityVerified else {
                completion(.noData)
                return
            }
            guard backgroundSyncTask == nil, manualSyncTask == nil,
                  accountVerificationTask == nil else {
                completion(.noData)
                return
            }

            let operation = Task { @MainActor [weak self] in
                guard let self else {
                    completion(.noData)
                    return
                }
                let generation = self.cloudAccountGeneration
                guard self.isStarted, !Task.isCancelled else {
                    completion(.noData)
                    return
                }
                await cancelAndAwaitLowPrioritySync()
                guard self.isStarted,
                      generation == self.cloudAccountGeneration,
                      !Task.isCancelled,
                      self.isICloudAccountIdentityVerified else {
                    completion(.noData)
                    return
                }
                self.initializeSyncEngineIfNeeded()
                self.hasUnresolvedSyncFailures = false
                let syncCycleGeneration = self.beginSyncCycle()
                defer {
                    self.endSyncCycle(syncCycleGeneration)
                    self.backgroundSyncTask = nil
                    if self.isStarted,
                       generation == self.cloudAccountGeneration,
                       self.isICloudAccountIdentityVerified,
                       !self.hasUnresolvedSyncFailures,
                       self.hasPendingSyncChanges {
                        self.scheduleLowPrioritySync()
                    }
                }

                do {
                    if let syncEngine = self.syncEngine {
                        if self.requiresInitialBackfillFetchBeforeUpload {
                            try await self.fetchChangesForInitialBackfillMigration(syncEngine)
                        } else {
                            try await syncEngine.fetchChanges()
                        }
                        guard generation == self.cloudAccountGeneration,
                              self.isICloudAccountIdentityVerified else {
                            completion(.noData)
                            return
                        }
                        if !self.hasUnresolvedSyncFailures,
                           self.hasPendingSyncChanges {
                            let deferredLocalChanges = try await self.sendChangesAndApplyCallbackOutcomes(
                                syncEngine,
                                generation: generation
                            )
                            if deferredLocalChanges {
                                completion(.newData)
                                return
                            }
                        }
                    }
                    guard generation == self.cloudAccountGeneration,
                          self.isICloudAccountIdentityVerified else {
                        completion(.noData)
                        return
                    }
                    if !self.hasUnresolvedSyncFailures {
                        self.markSyncCompletedIfFinished(allowActiveSyncCycle: true)
                        completion(.newData)
                    } else {
                        self.postStateChanged()
                        completion(.failed)
                    }
                } catch {
                    guard generation == self.cloudAccountGeneration,
                          self.isICloudAccountIdentityVerified else {
                        completion(.noData)
                        return
                    }
                    self.setError(error)
                    self.scheduleSyncRetryAfterFailure(error: error, reason: "backgroundSync")
                    completion(.failed)
                }
            }
            backgroundSyncTask = operation
        }
    }

    // Last known hard cloud inventory (persisted, so the screen can show the previous
    // state right away — even before sync is ever enabled).
    @objc var cloudInventory: ICiCloudSyncCloudInventory? {
        guard let stored = defaults.dictionary(forKey: Self.cloudInventoryKey),
              let fetchDate = stored["fetchDate"] as? Date else { return nil }
        return ICiCloudSyncCloudInventory(episodeStates: (stored["episodeStates"] as? NSNumber)?.intValue ?? 0,
                                          subscriptions: (stored["subscriptions"] as? NSNumber)?.intValue ?? 0,
                                          settings: (stored["settings"] as? NSNumber)?.intValue ?? 0,
                                          fetchDate: fetchDate)
    }

    // Counts the records that are actually ON iCloud, by type, with a full zone listing
    // (metadata only, no payloads). Deliberately not a CKQuery: recordName is not
    // queryable without dashboard-managed indexes. Runs independently of the sync engine
    // and of the enabled switches.
    @objc func refreshCloudInventory() {
        refreshCloudInventory(reason: "settingsView")
    }

    @objc func requestCloudInventoryRefreshAfterSync() {
        requestedCloudInventoryRefreshReason = "settingsActionAfterSync"
        cancelCloudInventoryRefreshForSync()
    }

    @objc func requestCloudInventoryRefreshAfterOptionChange() {
        requestedCloudInventoryRefreshReason = "settingsOptionChangeAfterSync"
        requestedCloudInventoryRefreshMustRun = cancelCloudInventoryRefreshForSync()
    }

    @discardableResult
    func cancelCloudInventoryRefreshForSync() -> Bool {
        guard isFetchingCloudInventory
                || cloudInventoryCancellationToken != nil
                || cloudInventoryOperation != nil else { return false }
        cloudInventoryRefreshGeneration &+= 1
        cloudInventoryCancellationToken?.cancel()
        cloudInventoryCancellationToken = nil
        cloudInventoryOperation?.cancel()
        cloudInventoryOperation = nil
        isFetchingCloudInventory = false
        pendingCloudInventoryRefreshReason = nil
        postStateChanged()
        return true
    }

    func runRequestedCloudInventoryRefresh() {
        guard let reason = requestedCloudInventoryRefreshReason else { return }
        requestedCloudInventoryRefreshReason = nil
        let mustRun = requestedCloudInventoryRefreshMustRun
        requestedCloudInventoryRefreshMustRun = false
        guard reason != "settingsOptionChangeAfterSync"
                || syncedUserDataInCurrentRun
                || mustRun else { return }
        refreshCloudInventory(reason: reason, afterCompletedSync: true)
    }

    func transitionalSubscriptionInventoryRecords() -> [String: String] {
        Self.syncMetadataValue(forKey: Self.transitionalSubscriptionInventoryRecordsKey) as? [String: String] ?? [:]
    }

    func knownRecordSystemFieldsPruneVersion(for accountRecordName: String) -> Int {
        (defaults.dictionary(forKey: Self.knownRecordSystemFieldsPruneVersionsKey)?[accountRecordName] as? NSNumber)?.intValue ?? 0
    }

    func setKnownRecordSystemFieldsPruneVersion(_ version: Int, for accountRecordName: String) {
        var versions = defaults.dictionary(forKey: Self.knownRecordSystemFieldsPruneVersionsKey) ?? [:]
        versions[accountRecordName] = version
        defaults.set(versions, forKey: Self.knownRecordSystemFieldsPruneVersionsKey)
    }

    func requestKnownRecordSystemFieldsPruneIfNeeded(accountRecordName: String) {
        guard knownRecordSystemFieldsPruneVersion(for: accountRecordName)
                < Self.knownRecordSystemFieldsPruneVersion else { return }
        if pendingCloudInventoryRefreshReason == nil {
            pendingCloudInventoryRefreshReason = "knownSystemFieldsCleanup"
        }
        runPendingCloudInventoryRefreshIfNeeded()
    }

    nonisolated static func cloudInventoryZoneIsMissing(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        switch cloudError.code {
        case .zoneNotFound, .userDeletedZone, .unknownItem:
            return true
        case .partialFailure:
            let nestedErrors = cloudError.partialErrorsByItemID?.values.map { $0 } ?? []
            return !nestedErrors.isEmpty && nestedErrors.allSatisfy { cloudInventoryZoneIsMissing($0) }
        default:
            return false
        }
    }

    func refreshCloudInventory(reason: String, afterCompletedSync: Bool = false) {
        guard isICloudAccountIdentityVerified, !isICloudAccountSignedOut else {
            pendingCloudInventoryRefreshReason = reason
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshAccountStatus()
                guard self.isICloudAccountIdentityVerified, !self.isICloudAccountSignedOut else { return }
                self.runPendingCloudInventoryRefreshIfNeeded()
            }
            return
        }
        guard afterCompletedSync || !syncInProgress else {
            requestedCloudInventoryRefreshReason = reason
            return
        }
        guard !isFetchingCloudInventory else {
            // A refresh is already in flight; remember the reason so it re-runs afterwards.
            // No diagnostics line here — this "skipped" path fired 253× in one capture (pure noise).
            pendingCloudInventoryRefreshReason = reason
            return
        }
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else {
            cloudInventoryRefreshErrorText = NSLocalizedString("iCloud data counts could not be updated.", comment: "")
            postStateChanged()
            return
        }
        let generation = cloudAccountGeneration
        cloudInventoryRefreshGeneration &+= 1
        let refreshGeneration = cloudInventoryRefreshGeneration
        let cancellationToken = ICCloudInventoryCancellationToken()
        cloudInventoryCancellationToken = cancellationToken
        pendingCloudInventoryRefreshReason = nil
        cloudInventoryRefreshErrorText = nil
        isFetchingCloudInventory = true
        postStateChanged()
        var metadata: [String: Any] = ["reason": reason]
        metadata.merge(syncDiagnosticsMetadata()) { current, _ in current }
        logSyncEvent("Cloud-Inventar-Abfrage gestartet", metadata: metadata)

        let shouldPruneKnownRecordSystemFields = knownRecordSystemFieldsPruneVersion(for: accountRecordName)
            < Self.knownRecordSystemFieldsPruneVersion

        func startCloudInventory(pruneCandidates: [String: Data]?) {
            guard refreshGeneration == cloudInventoryRefreshGeneration,
                  isFetchingCloudInventory,
                  !cancellationToken.isCancelled else { return }
            let shouldInspectPayloads = !defaults.bool(forKey: Self.cloudInventoryPayloadScanCompletedKey)
            let box = ICCloudInventoryCountsBox(
                transitionalSubscriptionRecordChangeTags: transitionalSubscriptionInventoryRecords(),
                inspectSubscriptionPayloads: shouldInspectPayloads
            )
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            // Payloads are required once to identify records written by the unreleased
            // same-type tombstone protocol. Thereafter the record change tag is sufficient;
            // normal count refreshes transfer only CloudKit system metadata.
            configuration.desiredKeys = shouldInspectPayloads ? ["payload"] : []
            let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                              configurationsByRecordZoneID: [zoneID: configuration])
            operation.fetchAllChanges = true
            operation.qualityOfService = .utility
            operation.recordWasChangedBlock = { _, result in
                switch result {
                case .success(let record):
                    box.record(record)
                case .failure:
                    box.markRecordFetchFailure()
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                box.remove(recordName: recordID.recordName)
            }
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let result):
                    box.markZoneFetchCompleted(moreComing: result.moreComing)
                case .failure(let error):
                    if Self.cloudInventoryZoneIsMissing(error) {
                        box.markZoneMissing()
                    } else {
                        box.markRecordFetchFailure()
                    }
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard generation == self.cloudAccountGeneration,
                          refreshGeneration == self.cloudInventoryRefreshGeneration,
                          !cancellationToken.isCancelled else { return }
                    defer {
                        if generation == self.cloudAccountGeneration,
                           refreshGeneration == self.cloudInventoryRefreshGeneration {
                            self.cloudInventoryCancellationToken = nil
                            self.cloudInventoryOperation = nil
                            self.isFetchingCloudInventory = false
                            self.runPendingCloudInventoryRefreshIfNeeded()
                        }
                    }

                    let countsByType: [String: Int]
                    let observedRecordNames: Set<String>
                    let zoneIsMissing: Bool
                    switch result {
                    case .success:
                        zoneIsMissing = box.observedMissingZone()
                        guard zoneIsMissing || box.inventoryIsComplete() else {
                            self.cloudInventoryRefreshErrorText = NSLocalizedString("iCloud data counts could not be updated.", comment: "")
                            self.logSyncEvent("Cloud-Inventar-Abfrage unvollständig", metadata: ["reason": reason])
                            self.postStateChanged()
                            return
                        }
                        countsByType = zoneIsMissing ? [:] : box.snapshot()
                        observedRecordNames = zoneIsMissing ? [] : box.observedRecordNames()
                    case .failure(let error):
                        zoneIsMissing = box.observedMissingZone() || Self.cloudInventoryZoneIsMissing(error)
                        guard zoneIsMissing else {
                            self.cloudInventoryRefreshErrorText = NSLocalizedString("iCloud data counts could not be updated.", comment: "")
                            var metadata = self.cloudKitErrorMetadata(error)
                            metadata["reason"] = reason
                            metadata.merge(self.syncDiagnosticsMetadata()) { current, _ in current }
                            self.logSyncEvent("Cloud-Inventar-Abfrage fehlgeschlagen", metadata: metadata)
                            self.postStateChanged()
                            return
                        }
                        countsByType = [:]
                        observedRecordNames = []
                    }

                    guard self.defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }
                    self.setSyncMetadata(
                        zoneIsMissing ? [String: String]() : box.transitionalSubscriptionRecords(),
                        forKey: Self.transitionalSubscriptionInventoryRecordsKey
                    )
                    if shouldInspectPayloads {
                        self.setSyncMetadata(true, forKey: Self.cloudInventoryPayloadScanCompletedKey)
                    }
                    self.storeCloudInventory(countsByType, reason: reason)
                    if !zoneIsMissing {
                        self.fetchDeviceRecordsForInventory(box.deviceIDs(), generation: generation)
                    }

                    guard let pruneCandidates else { return }
                    do {
                        let deletedCount = try await Self.pruneKnownRecordSystemFields(
                            keeping: observedRecordNames,
                            candidatesAtInventoryStart: pruneCandidates,
                            accountRecordName: accountRecordName,
                            cancellationToken: cancellationToken
                        )
                        guard generation == self.cloudAccountGeneration,
                              refreshGeneration == self.cloudInventoryRefreshGeneration,
                              !cancellationToken.isCancelled,
                              self.defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }
                        self.setKnownRecordSystemFieldsPruneVersion(
                            Self.knownRecordSystemFieldsPruneVersion,
                            for: accountRecordName
                        )
                        if deletedCount > 0 {
                            self.logSyncEvent("Lokale CloudKit-Systemfelder bereinigt", metadata: [
                                "reason": reason,
                                "deleted": deletedCount,
                                "remaining": observedRecordNames.count,
                            ])
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        self.logSyncEvent("Cloud-Inventar-Bereinigung fehlgeschlagen", metadata: [
                            "reason": reason,
                            "error": (error as NSError).localizedDescription,
                        ])
                    }
                }
            }
            cloudInventoryOperation = operation
            database.add(operation)
        }

        if shouldPruneKnownRecordSystemFields {
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let candidates = try await Self.snapshotKnownRecordSystemFieldsForPruning(
                        accountRecordName: accountRecordName,
                        cancellationToken: cancellationToken
                    )
                    guard generation == self.cloudAccountGeneration,
                          refreshGeneration == self.cloudInventoryRefreshGeneration,
                          self.defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else {
                        return
                    }
                    startCloudInventory(pruneCandidates: candidates)
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == self.cloudAccountGeneration,
                          refreshGeneration == self.cloudInventoryRefreshGeneration else { return }
                    self.logSyncEvent("Cloud-Inventar-Bereinigung konnte nicht vorbereitet werden", metadata: [
                        "reason": reason,
                        "error": (error as NSError).localizedDescription,
                    ])
                    guard self.defaults.string(forKey: Self.accountUserRecordNameKey) == accountRecordName else { return }
                    startCloudInventory(pruneCandidates: nil)
                }
            }
        } else {
            startCloudInventory(pruneCandidates: nil)
        }
    }

    // The device list used to stay empty ("Noch keine synchronisierten Geräte") until a
    // category was enabled, because the cache only fills via sync engine events. The
    // The inventory fetch above carries only the shared payload key; fetch the handful
    // of ICDevice records separately and feed the cache — the list is then correct as
    // soon as the sync page opens, even before anything is enabled.
    func fetchDeviceRecordsForInventory(_ recordIDs: [CKRecord.ID], generation: Int) {
        guard !recordIDs.isEmpty else { return }
        let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
        operation.qualityOfService = .utility
        operation.fetchRecordsResultBlock = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.cloudAccountGeneration else { return }
                self.postDevicesChanged()
            }
        }
        operation.perRecordResultBlock = { [weak self] _, result in
            guard case .success(let record) = result else { return }
            Task { @MainActor [weak self] in
                guard let self, let payload = self.payloadDictionary(from: record) else { return }
                guard generation == self.cloudAccountGeneration else { return }
                self.updateDeviceCache(with: payload)
            }
        }
        database.add(operation)
    }

    func storeCloudInventory(_ countsByType: [String: Int], reason: String) {
        // The three rows count USER objects only. Helper records (scroll positions,
        // the sort-order singleton, device entries) must not leak into them — they
        // showed "Einstellungen: 1" although settings sync was never enabled.
        let fetchDate = Date()
        let stored: [String: Any] = [
            "episodeStates": countsByType[RecordKind.episodeState] ?? 0,
            "subscriptions": countsByType[RecordKind.subscription] ?? 0,
            "settings": countsByType[RecordKind.appSettings] ?? 0,
            "fetchDate": fetchDate,
        ]
        setSyncMetadata(stored, forKey: Self.cloudInventoryKey)
        logSyncEvent("Cloud-Inventar aktualisiert", metadata: [
            "reason": reason,
            "episodeStates": stored["episodeStates"] ?? 0,
            "subscriptions": stored["subscriptions"] ?? 0,
            "settings": stored["settings"] ?? 0,
            "fetchDate": fetchDate,
            "byType": countsByType.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","),
        ])
        postStateChanged()
    }

    func runPendingCloudInventoryRefreshIfNeeded() {
        guard let reason = pendingCloudInventoryRefreshReason else { return }
        pendingCloudInventoryRefreshReason = nil
        refreshCloudInventory(reason: reason)
    }

    func performManualSync() async throws {
        guard !Task.isCancelled else { return }
        guard anySyncEnabled else {
            clearError()
            setStatus(NSLocalizedString("Keine Sync-Kategorie aktiviert.", comment: ""))
            return
        }
        guard !isICloudAccountSignedOut, isICloudAccountIdentityVerified else { return }
        let generation = cloudAccountGeneration

        await cancelAndAwaitLowPrioritySync()
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
        resetSyncRetryBackoff()
        initializeSyncEngineIfNeeded()
        captureInitialBackfillTotalsFromCachedCountsIfNeeded()
        hasUnresolvedSyncFailures = false
        let syncCycleGeneration = beginSyncCycle()
        defer { endSyncCycle(syncCycleGeneration) }
        setStatus(NSLocalizedString("Synchronisiere…", comment: ""))
        postStateChanged()
        await initialQueueTask?.value
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
        await applyPendingEpisodeStates()
        await applyPendingSubscriptions()
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
              !hasUnresolvedSyncFailures else { return }
        let outboxReadSucceeded = await drainLocalOutbox()
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
              outboxReadSucceeded, !hasUnresolvedSyncFailures else { return }
        queueDeviceRecordForPendingUserDataIfNeeded()
        postStateChanged()

        if let syncEngine {
            if requiresInitialBackfillFetchBeforeUpload {
                try await fetchChangesForInitialBackfillMigration(syncEngine)
                guard generation == cloudAccountGeneration,
                      isICloudAccountIdentityVerified else { return }
            } else {
                let deferredLocalChanges = try await sendChangesAndApplyCallbackOutcomes(
                    syncEngine,
                    generation: generation
                )
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
                if deferredLocalChanges { return }
                try await syncEngine.fetchChanges()
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
                if !hasUnresolvedSyncFailures, hasPendingSyncChanges {
                    let deferredLocalChanges = try await sendChangesAndApplyCallbackOutcomes(
                        syncEngine,
                        generation: generation
                    )
                    guard generation == cloudAccountGeneration,
                          isICloudAccountIdentityVerified else { return }
                    if deferredLocalChanges { return }
                }
            }
        }

        if !hasUnresolvedSyncFailures {
            markSyncCompletedIfFinished(allowActiveSyncCycle: true)
        } else {
            postStateChanged()
        }
    }

    var database: CKDatabase {
        container.privateCloudDatabase
    }

    var deviceID: String? {
        do {
            return try Self.resolveInstallationDeviceID()
        } catch {
            handleLocalPersistenceFailure(error)
            return nil
        }
    }

    func initializeSyncEngineIfNeeded() {
        let isRollingBackState = requiresSyncEngineStateRollbackAfterPersistenceFailure
        if isRollingBackState {
            syncEngine = nil
            updateSyncEngineCallbackGate()
            pendingInitialUploadBatches.removeAll()
            requiresSyncEngineStateRollbackAfterPersistenceFailure = false
        }
        guard syncEngine == nil else { return }

        var configuration = CKSyncEngine.Configuration(database: database,
                                                       stateSerialization: loadStateSerialization(),
                                                       delegate: self)
        configuration.automaticallySync = false
        let engine = CKSyncEngine(configuration)
        syncEngine = engine
        updateSyncEngineCallbackGate()
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        if isRollingBackState {
            scheduleCurrentEnabledDataForUpload()
        }
    }

    func updateSyncEngineCallbackGate() {
        syncEngineCallbackGate.update(syncEngine: syncEngine,
                                      generation: cloudAccountGeneration,
                                      isSignedOut: isICloudAccountSignedOut,
                                      isAccountIdentityVerified: isICloudAccountIdentityVerified,
                                      accountRecordName: defaults.string(forKey: Self.accountUserRecordNameKey),
                                      episodesSyncEnabled: episodesSyncEnabled,
                                      subscriptionsSyncEnabled: subscriptionsSyncEnabled)
    }

    func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard !isICloudAccountResetRequired else { return nil }
        guard let data = Self.syncMetadataValue(forKey: Self.engineStateKey) as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    nonisolated func persistStateSerialization(
        _ serialization: CKSyncEngine.State.Serialization
    ) async throws {
        try await Task.detached(priority: .utility) {
            let data = try JSONEncoder().encode(serialization)
            _ = try Self.writeSyncMetadataValue(data, forKey: Self.engineStateKey)
        }.value
    }

    func logSyncEvent(_ message: String, metadata: [String: Any] = [:]) {
        var details = metadata
        details["episodesSyncEnabled"] = episodesSyncEnabled
        details["subscriptionsSyncEnabled"] = subscriptionsSyncEnabled
        details["settingsSyncEnabled"] = settingsSyncEnabled
        details["anySyncEnabled"] = anySyncEnabled
        details["actor"] = "MainActor"
        details["syncEngineInitialized"] = syncEngine != nil
        details["initialQueueTaskActive"] = initialQueueTask != nil
        details["lowPrioritySyncTaskActive"] = lowPrioritySyncTask != nil
        details["isMainThread"] = Thread.isMainThread
        details["threadID"] = pthread_mach_thread_np(pthread_self())
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }

    func scheduleCurrentEnabledDataForUpload() {
        guard !isDeletingAllICloudData,
              !isICloudAccountSignedOut, isICloudAccountIdentityVerified,
              !requiresInitialBackfillFetchBeforeUpload else { return }
        cancelInitialQueueTask()
        initialQueueTaskGeneration &+= 1
        let queueTaskGeneration = initialQueueTaskGeneration
        let expectedCloudAccountGeneration = cloudAccountGeneration
        let expectedAccountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey)
        let snapshot = initialUploadSnapshot()
        logSyncEvent("Initiale iCloud-Queue geplant", metadata: [
            "snapshotEpisodesSyncEnabled": snapshot.episodesSyncEnabled,
            "snapshotSubscriptionsSyncEnabled": snapshot.subscriptionsSyncEnabled,
            "snapshotSettingsSyncEnabled": snapshot.settingsSyncEnabled,
        ])
        initialQueueTask = Task.detached(priority: .utility) { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.logSyncEvent("Initiale iCloud-Queue gestartet")
            }
            let plan = await Self.buildInitialUploadPlan(from: snapshot)
            guard !Task.isCancelled else { return }
            await self.applyInitialUploadPlan(
                plan,
                expectedCloudAccountGeneration: expectedCloudAccountGeneration,
                expectedAccountRecordName: expectedAccountRecordName,
                queueTaskGeneration: queueTaskGeneration
            )
        }
    }

    func cancelInitialQueueTask() {
        initialQueueTaskGeneration &+= 1
        if initialQueueTask != nil {
            logSyncEvent("Initiale iCloud-Queue abgebrochen")
        }
        initialQueueTask?.cancel()
        initialQueueTask = nil
    }

    func cancelAndAwaitInitialQueueTask() async {
        let activeInitialQueueTask = initialQueueTask
        cancelInitialQueueTask()
        if let activeInitialQueueTask {
            await activeInitialQueueTask.value
        }
    }

    func scheduleLowPrioritySync() {
        guard !isDeletingAllICloudData,
              anySyncEnabled, !isICloudAccountSignedOut, isICloudAccountIdentityVerified,
              accountVerificationTask == nil, manualSyncTask == nil, backgroundSyncTask == nil,
              lowPrioritySyncTask == nil else { return }
        // No "scheduled" diagnostics line — it fired 171× in one capture and only brackets the
        // "started"/"completed" events that already mark real sync activity.
        // CKSyncEngine asserts when sendChanges recurses from one of its delegate tasks.
        // Detached scheduling drops that callback task context before the manager syncs.
        lowPrioritySyncTask = Task.detached(priority: .background) { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.performLowPrioritySync()
        }
    }

    func performLowPrioritySync() async {
        var shouldScheduleContinuation = false
        defer {
            if !Task.isCancelled {
                lowPrioritySyncTask = nil
                if shouldScheduleContinuation {
                    scheduleLowPrioritySync()
                }
            }
        }
        let generation = cloudAccountGeneration
        guard anySyncEnabled, !isICloudAccountSignedOut, isICloudAccountIdentityVerified,
              !Task.isCancelled else {
            return
        }

        initializeSyncEngineIfNeeded()
        captureInitialBackfillTotalsFromCachedCountsIfNeeded()
        if requiresInitialBackfillFetchBeforeUpload {
            setStatus(NSLocalizedString("Vorhandene iCloud-Daten werden vor dem Hochladen geprüft…", comment: ""))
        } else if hasInitialUploadBackfillWork {
            setStatus(backfillProgressStatusText())
        } else {
            setStatus(NSLocalizedString("Synchronisiere…", comment: ""))
        }
        postStateChanged()
        hasUnresolvedSyncFailures = false
        await applyPendingEpisodeStates()
        await applyPendingSubscriptions()
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
              !Task.isCancelled, !hasUnresolvedSyncFailures else {
            postStateChanged()
            return
        }
        let outboxReadSucceeded = await drainLocalOutbox()
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
              !Task.isCancelled, outboxReadSucceeded, !hasUnresolvedSyncFailures else {
            postStateChanged()
            return
        }
        let syncCycleGeneration = beginSyncCycle()
        defer { endSyncCycle(syncCycleGeneration) }
        logSyncEvent("iCloud Sync mit niedriger Priorität gestartet", metadata: syncDiagnosticsMetadata())
        postStateChanged()

        do {
            if let syncEngine = syncEngine {
                if requiresInitialBackfillFetchBeforeUpload {
                    try await fetchChangesForInitialBackfillMigration(syncEngine)
                    guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                          !Task.isCancelled else { return }
                } else {
                    let deferredLocalChanges = try await sendChangesAndApplyCallbackOutcomes(
                        syncEngine,
                        generation: generation
                    )
                    guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                          !Task.isCancelled else { return }
                    if deferredLocalChanges {
                        shouldScheduleContinuation = anySyncEnabled
                            && !hasUnresolvedSyncFailures
                            && hasPendingSyncChanges
                        return
                    }
                    // While the initial backfill still has pages to upload, only send — defer the
                    // fetch until everything is up. The last page clears the cursor before it
                    // syncs, so that run still fetches. This stops the status flipping up/down
                    // every page and saves a network round-trip per page.
                    if !hasInitialUploadBackfillWork || hasIncompletePendingSubscriptionFetch {
                        try await syncEngine.fetchChanges()
                        guard generation == cloudAccountGeneration,
                              isICloudAccountIdentityVerified,
                              !Task.isCancelled else { return }
                        // The initial settings record is deliberately queued only after the
                        // first complete fetch proves that iCloud has none. Send that record in
                        // this same cycle; scheduling another send+fetch cycle added one whole
                        // CloudKit round trip to a one-record settings sync.
                        if hasPendingSyncChanges {
                            let deferredLocalChanges = try await sendChangesAndApplyCallbackOutcomes(
                                syncEngine,
                                generation: generation
                            )
                            guard generation == cloudAccountGeneration,
                                  isICloudAccountIdentityVerified,
                                  !Task.isCancelled else { return }
                            if deferredLocalChanges {
                                shouldScheduleContinuation = anySyncEnabled
                                    && !hasUnresolvedSyncFailures
                                    && hasPendingSyncChanges
                                return
                            }
                        }
                    }
                }
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  !Task.isCancelled else { return }
            if !hasUnresolvedSyncFailures {
                markSyncCompletedIfFinished(allowActiveSyncCycle: true)
            } else {
                postStateChanged()
            }
            shouldScheduleContinuation = anySyncEnabled
                && !hasUnresolvedSyncFailures
                && hasPendingSyncChanges
        } catch {
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  !Task.isCancelled else { return }
            setError(error)
            scheduleSyncRetryAfterFailure(error: error, reason: "lowPrioritySync")
        }
    }

    func cancelLowPrioritySyncTask() {
        if lowPrioritySyncTask != nil {
            logSyncEvent("iCloud Sync mit niedriger Priorität abgebrochen")
        }
        lowPrioritySyncTask?.cancel()
        lowPrioritySyncTask = nil
    }

    func cancelAndAwaitLowPrioritySync() async {
        guard let activeLowPrioritySyncTask = lowPrioritySyncTask else { return }
        logSyncEvent("iCloud Sync mit niedriger Priorität wird vor exklusiver Cloud-Arbeit beendet")
        activeLowPrioritySyncTask.cancel()
        await activeLowPrioritySyncTask.value
        lowPrioritySyncTask = nil
    }

    // CKSyncEngine runs with automaticallySync = false and never retries on its own.
    // Without this, a failed first sync (flaky network or zone setup right after
    // enabling a category) left "could not complete" standing indefinitely — nothing
    // ran again until the user tapped manual sync. Transient failures are retried
    // with exponential backoff (or the server-provided retry-after) while the app
    // is running; the backoff resets on the next completed sync.
    func scheduleSyncRetryAfterFailure(error: Error, reason: String) {
        if Self.isDeterministicLegacySyncItemMetadataError(error) {
            logSyncEvent("Deterministischer Legacy-Metadatenfehler wird nicht automatisch wiederholt", metadata: [
                "reason": reason,
                "domain": (error as NSError).domain,
                "code": (error as NSError).code,
            ])
            return
        }
        let ckError = error as? CKError
        scheduleSyncRetryAfterFailure(code: ckError?.code,
                                      retryAfter: ckError?.retryAfterSeconds,
                                      reason: reason,
                                      error: ckError)
    }

    func scheduleSyncRetryAfterFailure(code: CKError.Code?, retryAfter: TimeInterval? = nil, reason: String, error: CKError? = nil) {
        guard isStarted, anySyncEnabled || hasPendingDeviceControlIntents else { return }
        if let error, !Self.isTransientCloudKitError(error) {
            return
        }
        if error == nil, let code, !Self.isTransientCloudKitErrorCode(code) {
            return
        }
        let requiresAccountVerification = isICloudAccountSignedOut
            || !isICloudAccountIdentityVerified
            || reason == "accountStatus"
            || reason == "accountIdentity"
        if syncRetryWorkItem != nil {
            guard requiresAccountVerification && !syncRetryRequiresAccountVerification else { return }
            syncRetryWorkItem?.cancel()
            syncRetryWorkItem = nil
            syncRetryRequiresAccountVerification = false
            syncRetryAttempt = 0
        }
        syncRetryAttempt += 1
        let backoff = min(300.0, 15.0 * pow(2.0, Double(syncRetryAttempt - 1)))
        let delay = retryAfter ?? backoff
        logSyncEvent("Sync-Wiederholung geplant", metadata: [
            "delaySeconds": Int(delay),
            "attempt": syncRetryAttempt,
            "reason": reason,
            "errorCode": code?.rawValue ?? -1,
        ])
        syncRetryGeneration &+= 1
        let generation = syncRetryGeneration
        syncRetryRequiresAccountVerification = requiresAccountVerification
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, generation == self.syncRetryGeneration else { return }
                let shouldVerifyAccount = self.syncRetryRequiresAccountVerification
                self.syncRetryWorkItem = nil
                self.syncRetryRequiresAccountVerification = false
                guard self.isStarted,
                      self.anySyncEnabled || self.hasPendingDeviceControlIntents else { return }
                if shouldVerifyAccount {
                    await self.refreshAccountStatus()
                    if self.isICloudAccountIdentityVerified {
                        self.resumePendingDeviceControlIntentsForVerifiedAccount()
                        guard self.anySyncEnabled else { return }
                        if self.hasInitialUploadBackfillWork, !self.hasPendingSyncChanges {
                            self.scheduleCurrentEnabledDataForUpload()
                        } else {
                            self.scheduleLowPrioritySync()
                        }
                    }
                } else {
                    self.resumePendingDeviceControlIntentsForVerifiedAccount()
                    guard self.anySyncEnabled else { return }
                    if self.hasInitialUploadBackfillWork, !self.hasPendingSyncChanges {
                        self.scheduleCurrentEnabledDataForUpload()
                    } else {
                        self.scheduleLowPrioritySync()
                    }
                }
            }
        }
        syncRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func resetSyncRetryBackoff() {
        syncRetryAttempt = 0
        syncRetryGeneration &+= 1
        syncRetryRequiresAccountVerification = false
        syncRetryWorkItem?.cancel()
        syncRetryWorkItem = nil
    }

    nonisolated static func isTransientCloudKitError(_ error: CKError) -> Bool {
        if error.code == .partialFailure, let partialErrors = error.partialErrorsByItemID, !partialErrors.isEmpty {
            return partialErrors.values.contains { partialError in
                guard let partialCKError = partialError as? CKError else { return true }
                return isTransientCloudKitError(partialCKError)
            }
        }
        return isTransientCloudKitErrorCode(error.code)
    }

    // Retrying cannot fix a missing account, parental restrictions, a full quota, invalid
    // request/schema arguments or a record format from a newer app version.
    nonisolated static func isTransientCloudKitErrorCode(_ code: CKError.Code) -> Bool {
        switch code {
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted, .quotaExceeded, .invalidArguments, .incompatibleVersion:
            return false
        default:
            return true
        }
    }

    struct InitialUploadSnapshot {
        let episodesSyncEnabled: Bool
        let subscriptionsSyncEnabled: Bool
        let settingsSyncEnabled: Bool
        let episodeBackfillOffset: Int?
        let subscriptionBackfillOffset: Int?
        let episodeBackfillCursor: String?
        let subscriptionBackfillCursor: String?
        let settingsBackfillPending: Bool
    }

    struct InitialUploadPlan {
        let snapshot: InitialUploadSnapshot
        let createdAt: Date
        let pages: [InitialUploadPlanPage]
        let episodeObjectHashes: [String]
        let subscribedFeedURLs: [String]
        let syncItemMetadataWrites: [ICCloudSyncItemMetadataWrite]
        let preparationSucceeded: Bool
    }

    struct InitialUploadPlanPage {
        let episodeObjectHashes: [String]
        let subscribedFeedURLs: [String]
        let nextEpisodeBackfillOffset: Int?
        let nextSubscriptionBackfillOffset: Int?
        let nextEpisodeBackfillCursor: String?
        let nextSubscriptionBackfillCursor: String?
        let hasEpisodeBackfill: Bool
        let hasSubscriptionBackfill: Bool
    }

    struct InitialUploadBatch {
        var episodeRecordNames: Set<String>
        var subscriptionRecordNames: Set<String>
        var auxiliaryRecordNames: Set<String>
        let episodeRecordCount: Int
        let subscriptionRecordCount: Int
        let nextEpisodeBackfillOffset: Int?
        let nextSubscriptionBackfillOffset: Int?
        let nextEpisodeBackfillCursor: String?
        let nextSubscriptionBackfillCursor: String?
        var hasEpisodeBackfill: Bool
        var hasSubscriptionBackfill: Bool
    }

    struct InitialUploadPage {
        let values: [String]
        let nextCursor: String?
        let succeeded: Bool
    }

    struct InitialSubscriptionPage {
        let values: [String]
        let payloadHashes: [String: String]
        let nextCursor: String?
        let succeeded: Bool
    }

    func initialUploadSnapshot() -> InitialUploadSnapshot {
        let episodeState = initialBackfillState(
            enabled: episodesSyncEnabled,
            offsetKey: Self.initialEpisodeBackfillOffsetKey,
            cursorKey: Self.initialEpisodeBackfillCursorKey,
            checkpointKey: Self.initialEpisodeBackfillCheckpointKey
        )
        let subscriptionState = initialBackfillState(
            enabled: subscriptionsSyncEnabled,
            offsetKey: Self.initialSubscriptionBackfillOffsetKey,
            cursorKey: Self.initialSubscriptionBackfillCursorKey,
            checkpointKey: Self.initialSubscriptionBackfillCheckpointKey
        )
        let settingsPending = settingsSyncEnabled && defaults.bool(forKey: Self.initialSettingsBackfillPendingKey)
        return InitialUploadSnapshot(episodesSyncEnabled: episodesSyncEnabled,
                                     subscriptionsSyncEnabled: subscriptionsSyncEnabled,
                                     settingsSyncEnabled: settingsSyncEnabled,
                                     episodeBackfillOffset: episodeState.offset,
                                     subscriptionBackfillOffset: subscriptionState.offset,
                                     episodeBackfillCursor: episodeState.cursor,
                                     subscriptionBackfillCursor: subscriptionState.cursor,
                                     settingsBackfillPending: settingsPending)
    }

    func initialBackfillState(
        enabled: Bool,
        offsetKey: String,
        cursorKey: String,
        checkpointKey: String
    ) -> (offset: Int?, cursor: String?) {
        guard enabled else { return (nil, nil) }
        if let checkpoint = defaults.dictionary(forKey: checkpointKey) {
            guard let storedOffset = (checkpoint["offset"] as? NSNumber)?.intValue else {
                persistInitialBackfillCheckpoint(
                    offset: 0,
                    cursor: nil,
                    checkpointKey: checkpointKey,
                    offsetKey: offsetKey,
                    cursorKey: cursorKey
                )
                return (0, nil)
            }
            let offset = max(0, storedOffset)
            let cursor = checkpoint["cursor"] as? String
            if (offset > 0 && cursor == nil) || (offset == 0 && cursor != nil) {
                persistInitialBackfillCheckpoint(
                    offset: 0,
                    cursor: nil,
                    checkpointKey: checkpointKey,
                    offsetKey: offsetKey,
                    cursorKey: cursorKey
                )
                return (0, nil)
            }
            return (offset, cursor)
        }
        guard enabled, let storedOffset = (defaults.object(forKey: offsetKey) as? NSNumber)?.intValue else {
            return (nil, nil)
        }
        let offset = max(0, storedOffset)
        let cursor = defaults.string(forKey: cursorKey)
        if offset > 0, cursor == nil {
            // Legacy versions persisted only a mutable row offset. It cannot be mapped to
            // a stable identifier after offline inserts/deletes, so restart the idempotent
            // backfill instead of silently skipping records.
            persistInitialBackfillCheckpoint(
                offset: 0,
                cursor: nil,
                checkpointKey: checkpointKey,
                offsetKey: offsetKey,
                cursorKey: cursorKey
            )
            return (0, nil)
        }
        if offset == 0, cursor != nil {
            persistInitialBackfillCheckpoint(
                offset: 0,
                cursor: nil,
                checkpointKey: checkpointKey,
                offsetKey: offsetKey,
                cursorKey: cursorKey
            )
            return (0, nil)
        }
        persistInitialBackfillCheckpoint(
            offset: offset,
            cursor: cursor,
            checkpointKey: checkpointKey,
            offsetKey: offsetKey,
            cursorKey: cursorKey
        )
        return (offset, cursor)
    }

    func persistInitialBackfillCheckpoint(
        offset: Int,
        cursor: String?,
        checkpointKey: String,
        offsetKey: String,
        cursorKey: String
    ) {
        var checkpoint: [String: Any] = ["offset": max(0, offset)]
        if let cursor {
            checkpoint["cursor"] = cursor
        }
        // This single dictionary is the source of truth. The two legacy keys remain only
        // as compatibility mirrors for customers upgrading from the released build.
        defaults.set(checkpoint, forKey: checkpointKey)
        defaults.set(max(0, offset), forKey: offsetKey)
        if let cursor {
            defaults.set(cursor, forKey: cursorKey)
        } else {
            defaults.removeObject(forKey: cursorKey)
        }
    }

    nonisolated static func buildInitialUploadPlan(from snapshot: InitialUploadSnapshot) async -> InitialUploadPlan {
        let createdAt = Date()
        Self.logSyncEvent("Initialer iCloud Upload-Plan gestartet", metadata: [
            "snapshotEpisodesSyncEnabled": snapshot.episodesSyncEnabled,
            "snapshotSubscriptionsSyncEnabled": snapshot.subscriptionsSyncEnabled,
            "snapshotSettingsSyncEnabled": snapshot.settingsSyncEnabled,
            "episodeBackfillOffset": snapshot.episodeBackfillOffset ?? -1,
            "subscriptionBackfillOffset": snapshot.subscriptionBackfillOffset ?? -1,
            "hasEpisodeBackfillCursor": snapshot.episodeBackfillCursor != nil,
            "hasSubscriptionBackfillCursor": snapshot.subscriptionBackfillCursor != nil,
            "settingsBackfillPending": snapshot.settingsBackfillPending,
        ])
        guard snapshot.episodeBackfillOffset != nil || snapshot.subscriptionBackfillOffset != nil else {
            return InitialUploadPlan(snapshot: snapshot,
                                     createdAt: createdAt,
                                     pages: [],
                                     episodeObjectHashes: [],
                                     subscribedFeedURLs: [],
                                     syncItemMetadataWrites: [],
                                     preparationSucceeded: true)
        }

        var episodeBackfillOffset = snapshot.episodeBackfillOffset
        var subscriptionBackfillOffset = snapshot.subscriptionBackfillOffset
        var episodeBackfillCursor = snapshot.episodeBackfillCursor
        var subscriptionBackfillCursor = snapshot.subscriptionBackfillCursor
        var pages: [InitialUploadPlanPage] = []
        var episodeObjectHashes: [String] = []
        var subscribedFeedURLs: [String] = []
        var syncItemMetadataWrites: [ICCloudSyncItemMetadataWrite] = []
        let preparedIdentityCapacity = Self.initialUploadPreparedPageWindowSize * Self.pendingChangeQueueChunkSize
        episodeObjectHashes.reserveCapacity(preparedIdentityCapacity)
        subscribedFeedURLs.reserveCapacity(preparedIdentityCapacity)
        syncItemMetadataWrites.reserveCapacity(preparedIdentityCapacity * 2)

        for _ in 0..<Self.initialUploadPreparedPageWindowSize {
            let hasEpisodeBackfill = episodeBackfillOffset != nil
            let hasSubscriptionBackfill = subscriptionBackfillOffset != nil
            guard hasEpisodeBackfill || hasSubscriptionBackfill else { break }

            async let episodePage = hasEpisodeBackfill
                ? episodeObjectHashesForInitialUploadPlan(cursor: episodeBackfillCursor)
                : InitialUploadPage(values: [], nextCursor: nil, succeeded: true)
            async let subscriptionPage = hasSubscriptionBackfill
                ? subscribedFeedURLsForInitialUploadPlan(cursor: subscriptionBackfillCursor)
                : InitialSubscriptionPage(values: [], payloadHashes: [:], nextCursor: nil, succeeded: true)

            let episodes = await episodePage
            let subscriptions = await subscriptionPage
            guard episodes.succeeded, subscriptions.succeeded else {
                return InitialUploadPlan(snapshot: snapshot,
                                         createdAt: createdAt,
                                         pages: [],
                                         episodeObjectHashes: [],
                                         subscribedFeedURLs: [],
                                         syncItemMetadataWrites: [],
                                         preparationSucceeded: false)
            }

            let nextEpisodeOffset = episodes.nextCursor == nil
                ? nil
                : (episodeBackfillOffset ?? 0) + episodes.values.count
            let nextSubscriptionOffset = subscriptions.nextCursor == nil
                ? nil
                : (subscriptionBackfillOffset ?? 0) + subscriptions.values.count
            pages.append(InitialUploadPlanPage(
                episodeObjectHashes: episodes.values,
                subscribedFeedURLs: subscriptions.values,
                nextEpisodeBackfillOffset: nextEpisodeOffset,
                nextSubscriptionBackfillOffset: nextSubscriptionOffset,
                nextEpisodeBackfillCursor: episodes.nextCursor,
                nextSubscriptionBackfillCursor: subscriptions.nextCursor,
                hasEpisodeBackfill: hasEpisodeBackfill,
                hasSubscriptionBackfill: hasSubscriptionBackfill
            ))

            for objectHash in episodes.values {
                episodeObjectHashes.append(objectHash)
                syncItemMetadataWrites.append(ICCloudSyncItemMetadataWrite(
                    category: localOutboxEpisodeCategory,
                    recordName: RecordPrefix.episode + objectHash,
                    itemIdentifier: objectHash,
                    localModifiedAt: nil,
                    localState: nil,
                    payloadHash: nil
                ))
            }
            for feedURL in subscriptions.values {
                subscribedFeedURLs.append(feedURL)
                syncItemMetadataWrites.append(ICCloudSyncItemMetadataWrite(
                    category: localOutboxSubscriptionCategory,
                    recordName: subscriptionRecordName(forFeedURL: feedURL),
                    itemIdentifier: feedURL,
                    localModifiedAt: createdAt,
                    localState: true,
                    payloadHash: subscriptions.payloadHashes[feedURL]
                ))
            }

            episodeBackfillOffset = nextEpisodeOffset
            subscriptionBackfillOffset = nextSubscriptionOffset
            episodeBackfillCursor = episodes.nextCursor
            subscriptionBackfillCursor = subscriptions.nextCursor
        }

        Self.logSyncEvent("Initialer iCloud Upload-Plan fertig", metadata: [
            "pageCount": pages.count,
            "episodeObjectHashCount": episodeObjectHashes.count,
            "subscribedFeedURLCount": subscribedFeedURLs.count,
            "syncItemMetadataWriteCount": syncItemMetadataWrites.count,
            "preparationSucceeded": true,
        ])
        return InitialUploadPlan(snapshot: snapshot,
                                 createdAt: createdAt,
                                 pages: pages,
                                 episodeObjectHashes: episodeObjectHashes,
                                 subscribedFeedURLs: subscribedFeedURLs,
                                 syncItemMetadataWrites: syncItemMetadataWrites,
                                 preparationSucceeded: true)
    }

    nonisolated static func episodeObjectHashesForInitialUploadPlan(cursor: String?) async -> InitialUploadPage {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            return InitialUploadPage(values: [], nextCursor: nil, succeeded: false)
        }
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Episode")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.fetchLimit = Self.pendingChangeQueueChunkSize + 1
            request.propertiesToFetch = ["objectHash"]
            request.returnsDistinctResults = true
            request.sortDescriptors = [NSSortDescriptor(key: "objectHash", ascending: true)]
            let basePredicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND objectHash != nil AND (consumed == YES OR starred == YES OR position > 0)")
            request.predicate = cursor.map {
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    basePredicate,
                    NSPredicate(format: "objectHash > %@", $0),
                ])
            } ?? basePredicate
            let rows: [NSDictionary]
            do {
                rows = try context.fetch(request)
            } catch {
                Self.logSyncEvent("Initialer iCloud Episode-Plan konnte lokale Daten nicht lesen", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                return InitialUploadPage(values: [], nextCursor: nil, succeeded: false)
            }
            let objectHashes = rows.prefix(Self.pendingChangeQueueChunkSize).compactMap { $0["objectHash"] as? String }
            let nextCursor = rows.count > Self.pendingChangeQueueChunkSize ? objectHashes.last : nil
            Self.logSyncEvent("Initialer iCloud Episode-Plan Fetch-Seite", metadata: [
                "cursorPresent": cursor != nil,
                "rowCount": rows.count,
                "objectHashCount": objectHashes.count,
                "hasNextCursor": nextCursor != nil,
            ])
            return InitialUploadPage(values: objectHashes, nextCursor: nextCursor, succeeded: true)
        }
    }

    nonisolated static func subscribedFeedURLsForInitialUploadPlan(cursor: String?) async -> InitialSubscriptionPage {
        guard let context = DatabaseManager.shared()?.newICloudSyncBackgroundContext() else {
            return InitialSubscriptionPage(values: [], payloadHashes: [:], nextCursor: nil, succeeded: false)
        }
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Feed")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.fetchLimit = Self.pendingChangeQueueChunkSize + 1
            request.propertiesToFetch = ["sourceURL_"]
            request.returnsDistinctResults = true
            request.sortDescriptors = [NSSortDescriptor(key: "sourceURL_", ascending: true)]
            let basePredicate = NSPredicate(format: "subscribed == YES AND sourceURL_ != nil")
            request.predicate = cursor.map {
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    basePredicate,
                    NSPredicate(format: "sourceURL_ > %@", $0),
                ])
            } ?? basePredicate
            let rows: [NSDictionary]
            do {
                rows = try context.fetch(request)
            } catch {
                Self.logSyncEvent("Initialer iCloud Abo-Plan konnte lokale Daten nicht lesen", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                return InitialSubscriptionPage(values: [], payloadHashes: [:], nextCursor: nil, succeeded: false)
            }
            let pageFeedURLs = rows.prefix(Self.pendingChangeQueueChunkSize).compactMap {
                $0["sourceURL_"] as? String
            }
            let payloadRequest = NSFetchRequest<CDFeed>(entityName: "Feed")
            payloadRequest.includesSubentities = false
            payloadRequest.relationshipKeyPathsForPrefetching = ["properties"]
            payloadRequest.predicate = NSPredicate(
                format: "subscribed == YES AND sourceURL_ IN %@",
                pageFeedURLs
            )
            let payloadFeeds: [CDFeed]
            do {
                payloadFeeds = try context.fetch(payloadRequest)
            } catch {
                Self.logSyncEvent("Initiale iCloud Abo-Payloads konnten lokale Daten nicht lesen", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                return InitialSubscriptionPage(values: [], payloadHashes: [:], nextCursor: nil, succeeded: false)
            }
            var payloadFeedByURL: [String: CDFeed] = [:]
            for feed in payloadFeeds {
                guard let feedURL = feed.value(forKey: "sourceURL_") as? String else { continue }
                if let existing = payloadFeedByURL[feedURL],
                   existing.objectID.uriRepresentation().absoluteString
                    <= feed.objectID.uriRepresentation().absoluteString {
                    continue
                }
                payloadFeedByURL[feedURL] = feed
            }
            var feedURLs: [String] = []
            var payloadHashes: [String: String] = [:]
            for feedURL in pageFeedURLs {
                guard let feed = payloadFeedByURL[feedURL] else { continue }
                feedURLs.append(feedURL)
                // Record the payload hash at queue time so the change-gate matches right away.
                // Without it the first refresh after enabling subscription sync saw every feed
                // as "changed" and re-uploaded the whole list once more.
                payloadHashes[feedURL] = subscriptionPayloadHash(for: feed)
            }
            let nextCursor = rows.count > Self.pendingChangeQueueChunkSize ? pageFeedURLs.last : nil
            Self.logSyncEvent("Initialer iCloud Abo-Plan Fetch-Seite", metadata: [
                "cursorPresent": cursor != nil,
                "rowCount": rows.count,
                "feedURLCount": feedURLs.count,
                "hasNextCursor": nextCursor != nil,
            ])
            return InitialSubscriptionPage(values: feedURLs, payloadHashes: payloadHashes, nextCursor: nextCursor, succeeded: true)
        }
    }

    nonisolated static func logSyncEvent(_ message: String, metadata: [String: Any] = [:]) {
        let defaults = UserDefaults.standard
        let episodesEnabled = defaults.bool(forKey: ICiCloudSyncEpisodesEnabled)
        let subscriptionsEnabled = defaults.bool(forKey: ICiCloudSyncSubscriptionsEnabled)
        let settingsEnabled = defaults.bool(forKey: ICiCloudSyncSettingsEnabled)
        var details = metadata
        details["episodesSyncEnabled"] = episodesEnabled
        details["subscriptionsSyncEnabled"] = subscriptionsEnabled
        details["settingsSyncEnabled"] = settingsEnabled
        details["anySyncEnabled"] = episodesEnabled || subscriptionsEnabled || settingsEnabled
        details["actor"] = "nonisolated"
        details["isMainThread"] = Thread.isMainThread
        details["threadID"] = pthread_mach_thread_np(pthread_self())
        ICDiagnosticLogger.shared.logEvent("icloud-sync", message: message, metadata: details as NSDictionary)
    }

    nonisolated static func subscriptionRecordName(forFeedURL feedURL: String) -> String {
        RecordPrefix.subscription + sha256Hex(feedURL)
    }

    nonisolated static func subscriptionTombstoneRecordName(forFeedURL feedURL: String) -> String {
        RecordPrefix.subscriptionTombstone + sha256Hex(feedURL)
    }

    nonisolated static func subscriptionOutboxRecordNames(forCloudRecordName recordName: String) -> Set<String> {
        if recordName.hasPrefix(RecordPrefix.subscription) {
            let hash = String(recordName.dropFirst(RecordPrefix.subscription.count))
            return [RecordPrefix.subscription + hash, RecordPrefix.subscriptionTombstone + hash]
        }
        if recordName.hasPrefix(RecordPrefix.subscriptionTombstone) {
            let hash = String(recordName.dropFirst(RecordPrefix.subscriptionTombstone.count))
            return [RecordPrefix.subscription + hash, RecordPrefix.subscriptionTombstone + hash]
        }
        return [recordName]
    }

    func initialUploadPlanIsCurrent(
        _ snapshot: InitialUploadSnapshot,
        expectedCloudAccountGeneration: Int,
        expectedAccountRecordName: String?,
        queueTaskGeneration: Int?
    ) -> Bool {
        guard expectedCloudAccountGeneration == cloudAccountGeneration,
              !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified,
              let expectedAccountRecordName,
              defaults.string(forKey: Self.accountUserRecordNameKey) == expectedAccountRecordName else {
            return false
        }
        if let queueTaskGeneration,
           queueTaskGeneration != initialQueueTaskGeneration {
            return false
        }
        let currentSnapshot = initialUploadSnapshot()
        return currentSnapshot.episodesSyncEnabled == snapshot.episodesSyncEnabled
            && currentSnapshot.subscriptionsSyncEnabled == snapshot.subscriptionsSyncEnabled
            && currentSnapshot.settingsSyncEnabled == snapshot.settingsSyncEnabled
            && currentSnapshot.episodeBackfillOffset == snapshot.episodeBackfillOffset
            && currentSnapshot.subscriptionBackfillOffset == snapshot.subscriptionBackfillOffset
            && currentSnapshot.episodeBackfillCursor == snapshot.episodeBackfillCursor
            && currentSnapshot.subscriptionBackfillCursor == snapshot.subscriptionBackfillCursor
            && currentSnapshot.settingsBackfillPending == snapshot.settingsBackfillPending
    }

    func applyInitialUploadPlan(
        _ plan: InitialUploadPlan,
        scheduleSyncAfterQueue: Bool = true,
        expectedCloudAccountGeneration: Int,
        expectedAccountRecordName: String?,
        queueTaskGeneration: Int? = nil
    ) async {
        defer {
            if scheduleSyncAfterQueue,
               let queueTaskGeneration,
               queueTaskGeneration == initialQueueTaskGeneration {
                initialQueueTask = nil
            }
        }
        guard anySyncEnabled, !Task.isCancelled,
              initialUploadPlanIsCurrent(
                plan.snapshot,
                expectedCloudAccountGeneration: expectedCloudAccountGeneration,
                expectedAccountRecordName: expectedAccountRecordName,
                queueTaskGeneration: queueTaskGeneration
              ) else { return }
        logSyncEvent("iCloud Upload-Queue baut Daten auf", metadata: [
            "pageCount": plan.pages.count,
            "episodeObjectHashCount": plan.episodeObjectHashes.count,
            "subscribedFeedURLCount": plan.subscribedFeedURLs.count,
            "snapshotEpisodesSyncEnabled": plan.snapshot.episodesSyncEnabled,
            "snapshotSubscriptionsSyncEnabled": plan.snapshot.subscriptionsSyncEnabled,
            "snapshotSettingsSyncEnabled": plan.snapshot.settingsSyncEnabled,
        ])
        let hasInitialWork = plan.snapshot.episodeBackfillOffset != nil
        || plan.snapshot.subscriptionBackfillOffset != nil
        guard hasInitialWork else {
            if scheduleSyncAfterQueue {
                // Still publish the device record: turning a category OFF queues no backfill
                // work, but the other devices' lists must see the new option flags. This runs
                // inside the asynchronous plan task, not in the switch tap.
                queueDeviceRecord()
            }
            logSyncEvent("Initiale iCloud-Queue ohne Arbeit beendet")
            if scheduleSyncAfterQueue {
                scheduleLowPrioritySync()
            }
            return
        }
        guard plan.preparationSucceeded else {
            handleLocalUploadReadFailure(reason: "initialUploadPlan")
            return
        }

        guard let expectedAccountRecordName else {
            handleLocalUploadReadFailure(reason: "initialUploadMetadataAccount")
            return
        }
        do {
            _ = try await Self.upsertSyncItemMetadata(
                accountRecordName: expectedAccountRecordName,
                writes: plan.syncItemMetadataWrites,
                replaceExisting: false
            )
        } catch is CancellationError {
            return
        } catch {
            logSyncEvent("Initiale iCloud-Metadaten konnten nicht gespeichert werden", metadata: [
                "errorDomain": (error as NSError).domain,
                "errorCode": (error as NSError).code,
            ])
            handleLocalUploadReadFailure(reason: "initialUploadMetadata")
            return
        }
        guard !Task.isCancelled,
              initialUploadPlanIsCurrent(
                plan.snapshot,
                expectedCloudAccountGeneration: expectedCloudAccountGeneration,
                expectedAccountRecordName: expectedAccountRecordName,
                queueTaskGeneration: queueTaskGeneration
              ) else { return }

        initializeSyncEngineIfNeeded()
        var pendingKeys = pendingRecordZoneChangeKeys()
        if scheduleSyncAfterQueue,
           let intent = persistPendingDeviceControlSaveIntent(
            accountRecordName: expectedAccountRecordName
           ) {
            addPendingSaves(
                [deviceRecordID(for: intent.targetDeviceID)],
                pendingKeys: &pendingKeys,
                stampDeviceRecordForUserData: false
            )
        }
        var queuedUserData = false
        var auxiliaryRecordNames: Set<String> = []

        if plan.snapshot.episodeBackfillOffset != nil, episodesSyncEnabled {
            queuedUserData = await applyInitialEpisodeQueue(plan.episodeObjectHashes, pendingKeys: &pendingKeys) || queuedUserData
            guard !Task.isCancelled,
                  initialUploadPlanIsCurrent(
                    plan.snapshot,
                    expectedCloudAccountGeneration: expectedCloudAccountGeneration,
                    expectedAccountRecordName: expectedAccountRecordName,
                    queueTaskGeneration: queueTaskGeneration
                  ) else { return }
            if plan.snapshot.episodeBackfillOffset == 0 {
                let existingIntent = pendingSingletonUploadIntent(
                    recordName: RecordPrefix.listScrollPositions,
                    accountRecordName: expectedAccountRecordName
                )
                let intent = existingIntent ?? ICListScrollPositionsLastModifiedDate().flatMap {
                    persistPendingSingletonUploadIntent(
                        for: listScrollPositionsRecordID(),
                        modifiedAt: $0
                    )
                }
                if let intent {
                    setScrollPositionsLocalModifiedDate(intent.modifiedAt)
                    addPendingSaves([listScrollPositionsRecordID()], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
                    auxiliaryRecordNames.insert(RecordPrefix.listScrollPositions)
                    queuedUserData = true
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  initialUploadPlanIsCurrent(
                    plan.snapshot,
                    expectedCloudAccountGeneration: expectedCloudAccountGeneration,
                    expectedAccountRecordName: expectedAccountRecordName,
                    queueTaskGeneration: queueTaskGeneration
                  ) else { return }
        }

        if plan.snapshot.subscriptionBackfillOffset != nil, subscriptionsSyncEnabled {
            if plan.snapshot.subscriptionBackfillOffset == 0, Self.hasLocalSubscriptionListSettingsForInitialBackfill() {
                // The list sort mode, saved manual order, episode-list filters and sidebar
                // visibility travel with the subscriptions. Still do not publish a
                // sort-mode-only state during initial backfill: it can race the real manual
                // order under last-writer-wins. Local list/menu customizations are real
                // durable user data and must seed the singleton on first upload.
                if let intent = pendingSingletonUploadIntent(
                    recordName: RecordPrefix.subscriptionListSettings,
                    accountRecordName: expectedAccountRecordName
                ), let payload = intent.payloadDictionary() {
                    setSyncMetadata(intent.modifiedAt, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
                    setSyncMetadata(
                        Self.subscriptionListSettingsFingerprint(payload: payload),
                        forKey: Self.subscriptionListSettingsBaselineKey
                    )
                    addPendingSaves([subscriptionListSettingsRecordID()], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
                    auxiliaryRecordNames.insert(RecordPrefix.subscriptionListSettings)
                    queuedUserData = true
                }
            }
            queuedUserData = await applyInitialSubscriptionQueue(plan.subscribedFeedURLs, pendingKeys: &pendingKeys) || queuedUserData
            guard !Task.isCancelled,
                  initialUploadPlanIsCurrent(
                    plan.snapshot,
                    expectedCloudAccountGeneration: expectedCloudAccountGeneration,
                    expectedAccountRecordName: expectedAccountRecordName,
                    queueTaskGeneration: queueTaskGeneration
                  ) else { return }
            await Task.yield()
            guard !Task.isCancelled,
                  initialUploadPlanIsCurrent(
                    plan.snapshot,
                    expectedCloudAccountGeneration: expectedCloudAccountGeneration,
                    expectedAccountRecordName: expectedAccountRecordName,
                    queueTaskGeneration: queueTaskGeneration
                  ) else { return }
        }

        // Settings deliberately NOT queued here. The old eager publish stamped a fresh
        // localModifiedDate before the first fetch — the enabling device then won
        // last-writer-wins against the REAL cloud settings and silently discarded them
        // (the "iPad never received the iPhone settings" bug). The initial settings
        // publish now happens in didFetchChanges, only if no remote settings arrived.

        if queuedUserData, scheduleSyncAfterQueue {
            queueDeviceRecord(stampLastSyncDate: true)
        }
        if !Task.isCancelled {
            recordInitialUploadBatchesQueued(
                plan.pages,
                auxiliaryRecordNames: auxiliaryRecordNames
            )
            logSyncEvent("Initiale iCloud-Queue abgeschlossen", metadata: [
                "queuedUserData": queuedUserData,
                "knownPendingKeyCount": pendingKeys.count,
                "pageCount": plan.pages.count,
            ])
            logSyncEvent("iCloud Upload-Queue fertig")
            // Even an empty local library must fetch the other devices' data. A continuation
            // page is added from the active CKSyncEngine event and must not start another task.
            if scheduleSyncAfterQueue {
                scheduleLowPrioritySync()
            }
            postStateChanged()
        }
    }

    @discardableResult
    func queueNextInitialUploadPageDuringActiveSend() async -> Bool {
        guard pendingInitialUploadBatches.isEmpty,
              initialQueueTask == nil,
              !isPreparingInitialUploadPage,
              !requiresInitialBackfillFetchBeforeUpload,
              hasInitialUploadBackfillWork,
              anySyncEnabled,
              !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified,
              !hasUnresolvedSyncFailures,
              !Task.isCancelled else {
            return false
        }

        isPreparingInitialUploadPage = true
        defer { isPreparingInitialUploadPage = false }
        let generation = cloudAccountGeneration
        let snapshot = initialUploadSnapshot()
        let plan = await Self.buildInitialUploadPlan(from: snapshot)
        let currentSnapshot = initialUploadSnapshot()
        guard generation == cloudAccountGeneration,
              pendingInitialUploadBatches.isEmpty,
              currentSnapshot.episodesSyncEnabled == snapshot.episodesSyncEnabled,
              currentSnapshot.subscriptionsSyncEnabled == snapshot.subscriptionsSyncEnabled,
              currentSnapshot.episodeBackfillOffset == snapshot.episodeBackfillOffset,
              currentSnapshot.subscriptionBackfillOffset == snapshot.subscriptionBackfillOffset,
              currentSnapshot.episodeBackfillCursor == snapshot.episodeBackfillCursor,
              currentSnapshot.subscriptionBackfillCursor == snapshot.subscriptionBackfillCursor,
              !Task.isCancelled else {
            return false
        }
        await applyInitialUploadPlan(
            plan,
            scheduleSyncAfterQueue: false,
            expectedCloudAccountGeneration: generation,
            expectedAccountRecordName: defaults.string(forKey: Self.accountUserRecordNameKey)
        )
        return !pendingInitialUploadBatches.isEmpty
    }

    // The settings marker is NOT upload-backfill work anymore: the initial settings
    // publish is fetch-gated (didFetchChanges) so an enabling device first adopts an
    // existing cloud state instead of displacing it under last-writer-wins.
    var hasInitialUploadBackfillWork: Bool {
        (episodesSyncEnabled && hasStoredInitialBackfill(
            checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
            offsetKey: Self.initialEpisodeBackfillOffsetKey
        ))
        || (subscriptionsSyncEnabled && hasStoredInitialBackfill(
            checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
            offsetKey: Self.initialSubscriptionBackfillOffsetKey
        ))
    }

    func recordInitialUploadBatchesQueued(
        _ pages: [InitialUploadPlanPage],
        auxiliaryRecordNames: Set<String>
    ) {
        pendingInitialUploadBatches = pages.enumerated().map { index, page in
            let hasEpisodeBackfill = page.hasEpisodeBackfill && episodesSyncEnabled
            let hasSubscriptionBackfill = page.hasSubscriptionBackfill && subscriptionsSyncEnabled
            return InitialUploadBatch(
                episodeRecordNames: hasEpisodeBackfill
                    ? Set(page.episodeObjectHashes.map { RecordPrefix.episode + $0 })
                    : [],
                subscriptionRecordNames: hasSubscriptionBackfill
                    ? Set(page.subscribedFeedURLs.flatMap { feedURL in
                        [
                            Self.subscriptionRecordName(forFeedURL: feedURL),
                            Self.subscriptionTombstoneRecordName(forFeedURL: feedURL),
                        ]
                    })
                    : [],
                auxiliaryRecordNames: index == pages.startIndex ? auxiliaryRecordNames : [],
                episodeRecordCount: hasEpisodeBackfill ? page.episodeObjectHashes.count : 0,
                subscriptionRecordCount: hasSubscriptionBackfill ? page.subscribedFeedURLs.count : 0,
                nextEpisodeBackfillOffset: page.nextEpisodeBackfillOffset,
                nextSubscriptionBackfillOffset: page.nextSubscriptionBackfillOffset,
                nextEpisodeBackfillCursor: page.nextEpisodeBackfillCursor,
                nextSubscriptionBackfillCursor: page.nextSubscriptionBackfillCursor,
                hasEpisodeBackfill: hasEpisodeBackfill,
                hasSubscriptionBackfill: hasSubscriptionBackfill
            )
        }
        advanceConfirmedInitialUploadBatches()
        logSyncEvent("Initiale iCloud-Queue wartet auf CloudKit-Bestätigung", metadata: [
            "pageCount": pendingInitialUploadBatches.count,
            "episodeRecordCount": pendingInitialUploadBatches.reduce(0) { $0 + $1.episodeRecordNames.count },
            "subscriptionRecordCount": pendingInitialUploadBatches.reduce(0) { $0 + $1.subscriptionRecordNames.count },
            "auxiliaryRecordCount": pendingInitialUploadBatches.reduce(0) { $0 + $1.auxiliaryRecordNames.count },
        ])
    }

    func invalidateCloudInventory(reason: String) {
        defaults.removeObject(forKey: Self.cloudInventoryKey)
        logSyncEvent("Cloud-Inventar invalidiert", metadata: ["reason": reason])
    }

    func recordInitialUploadRecordsSaved(_ recordIDs: [CKRecord.ID]) {
        recordInitialUploadRecordsResolved(recordIDs)
    }

    func initialEpisodeRecordsAwaitingAcknowledgedClock(in records: [CKRecord]) -> [CKRecord] {
        let pendingRecordNames = pendingInitialUploadBatches.reduce(into: Set<String>()) {
            $0.formUnion($1.episodeRecordNames)
        }
        guard !pendingRecordNames.isEmpty else { return [] }
        return records.filter {
            $0.recordType == RecordKind.episodeState
                && pendingRecordNames.contains($0.recordID.recordName)
        }
    }

    func persistAcknowledgedInitialEpisodeClocks(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        guard let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) else {
            throw Self.syncItemMetadataStoreError(
                code: 1,
                description: "Der iCloud-Account für bestätigte Episodenmetadaten konnte nicht bestimmt werden."
            )
        }
        var writes: [ICCloudSyncItemMetadataWrite] = []
        writes.reserveCapacity(records.count)
        for record in records {
            let recordName = record.recordID.recordName
            guard record.recordType == RecordKind.episodeState,
                  recordName.hasPrefix(RecordPrefix.episode),
                  let updatedAt = record["updatedAt"] as? Date else {
                throw Self.syncItemMetadataStoreError(
                    code: 2,
                    description: "Ein bestätigter iCloud-Episodenstatus enthält keine gültige Sync-Uhr."
                )
            }
            let objectHash = String(recordName.dropFirst(RecordPrefix.episode.count))
            guard !objectHash.isEmpty else {
                throw Self.syncItemMetadataStoreError(
                    code: 2,
                    description: "Ein bestätigter iCloud-Episodenstatus enthält keine gültige Identität."
                )
            }
            writes.append(ICCloudSyncItemMetadataWrite(
                category: Self.localOutboxEpisodeCategory,
                recordName: recordName,
                itemIdentifier: objectHash,
                localModifiedAt: updatedAt,
                localState: nil,
                payloadHash: nil
            ))
        }
        _ = try await Self.upsertSyncItemMetadata(
            accountRecordName: accountRecordName,
            writes: writes,
            replaceExisting: false
        )
    }

    func recordInitialUploadRecordsResolved(_ recordIDs: [CKRecord.ID]) {
        recordInitialUploadRecordNamesResolved(Set(recordIDs.map(\.recordName)))
    }

    func recordInitialUploadRecordNamesResolved(_ resolvedNames: Set<String>) {
        guard !pendingInitialUploadBatches.isEmpty, !resolvedNames.isEmpty else { return }
        var didResolveRecord = false
        for index in pendingInitialUploadBatches.indices {
            let unresolvedCount = pendingInitialUploadBatches[index].episodeRecordNames.count
                + pendingInitialUploadBatches[index].subscriptionRecordNames.count
                + pendingInitialUploadBatches[index].auxiliaryRecordNames.count
            pendingInitialUploadBatches[index].episodeRecordNames.subtract(resolvedNames)
            pendingInitialUploadBatches[index].subscriptionRecordNames.subtract(resolvedNames)
            pendingInitialUploadBatches[index].auxiliaryRecordNames.subtract(resolvedNames)
            let remainingCount = pendingInitialUploadBatches[index].episodeRecordNames.count
                + pendingInitialUploadBatches[index].subscriptionRecordNames.count
                + pendingInitialUploadBatches[index].auxiliaryRecordNames.count
            didResolveRecord = didResolveRecord || remainingCount < unresolvedCount
        }
        let didAdvancePage = advanceConfirmedInitialUploadBatches()
        if didResolveRecord, !didAdvancePage {
            postStateChanged()
        }
    }

    @discardableResult
    func advanceConfirmedInitialUploadBatches() -> Bool {
        var confirmedPageCount = 0
        while let batch = pendingInitialUploadBatches.first,
              batch.episodeRecordNames.isEmpty,
              batch.subscriptionRecordNames.isEmpty,
              batch.auxiliaryRecordNames.isEmpty {
            if batch.hasEpisodeBackfill {
                updateInitialEpisodeBackfillCursor(
                    nextOffset: batch.nextEpisodeBackfillOffset,
                    nextCursor: batch.nextEpisodeBackfillCursor
                )
            }
            if batch.hasSubscriptionBackfill {
                updateInitialSubscriptionBackfillCursor(
                    nextOffset: batch.nextSubscriptionBackfillOffset,
                    nextCursor: batch.nextSubscriptionBackfillCursor
                )
            }
            pendingInitialUploadBatches.removeFirst()
            confirmedPageCount += 1
        }
        guard confirmedPageCount > 0 else { return false }
        logSyncEvent("Initiale iCloud-Seiten von CloudKit bestätigt", metadata: [
            "confirmedPageCount": confirmedPageCount,
            "remainingPageCount": pendingInitialUploadBatches.count,
            "episodeBackfillOffset": (defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
            "subscriptionBackfillOffset": (defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
        ])
        if anySyncEnabled, !hasInitialUploadBackfillWork {
            setStatus(NSLocalizedString("Prüft, ob alle Daten auf iCloud angekommen sind…", comment: ""))
        }
        postStateChanged()
        return true
    }

    func discardInitialUploadCheckpoints(episodes: Bool, subscriptions: Bool) {
        guard episodes || subscriptions else { return }
        for index in pendingInitialUploadBatches.indices {
            if episodes {
                pendingInitialUploadBatches[index].episodeRecordNames.removeAll()
                pendingInitialUploadBatches[index].auxiliaryRecordNames.remove(RecordPrefix.listScrollPositions)
                pendingInitialUploadBatches[index].hasEpisodeBackfill = false
            }
            if subscriptions {
                pendingInitialUploadBatches[index].subscriptionRecordNames.removeAll()
                pendingInitialUploadBatches[index].auxiliaryRecordNames.remove(RecordPrefix.subscriptionListSettings)
                pendingInitialUploadBatches[index].hasSubscriptionBackfill = false
            }
        }
        advanceConfirmedInitialUploadBatches()
    }

    func handleLocalUploadReadFailure(reason: String) {
        hasUnresolvedSyncFailures = true
        let error = NSError(
            domain: "ICiCloudSyncLocalRead",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Local data could not be read for iCloud upload."]
        )
        logSyncEvent("Lokale Daten für iCloud Upload nicht lesbar", metadata: ["reason": reason])
        setError(error)
        scheduleSyncRetryAfterFailure(error: error, reason: reason)
    }

    func applySyncEngineCallbackOutcome(for syncEngine: CKSyncEngine, generation: Int) -> Bool {
        let outcome = syncEngineCallbackGate.takeInitialUploadOutcome(
            generation: generation,
            for: syncEngine
        )
        let hasDeferredLocalChanges = outcome.localChangesDeferred
        recordInitialUploadRecordNamesResolved(outcome.resolvedRecordNames)
        if outcome.localReadFailed {
            handleLocalUploadReadFailure(reason: "recordMaterialization")
        }
        return hasDeferredLocalChanges
    }

    func sendChangesAndApplyCallbackOutcomes(_ syncEngine: CKSyncEngine,
                                             generation: Int) async throws -> Bool {
        guard !requiresInitialBackfillFetchBeforeUpload else { return false }
        while true {
            guard !requiresInitialBackfillFetchBeforeUpload else { return false }
            do {
                try await syncEngine.sendChanges()
            } catch {
                _ = applySyncEngineCallbackOutcome(for: syncEngine, generation: generation)
                throw error
            }
            let hasDeferredLocalChanges = applySyncEngineCallbackOutcome(
                for: syncEngine,
                generation: generation
            )
            guard generation == cloudAccountGeneration,
                  !hasUnresolvedSyncFailures,
                  !Task.isCancelled else {
                return false
            }
            if hasDeferredLocalChanges && hasPendingSyncChanges { return true }

            if requiresImmediateFinalDeviceRecordResend {
                requiresImmediateFinalDeviceRecordResend = false
                guard hasPendingFinalDeviceRecordUpdate, hasPendingSyncChanges else { return false }
                continue
            }
            if requiresImmediateSingletonRecordResend {
                requiresImmediateSingletonRecordResend = false
                guard hasPendingSyncChanges else { return false }
                continue
            }

            await queueNextInitialUploadPageDuringActiveSend()
            guard hasInitialUploadBackfillWork, hasPendingSyncChanges else {
                return false
            }
        }
    }

    func updateInitialEpisodeBackfillCursor(nextOffset: Int?, nextCursor: String?) {
        if let nextOffset, let nextCursor {
            persistInitialBackfillCheckpoint(
                offset: nextOffset,
                cursor: nextCursor,
                checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
                offsetKey: Self.initialEpisodeBackfillOffsetKey,
                cursorKey: Self.initialEpisodeBackfillCursorKey
            )
        } else {
            markInitialEpisodeBackfillCompleted()
            clearInitialEpisodeBackfillCursor()
        }
    }

    func updateInitialSubscriptionBackfillCursor(nextOffset: Int?, nextCursor: String?) {
        if let nextOffset, let nextCursor {
            persistInitialBackfillCheckpoint(
                offset: nextOffset,
                cursor: nextCursor,
                checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
                offsetKey: Self.initialSubscriptionBackfillOffsetKey,
                cursorKey: Self.initialSubscriptionBackfillCursorKey
            )
        } else {
            markInitialSubscriptionBackfillCompleted()
            clearInitialSubscriptionBackfillCursor()
        }
    }

    func migrateResumableInitialBackfillAccountsIfNeeded() {
        guard !defaults.bool(forKey: Self.initialBackfillAccountMigrationCompletedKey) else { return }
        guard !isICloudAccountResetRequired,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else { return }
        var fetchBeforeUploadCategories = defaults.string(
            forKey: Self.initialBackfillFetchBeforeUploadAccountKey
        ) == accountRecordName
            ? initialBackfillFetchBeforeUploadCategories
            : []
        if defaults.bool(forKey: Self.episodesSyncHasParticipatedKey) {
            fetchBeforeUploadCategories.insert("episodes")
            if episodesSyncEnabled {
                if !hasStoredInitialBackfill(
                    checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
                    offsetKey: Self.initialEpisodeBackfillOffsetKey
                ) {
                    resetInitialEpisodeBackfillCursor()
                }
                defaults.set(accountRecordName, forKey: Self.initialEpisodeBackfillAccountKey)
                defaults.removeObject(forKey: Self.initialEpisodeBackfillCompletedAccountKey)
            }
        }
        if defaults.bool(forKey: Self.subscriptionsSyncHasParticipatedKey) {
            fetchBeforeUploadCategories.insert("subscriptions")
            if subscriptionsSyncEnabled {
                if !hasStoredInitialBackfill(
                    checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
                    offsetKey: Self.initialSubscriptionBackfillOffsetKey
                ) {
                    resetInitialSubscriptionBackfillCursor()
                }
                defaults.set(accountRecordName, forKey: Self.initialSubscriptionBackfillAccountKey)
                defaults.removeObject(forKey: Self.initialSubscriptionBackfillCompletedAccountKey)
                defaults.set(true, forKey: Self.suppressSubscriptionDeletionsKey)
            }
        }
        if !fetchBeforeUploadCategories.isEmpty {
            // The account marker commits the category set. A process stop between these
            // writes leaves the gate closed and the migration retries on the next launch.
            defaults.removeObject(forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
            defaults.set(
                fetchBeforeUploadCategories.sorted(),
                forKey: Self.initialBackfillFetchBeforeUploadCategoriesKey
            )
            defaults.set(accountRecordName, forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
        }
        defaults.set(true, forKey: Self.initialBackfillAccountMigrationCompletedKey)
    }

    func prepareInitialBackfillsForVerifiedAccount() {
        guard isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else { return }

        if episodesSyncEnabled {
            prepareInitialEpisodeFetchBeforeUploadIfNeeded(
                accountRecordName: accountRecordName
            )
            if defaults.string(forKey: Self.initialEpisodeBackfillCompletedAccountKey) == accountRecordName {
                clearInitialEpisodeBackfillCursor()
                clearInitialEpisodeBackfillTotal()
            } else if defaults.string(forKey: Self.initialEpisodeBackfillAccountKey) != accountRecordName
                        || !hasStoredInitialBackfill(
                            checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
                            offsetKey: Self.initialEpisodeBackfillOffsetKey
                        ) {
                resetInitialEpisodeBackfillCursor()
                defaults.set(accountRecordName, forKey: Self.initialEpisodeBackfillAccountKey)
                defaults.removeObject(forKey: Self.initialEpisodeBackfillCompletedAccountKey)
            }
        }

        if subscriptionsSyncEnabled {
            if defaults.string(forKey: Self.initialSubscriptionBackfillCompletedAccountKey) == accountRecordName {
                clearInitialSubscriptionBackfillCursor()
                clearInitialSubscriptionBackfillTotal()
            } else if defaults.string(forKey: Self.initialSubscriptionBackfillAccountKey) != accountRecordName
                        || !hasStoredInitialBackfill(
                            checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
                            offsetKey: Self.initialSubscriptionBackfillOffsetKey
                        ) {
                resetInitialSubscriptionBackfillCursor()
                defaults.set(accountRecordName, forKey: Self.initialSubscriptionBackfillAccountKey)
                defaults.removeObject(forKey: Self.initialSubscriptionBackfillCompletedAccountKey)
            }
        }
    }

    func markInitialEpisodeBackfillCompleted() {
        guard isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else { return }
        defaults.set(accountRecordName, forKey: Self.initialEpisodeBackfillAccountKey)
        defaults.set(accountRecordName, forKey: Self.initialEpisodeBackfillCompletedAccountKey)
        clearInitialEpisodeBackfillTotal()
    }

    func markInitialSubscriptionBackfillCompleted() {
        guard isICloudAccountIdentityVerified,
              let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey),
              !accountRecordName.isEmpty else { return }
        defaults.set(accountRecordName, forKey: Self.initialSubscriptionBackfillAccountKey)
        defaults.set(accountRecordName, forKey: Self.initialSubscriptionBackfillCompletedAccountKey)
        clearInitialSubscriptionBackfillTotal()
    }

    func invalidateInitialBackfillParticipation() {
        for key in [Self.initialEpisodeBackfillAccountKey,
                    Self.initialSubscriptionBackfillAccountKey,
                    Self.initialEpisodeBackfillCompletedAccountKey,
                    Self.initialSubscriptionBackfillCompletedAccountKey,
                    Self.initialEpisodeBackfillTotalKey,
                    Self.initialSubscriptionBackfillTotalKey,
                    Self.initialEpisodeBackfillTotalAccountKey,
                    Self.initialSubscriptionBackfillTotalAccountKey] {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Self.initialBackfillFetchBeforeUploadCategoriesKey)
        defaults.removeObject(forKey: Self.initialBackfillFetchBeforeUploadAccountKey)
    }

    func resetInitialEpisodeBackfillCursor() {
        clearInitialEpisodeBackfillTotal()
        persistInitialBackfillCheckpoint(
            offset: 0,
            cursor: nil,
            checkpointKey: Self.initialEpisodeBackfillCheckpointKey,
            offsetKey: Self.initialEpisodeBackfillOffsetKey,
            cursorKey: Self.initialEpisodeBackfillCursorKey
        )
    }

    func clearInitialEpisodeBackfillCursor() {
        defaults.removeObject(forKey: Self.initialEpisodeBackfillCheckpointKey)
        defaults.removeObject(forKey: Self.initialEpisodeBackfillOffsetKey)
        defaults.removeObject(forKey: Self.initialEpisodeBackfillCursorKey)
    }

    func resetInitialSubscriptionBackfillCursor() {
        clearInitialSubscriptionBackfillTotal()
        persistInitialBackfillCheckpoint(
            offset: 0,
            cursor: nil,
            checkpointKey: Self.initialSubscriptionBackfillCheckpointKey,
            offsetKey: Self.initialSubscriptionBackfillOffsetKey,
            cursorKey: Self.initialSubscriptionBackfillCursorKey
        )
    }

    func clearInitialSubscriptionBackfillCursor() {
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillCheckpointKey)
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillOffsetKey)
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillCursorKey)
    }

    func clearInitialEpisodeBackfillTotal() {
        defaults.removeObject(forKey: Self.initialEpisodeBackfillTotalAccountKey)
        defaults.removeObject(forKey: Self.initialEpisodeBackfillTotalKey)
    }

    func clearInitialSubscriptionBackfillTotal() {
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillTotalAccountKey)
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillTotalKey)
    }

    func clearInitialUploadCursors() {
        clearInitialEpisodeBackfillCursor()
        clearInitialSubscriptionBackfillCursor()
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
    }

    func resetInitialBackfillCursorsForEnabledOptions() {
        let verifiedAccountRecordName = isICloudAccountIdentityVerified
            ? defaults.string(forKey: Self.accountUserRecordNameKey)
            : nil
        if episodesSyncEnabled {
            resetInitialEpisodeBackfillCursor()
            if let verifiedAccountRecordName {
                defaults.set(verifiedAccountRecordName, forKey: Self.initialEpisodeBackfillAccountKey)
                defaults.removeObject(forKey: Self.initialEpisodeBackfillCompletedAccountKey)
            }
        }
        if subscriptionsSyncEnabled {
            resetInitialSubscriptionBackfillCursor()
            if let verifiedAccountRecordName {
                defaults.set(verifiedAccountRecordName, forKey: Self.initialSubscriptionBackfillAccountKey)
                defaults.removeObject(forKey: Self.initialSubscriptionBackfillCompletedAccountKey)
            }
            defaults.set(true, forKey: Self.suppressSubscriptionDeletionsKey)
        }
        if settingsSyncEnabled {
            defaults.set(true, forKey: Self.initialSettingsBackfillPendingKey)
        }
    }

    func applyInitialEpisodeQueue(_ objectHashes: [String], pendingKeys: inout Set<String>) async -> Bool {
        var queuedRecords = false
        var index = objectHashes.startIndex
        var chunkIndex = 0
        while index < objectHashes.endIndex {
            let end = objectHashes.index(index, offsetBy: Self.pendingChangeQueueChunkSize, limitedBy: objectHashes.endIndex) ?? objectHashes.endIndex
            guard episodesSyncEnabled, !Task.isCancelled else { return queuedRecords }
            let chunk = objectHashes[index..<end]
            addPendingSaves(chunk.map { episodeRecordID(forObjectHash: $0) }, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
            queuedRecords = true
            logSyncEvent("Initiale iCloud Episode-Queue Chunk angewendet", metadata: [
                "chunkIndex": chunkIndex,
                "chunkRecordCount": chunk.count,
                "knownPendingKeyCount": pendingKeys.count,
            ])
            index = end
            chunkIndex += 1
            await Task.yield()
        }
        return queuedRecords
    }

    func applyInitialSubscriptionQueue(_ feedURLs: [String], pendingKeys: inout Set<String>) async -> Bool {
        var queuedRecords = false
        var index = feedURLs.startIndex
        var chunkIndex = 0
        while index < feedURLs.endIndex {
            let end = feedURLs.index(index, offsetBy: Self.pendingChangeQueueChunkSize, limitedBy: feedURLs.endIndex) ?? feedURLs.endIndex
            guard subscriptionsSyncEnabled, !Task.isCancelled else { return queuedRecords }
            let chunk = feedURLs[index..<end]
            addPendingSaves(chunk.map { subscriptionRecordID(forFeedURL: $0) }, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
            addPendingDeletes(chunk.map { subscriptionTombstoneRecordID(forFeedURL: $0) },
                              pendingKeys: &pendingKeys)
            queuedRecords = true
            logSyncEvent("Initiale iCloud Abo-Queue Chunk angewendet", metadata: [
                "chunkIndex": chunkIndex,
                "chunkRecordCount": chunk.count,
                "knownPendingKeyCount": pendingKeys.count,
            ])
            index = end
            chunkIndex += 1
            await Task.yield()
        }
        return queuedRecords
    }

    func queueDeviceRecord(stampLastSyncDate: Bool = false, scheduleSync: Bool = true) {
        guard let intent = persistPendingDeviceControlSaveIntent(
            stampLastSyncDate: stampLastSyncDate
        ) else { return }
        if stampLastSyncDate {
            deviceRecordShouldStampSyncDate = true
            setSyncMetadata(true, forKey: Self.deviceRecordShouldStampSyncDateKey)
        }
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves([deviceRecordID(for: intent.targetDeviceID)],
                        pendingKeys: &pendingKeys,
                        stampDeviceRecordForUserData: false,
                        scheduleSync: scheduleSync)
    }

    func addPendingSave(_ recordID: CKRecord.ID) {
        addPendingSaves([recordID])
    }

    func addPendingSaves(_ recordIDs: [CKRecord.ID]) {
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves(recordIDs, pendingKeys: &pendingKeys, stampDeviceRecordForUserData: true, scheduleSync: true)
    }

    func addPendingSaves(_ recordIDs: [CKRecord.ID], pendingKeys: inout Set<String>, stampDeviceRecordForUserData: Bool, scheduleSync: Bool = false) {
        guard !recordIDs.isEmpty else { return }
        let containsUserData = containsUserDataRecordID(recordIDs)
        initializeSyncEngineIfNeeded()
        let changes = recordIDs.compactMap { recordID -> CKSyncEngine.PendingRecordZoneChange? in
            let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID)
            let key = pendingChangeKey(change)
            guard !pendingKeys.contains(key) else { return nil }
            pendingKeys.insert(key)
            return change
        }
        if !changes.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: changes)
        }
        if containsUserData, stampDeviceRecordForUserData {
            queueDeviceRecord(stampLastSyncDate: true)
        }
        if scheduleSync {
            scheduleLowPrioritySync()
        }
    }

    func addPendingDeletes(_ recordIDs: [CKRecord.ID], pendingKeys: inout Set<String>) {
        guard !recordIDs.isEmpty else { return }
        initializeSyncEngineIfNeeded()
        let changes = recordIDs.compactMap { recordID -> CKSyncEngine.PendingRecordZoneChange? in
            let change = CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID)
            let key = pendingChangeKey(change)
            guard !pendingKeys.contains(key) else { return nil }
            pendingKeys.insert(key)
            return change
        }
        if !changes.isEmpty {
            syncEngine?.state.add(pendingRecordZoneChanges: changes)
        }
    }

    func pendingRecordZoneChangeKeys() -> Set<String> {
        Set(syncEngine?.state.pendingRecordZoneChanges.map { pendingChangeKey($0) } ?? [])
    }

    func pendingChangeKey(_ change: CKSyncEngine.PendingRecordZoneChange) -> String {
        switch change {
        case .saveRecord(let recordID):
            return "save:\(recordID.recordName)"
        case .deleteRecord(let recordID):
            return "delete:\(recordID.recordName)"
        @unknown default:
            return "unknown"
        }
    }

    func containsUserDataRecordID(_ recordIDs: [CKRecord.ID]) -> Bool {
        recordIDs.contains { isUserDataRecordID($0) }
    }

    func isUserDataRecordID(_ recordID: CKRecord.ID) -> Bool {
        Self.isUserDataRecordName(recordID.recordName)
    }

    func isCloudInventoryRecordType(_ recordType: String) -> Bool {
        recordType == RecordKind.episodeState
            || recordType == RecordKind.subscription
            || recordType == RecordKind.appSettings
    }

    func isBulkEchoRecord(_ record: CKRecord) -> Bool {
        record.recordType == RecordKind.episodeState
            || record.recordType == RecordKind.subscription
            || record.recordType == RecordKind.subscriptionTombstone
    }

    nonisolated static func isUserDataRecordName(_ recordName: String) -> Bool {
        recordName.hasPrefix(RecordPrefix.episode)
        || recordName.hasPrefix(RecordPrefix.subscription)
        || recordName.hasPrefix(RecordPrefix.subscriptionTombstone)
        || recordName == RecordPrefix.appSettings
        || recordName == RecordPrefix.listScrollPositions
        || recordName == RecordPrefix.subscriptionListSettings
    }

    func hasPendingUserDataChanges() -> Bool {
        guard let syncEngine else { return false }
        return syncEngine.state.pendingRecordZoneChanges.contains { change in
            switch change {
            case .saveRecord(let recordID), .deleteRecord(let recordID):
                return isUserDataRecordID(recordID)
            @unknown default:
                return false
            }
        }
    }

    func queueDeviceRecordForPendingUserDataIfNeeded() {
        guard hasPendingUserDataChanges() else { return }
        queueDeviceRecord(stampLastSyncDate: true)
    }
}
