//
//  ICiCloudSyncManager.swift
//  Instacast
//

@preconcurrency import CloudKit
import CoreData
import CryptoKit
import Darwin
import Foundation
import UIKit

final class ICiCloudSyncEngineCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var engineIdentifier: ObjectIdentifier?
    private var generation = 0
    private var isSignedOut = false
    private var isAccountIdentityVerified = false
    private var localCaptureAccountRecordName: String?
    private var deleteAttemptRevisionsByRecordName: [String: [String]] = [:]
    private var resolvedInitialUploadRecordNames: Set<String> = []
    private var localUploadReadFailed = false

    func update(syncEngine: CKSyncEngine?, generation: Int, isSignedOut: Bool,
                isAccountIdentityVerified: Bool, accountRecordName: String?) {
        lock.lock()
        let engineChanged = engineIdentifier != syncEngine.map(ObjectIdentifier.init)
            || self.generation != generation
        engineIdentifier = syncEngine.map(ObjectIdentifier.init)
        self.generation = generation
        self.isSignedOut = isSignedOut
        self.isAccountIdentityVerified = isAccountIdentityVerified
        if !isSignedOut && isAccountIdentityVerified {
            localCaptureAccountRecordName = accountRecordName
        } else {
            localCaptureAccountRecordName = nil
        }
        if engineChanged || isSignedOut || !isAccountIdentityVerified {
            deleteAttemptRevisionsByRecordName = [:]
            resolvedInitialUploadRecordNames = []
            localUploadReadFailed = false
        }
        lock.unlock()
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
                                    generation: Int,
                                    for syncEngine: CKSyncEngine) {
        guard !resolvedRecordNames.isEmpty || localReadFailed else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut, isAccountIdentityVerified,
              self.generation == generation,
              engineIdentifier == ObjectIdentifier(syncEngine) else { return }
        resolvedInitialUploadRecordNames.formUnion(resolvedRecordNames)
        self.localUploadReadFailed = self.localUploadReadFailed || localReadFailed
    }

    func takeInitialUploadOutcome(generation: Int,
                                  for syncEngine: CKSyncEngine) -> (resolvedRecordNames: Set<String>, localReadFailed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !isSignedOut, isAccountIdentityVerified,
              self.generation == generation,
              engineIdentifier == ObjectIdentifier(syncEngine) else { return ([], false) }
        let outcome = (resolvedInitialUploadRecordNames, localUploadReadFailed)
        resolvedInitialUploadRecordNames = []
        localUploadReadFailed = false
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
    nonisolated static let initialSettingsBackfillPendingKey = "ICiCloudSyncInitialSettingsBackfillPending"
    nonisolated static let pendingInitialSettingsPayloadKey = "ICiCloudSyncPendingInitialSettingsPayload"
    @objc static let initialSettingsChoiceNeededNotification = "ICiCloudSyncInitialSettingsChoiceNeeded"
    nonisolated static let settingsLocalModifiedDateKey = "ICiCloudSyncSettingsLocalModifiedDate"
    nonisolated static let settingsSyncedHashKey = "ICiCloudSyncSettingsSyncedHash"
    nonisolated static let suppressSubscriptionDeletionsKey = "ICiCloudSyncSuppressSubscriptionDeletions"
    nonisolated static let cloudInventoryKey = "ICiCloudSyncCloudInventory"
    nonisolated static let cloudInventoryPayloadScanCompletedKey = "ICiCloudSyncCloudInventoryPayloadScanCompleted"
    nonisolated static let transitionalSubscriptionInventoryRecordsKey = "ICiCloudSyncTransitionalSubscriptionInventoryRecords"
    nonisolated static let subscriptionListSettingsLocalModifiedDateKey = "ICiCloudSyncSubscriptionListSettingsLocalModifiedDate"
    nonisolated static let subscriptionListSettingsBaselineKey = "ICiCloudSyncSubscriptionListSettingsBaseline"
    // Mirrors the file-private kManualFeedOrderKey in DatabaseManager.m.
    nonisolated static let manualFeedOrderDefaultsKey = "ManualFeedOrder"
    nonisolated static let scrollPositionsLocalModifiedDateKey = "ICiCloudSyncScrollPositionsLocalModifiedDate"
    nonisolated static let lastSyncDateKey = "ICiCloudSyncLastSyncDate"
    nonisolated static let lastStatusKey = "ICiCloudSyncLastStatus"
    nonisolated static let lastErrorKey = "ICiCloudSyncLastError"
    nonisolated static let deviceRecordShouldStampSyncDateKey = "ICiCloudSyncDeviceRecordShouldStampSyncDate"
    nonisolated static let finalDeviceRecordUpdatePendingKey = "ICiCloudSyncFinalDeviceRecordUpdatePending"
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
    nonisolated static let localOutboxSaveOperation = "save"
    nonisolated static let localOutboxDeleteOperation = "delete"
    nonisolated static let localMutationRevisionPayloadKey = "_icLocalMutationRevision"
    // CloudKit accepts at most 250 saves + deletes per request. CKSyncEngine can request
    // several of these bounded batches during one sendChanges() call.
    nonisolated static let maximumRecordZoneChangesPerBatch = 250
    nonisolated static let pendingChangeQueueChunkSize = 250
    nonisolated static let remoteApplyBatchSize = 100
    nonisolated static let syncMetadataDirectoryName = "iCloudSyncMetadata"
    nonisolated static let legacyKnownRecordSystemFieldsDirectoryName = "KnownRecords"
    nonisolated static let legacySyncItemMetadataErrorDomain = "ICiCloudSyncLegacyMetadata"

    nonisolated static var fileBackedSyncMetadataKeys: Set<String> {
        [
            Self.engineStateKey,
            Self.knownRecordsKey,
            Self.accountResetRequiredKey,
            Self.finalDeviceRecordUpdatePendingKey,
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

    let defaults = UserDefaults.standard
    let container = CKContainer(identifier: ICiCloudSyncManager.containerIdentifier)
    let zoneID = CKRecordZone.ID(zoneName: ICiCloudSyncManager.zoneName)
    nonisolated let syncEngineCallbackGate = ICiCloudSyncEngineCallbackGate()
    var syncEngine: CKSyncEngine?
    var isStarted = false
    var isDeletingAllICloudData = false
    var isApplyingRemoteChange = false
    var isWritingSyncMetadata = false
    var hasUnresolvedSyncFailures = false
    var requiresSyncEngineStateRollbackAfterPersistenceFailure = false
    var settingsDebounceWorkItem: DispatchWorkItem?
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
    var lastForegroundSyncDate: Date?
    var didPruneEpisodeLocalModifiedDates = false
    var isApplyingPendingSubscriptions = false
    var syncActivityExpectedCount = 0
    var syncActivityKindLabel: String?
    var isFetchingCloudInventory = false
    private(set) var cloudInventoryRefreshErrorText: String?
    var cloudInventoryRefreshInProgress: Bool { isFetchingCloudInventory }
    var pendingCloudInventoryRefreshReason: String?
    var requestedCloudInventoryRefreshReason: String?
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
    var requiresImmediateFinalDeviceRecordResend = false
    var isICloudAccountTransitionRunning = false
    var iCloudAccountTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    var iCloudAccountTransitionToken = 0
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
    var syncActivityStartDate: Date?
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

    var hasPendingFinalDeviceRecordUpdate: Bool {
        (Self.syncMetadataValue(forKey: Self.finalDeviceRecordUpdatePendingKey) as? NSNumber)?.boolValue == true
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
    }

    @objc var lastSyncDate: Date? {
        defaults.object(forKey: Self.lastSyncDateKey) as? Date
    }

    @objc var syncCounts: ICiCloudSyncCounts {
        let totals = syncTotalCounts()
        return ICiCloudSyncCounts(
            episodesSynced: episodesSyncEnabled ? syncedCount(backfillKey: Self.initialEpisodeBackfillOffsetKey, total: totals.episodes) : 0,
            episodesTotal: episodesSyncEnabled ? totals.episodes : 0,
            subscriptionsSynced: subscriptionsSyncEnabled ? syncedCount(backfillKey: Self.initialSubscriptionBackfillOffsetKey, total: totals.subscriptions) : 0,
            subscriptionsTotal: subscriptionsSyncEnabled ? totals.subscriptions : 0,
            settings: settingsSyncEnabled ? totals.settings : 0,
            countsAvailable: cachedSyncTotalCounts != nil)
    }

    // How many of `total` are already synced: while the initial backfill runs, its persisted
    // page cursor is how far we've gotten; once it's cleared the whole set is synced.
    func syncedCount(backfillKey: String, total: Int) -> Int {
        guard let offset = (defaults.object(forKey: backfillKey) as? NSNumber)?.intValue else {
            return total
        }
        return min(max(offset, 0), total)
    }

    // Stable totals of what's kept in iCloud, counted directly in Core Data so the number is
    // the real total (e.g. "4490 episodes with play state") instead of a sync-progress figure.
    // The count itself runs on a BACKGROUND context — never the main thread — because a
    // count on the main context can block for seconds waiting on the SQLite store lock that
    // the background backfill/refresh holds (this was a multi-second UI freeze when toggling a
    // switch). The UI shows the last computed value and refreshes when a new one is ready.
    func syncTotalCounts() -> (episodes: Int, subscriptions: Int, settings: Int) {
        let cached = cachedSyncTotalCounts
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
            let counts = await Self.computeSyncTotalCounts(episodesEnabled: episodesEnabled, subscriptionsEnabled: subscriptionsEnabled, settingsEnabled: settingsEnabled)
            await MainActor.run {
                guard let self else { return }
                self.cachedSyncTotalCounts = (counts.episodes, counts.subscriptions, counts.settings, Date())
                self.isRefreshingSyncTotalCounts = false
                self.postStateChanged()
            }
        }
    }

    nonisolated static func computeSyncTotalCounts(episodesEnabled: Bool, subscriptionsEnabled: Bool, settingsEnabled: Bool) async -> (episodes: Int, subscriptions: Int, settings: Int) {
        // The settings count copies and filters the whole defaults domain — do that here,
        // off the main thread, together with the Core Data counts.
        let settings = settingsEnabled ? syncedSettingsValueCount() : 0
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else { return (0, 0, settings) }
        return await context.perform {
            var episodes = 0
            var subscriptions = 0
            if episodesEnabled {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Episode")
                request.predicate = NSPredicate(format: "feed.subscribed == YES AND archived == NO AND objectHash != nil AND (consumed == YES OR starred == YES OR position > 0)")
                episodes = (try? context.count(for: request)) ?? 0
            }
            if subscriptionsEnabled {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Feed")
                request.predicate = NSPredicate(format: "subscribed == YES AND sourceURL_ != nil")
                subscriptions = (try? context.count(for: request)) ?? 0
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
        if isHydratingStubFeeds, hydrationTotalCount > 0 {
            return String(format: NSLocalizedString("Lade Podcast-Folgen… %ld/%ld", comment: ""), hydrationCompletedCount, hydrationTotalCount)
        }
        // While the initial backfill pages through, the stable "Lädt hoch… X / Y"
        // (lastStatus, updated per page) wins over the per-batch activity counter —
        // alternating between the two number formats read as status "flickering".
        if !hasInitialUploadBackfillWork, let activity = syncActivityStatusText() {
            return activity
        }
        if let status = defaults.string(forKey: Self.lastStatusKey), !status.isEmpty {
            return status
        }
        return NSLocalizedString("Bereit", comment: "")
    }

    @objc var devices: [ICiCloudSyncDeviceInfo] {
        deviceCache().compactMap { key, value in
            let value = key == deviceID ? value.merging(localDevicePayload()) { _, current in current } : value
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
                                          isCurrentDevice: key == deviceID)
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

        if anySyncEnabled || hasPendingFinalDeviceRecordUpdate {
            initializeSyncEngineIfNeeded()
            if anySyncEnabled {
                queueDeviceRecordForPendingUserDataIfNeeded()
                if hasInitialUploadBackfillWork, !isICloudAccountSignedOut, isICloudAccountIdentityVerified {
                    scheduleCurrentEnabledDataForUpload()
                }
                // Retry payloads that arrived before their episode/feed existed locally and
                // whose normal trigger (new episodes added) didn't fire again before the app
                // was quit — without this they could sit in the pending store indefinitely.
                scheduleApplyPendingPayloads()
                // Publishes the sort mode/settings if their fingerprint baseline is missing
                // (devices that enabled subscription sync before this record type existed).
                scheduleSettingsChangeCheck()
                hydrateStubFeedsIfNeeded()
            }
            Task { @MainActor in
                await refreshAccountStatus()
                guard isICloudAccountIdentityVerified else { return }
                resumePendingFinalDeviceRecordUpdateIfNeeded()
                if anySyncEnabled {
                    if await drainLocalOutbox() {
                        scheduleLowPrioritySync()
                    }
                }
            }
        }
    }

    // CKSyncEngine runs with automaticallySync = false, so nothing syncs on its own:
    // remote changes only arrive via push (best effort — often dropped after a force
    // quit), after a local change, or via manual sync. Without this hook a device could
    // stay on a stale state indefinitely while showing "Bereit". Called on launch and on
    // foreground entry, throttled like the feed auto-refresh.
    @objc func performForegroundSyncIfNeeded() {
        guard isStarted, anySyncEnabled else { return }
        let now = Date()
        if let last = lastForegroundSyncDate, now.timeIntervalSince(last) < 15 * 60 {
            return
        }
        lastForegroundSyncDate = now
        logSyncEvent("Foreground-Sync angestoßen")
        setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
        Task { @MainActor in
            await refreshAccountStatus()
            guard isICloudAccountIdentityVerified else { return }
            scheduleLowPrioritySync()
            // Resume any interrupted episode loading for stub feeds; feeds that failed in
            // the previous session/run get one fresh attempt per foreground entry.
            hydrationFailedFeedIDs.removeAll()
            hydrateStubFeedsIfNeeded()
        }
    }

    @objc func setEpisodesSyncEnabled(_ enabled: Bool) {
        guard applyEpisodesSyncEnabled(enabled) else { return }
        logSyncEvent("Episode Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @discardableResult
    private func applyEpisodesSyncEnabled(_ enabled: Bool) -> Bool {
        guard episodesSyncEnabled != enabled else { return false }
        defaults.set(enabled, forKey: ICiCloudSyncEpisodesEnabled)
        if enabled {
            defaults.set(true, forKey: Self.episodesSyncHasParticipatedKey)
            resetInitialEpisodeBackfillCursor()
        } else {
            discardInitialUploadCheckpoints(episodes: true, subscriptions: false)
            clearInitialEpisodeBackfillCursor()
        }
        return true
    }

    @objc func setSubscriptionsSyncEnabled(_ enabled: Bool) {
        guard applySubscriptionsSyncEnabled(enabled) else { return }
        logSyncEvent("Abo Sync-Schalter geändert", metadata: ["enabled": enabled])
        syncOptionsChanged()
    }

    @discardableResult
    private func applySubscriptionsSyncEnabled(_ enabled: Bool) -> Bool {
        guard subscriptionsSyncEnabled != enabled else { return false }
        defaults.set(enabled, forKey: ICiCloudSyncSubscriptionsEnabled)
        if enabled {
            defaults.set(true, forKey: Self.subscriptionsSyncHasParticipatedKey)
            resetInitialSubscriptionBackfillCursor()
            // Enabling must NEVER delete local subscriptions: deletions that piled up in
            // the cloud while sync was off arrive in the catch-up fetch and are suppressed
            // until the first complete fetch has run (union semantics — the local copy is
            // re-uploaded by the backfill). Only live deletions after that are applied.
            defaults.set(true, forKey: Self.suppressSubscriptionDeletionsKey)
        } else {
            discardInitialUploadCheckpoints(episodes: false, subscriptions: true)
            clearInitialSubscriptionBackfillCursor()
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
        logSyncEvent("iCloud Sync-Schalter aus Backup wiederhergestellt", metadata: [
            "episodesPresent": episodes != nil,
            "subscriptionsPresent": subscriptions != nil,
            "settingsPresent": settings != nil,
        ])
        syncOptionsChanged()
    }

    @objc func syncOptionsChanged() {
        if !anySyncEnabled, !persistFinalDeviceRecordUpdateIntent() {
            postStateChanged()
            return
        }
        guard isStarted else { return }

        logSyncEvent("Sync-Optionen geändert")
        if anySyncEnabled {
            clearError()
            setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
            Task { @MainActor in
                await refreshAccountStatus()
                guard isICloudAccountIdentityVerified else { return }
                if await drainLocalOutbox() {
                    scheduleLowPrioritySync()
                }
            }
            postStateChanged()
            return
        }

        logSyncEvent("iCloud Sync deaktiviert")
        clearError()
        cancelInitialQueueTask()
        clearInitialUploadCursors()
        if isICloudAccountSignedOut {
            setStatus(NSLocalizedString("Aus", comment: ""))
            postStateChanged()
            return
        }
        setStatus(NSLocalizedString("iCloud prüfen…", comment: ""))
        Task { @MainActor in
            await refreshAccountStatus()
            guard isICloudAccountIdentityVerified else { return }
            resumePendingFinalDeviceRecordUpdateIfNeeded()
            postStateChanged()
        }
        postStateChanged()
    }

    @discardableResult
    func persistFinalDeviceRecordUpdateIntent() -> Bool {
        do {
            _ = try Self.writeSyncMetadataValue(true, forKey: Self.finalDeviceRecordUpdatePendingKey)
            defaults.removeObject(forKey: Self.finalDeviceRecordUpdatePendingKey)
            return true
        } catch {
            handleLocalPersistenceFailure(error)
            return false
        }
    }

    func clearPendingFinalDeviceRecordUpdateIntent() {
        Self.removeSyncMetadataValue(forKey: Self.finalDeviceRecordUpdatePendingKey)
        defaults.removeObject(forKey: Self.finalDeviceRecordUpdatePendingKey)
    }

    func resumePendingFinalDeviceRecordUpdateIfNeeded() {
        guard hasPendingFinalDeviceRecordUpdate,
              !isDeletingAllICloudData,
              !isICloudAccountSignedOut,
              isICloudAccountIdentityVerified else { return }
        queueDeviceRecord()
        if anySyncEnabled {
            scheduleLowPrioritySync()
        } else {
            sendFinalDeviceRecordUpdate()
        }
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
            do {
                try await self.sendChangesAndApplyCallbackOutcomes(syncEngine, generation: cloudGeneration)
            } catch {
                guard generation == self.finalDeviceRecordUpdateGeneration else { return }
                self.finalDeviceRecordUpdateTask = nil
                self.setError(error)
                self.scheduleSyncRetryAfterFailure(error: error, reason: "finalDeviceRecord")
                return
            }
            guard generation == self.finalDeviceRecordUpdateGeneration else { return }
            self.finalDeviceRecordUpdateTask = nil
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
        Task { @MainActor in
            guard !isDeletingAllICloudData else {
                completion(nil)
                return
            }
            if isICloudAccountSignedOut || !isICloudAccountIdentityVerified {
                await refreshAccountStatus()
                guard !isICloudAccountSignedOut, isICloudAccountIdentityVerified else {
                    completion(nil)
                    return
                }
            }
            guard !isDeletingAllICloudData,
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
                self.isPerformingManualSync = true
                self.postStateChanged()
                defer {
                    self.manualSyncTask = nil
                    if generation == self.cloudAccountGeneration {
                        self.isPerformingManualSync = false
                        self.postStateChanged()
                    }
                    if self.isICloudAccountIdentityVerified,
                       !self.hasUnresolvedSyncFailures,
                       self.hasPendingSyncChanges {
                        self.scheduleLowPrioritySync()
                    }
                }
                do {
                    try await self.performManualSync()
                    guard generation == self.cloudAccountGeneration,
                          self.isICloudAccountIdentityVerified else {
                        completion(nil)
                        return
                    }
                    completion(nil)
                } catch {
                    guard generation == self.cloudAccountGeneration,
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

            if let accountRecordName = defaults.string(forKey: Self.accountUserRecordNameKey) {
                deleteLocalOutboxEntries(for: accountRecordName)
            }
            do {
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
            resetAllLocalSyncMetadata()
            clearPendingFinalDeviceRecordUpdateIntent()
            isDeletingAllICloudData = false
            // The "On iCloud" rows kept showing the pre-delete counts (stale cache,
            // refreshed only every 30s) — reflect the now-empty zone immediately.
            storeCloudInventory([:], reason: "deleteAllICloudData")

            if anySyncEnabled {
                initializeSyncEngineIfNeeded()
                resetInitialBackfillCursorsForEnabledOptions()
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
    @objc func prepareForLocalAppResetWithCompletion(_ completion: @escaping (NSError?) -> Void) {
        Task { @MainActor in
            isStarted = false
            defaults.set(false, forKey: ICiCloudSyncEpisodesEnabled)
            defaults.set(false, forKey: ICiCloudSyncSubscriptionsEnabled)
            defaults.set(false, forKey: ICiCloudSyncSettingsEnabled)
            cloudAccountGeneration &+= 1
            updateSyncEngineCallbackGate()

            let tasks = [initialQueueTask, lowPrioritySyncTask, accountVerificationTask,
                         manualSyncTask, backgroundSyncTask, finalDeviceRecordUpdateTask,
                         localOutboxDrainTask].compactMap { $0 }
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
            initialQueueTask = nil
            lowPrioritySyncTask = nil
            accountVerificationTask = nil
            manualSyncTask = nil
            backgroundSyncTask = nil
            finalDeviceRecordUpdateTask = nil
            localOutboxDrainTask = nil
            syncEngine = nil

            do {
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

            if let context = databaseManager.objectContext {
                let request = NSFetchRequest<NSManagedObject>(entityName: Self.localOutboxEntityName)
                do {
                    for entry in try context.fetch(request) { context.delete(entry) }
                } catch {
                    completion(error as NSError)
                    return
                }
                if let saveError = databaseManager.saveReturningError() {
                    completion(saveError as NSError)
                    return
                }
            }

            resetAllLocalSyncMetadata()
            clearPendingFinalDeviceRecordUpdateIntent()
            setStatus(NSLocalizedString("Aus", comment: ""))
            postStateChanged()
            completion(nil)
        }
    }

    func resetAllLocalSyncMetadata() {
        settingsDebounceWorkItem?.cancel()
        settingsDebounceWorkItem = nil
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

        cloudAccountGeneration &+= 1
        updateSyncEngineCallbackGate()
        isFetchingCloudInventory = false
        cloudInventoryRefreshErrorText = nil
        pendingCloudInventoryRefreshReason = nil
        setSyncMetadata(nil, forKey: Self.engineStateKey)
        Self.removeSyncMetadataValue(forKey: Self.knownRecordsKey)
        for key in [Self.deviceCacheKey, Self.pendingEpisodeStatesKey, Self.pendingSubscriptionPayloadsKey,
                    Self.pendingSubscriptionFetchCompleteKey,
                    Self.transitionalSubscriptionInventoryRecordsKey,
                    Self.pendingInitialSettingsPayloadKey] {
            setSyncMetadata(nil, forKey: key)
        }
        for key in [Self.settingsLocalModifiedDateKey, Self.settingsSyncedHashKey,
                    Self.scrollPositionsLocalModifiedDateKey, Self.suppressSubscriptionDeletionsKey,
                    Self.subscriptionListSettingsLocalModifiedDateKey, Self.subscriptionListSettingsBaselineKey,
                    Self.lastSyncDateKey, Self.deviceRecordShouldStampSyncDateKey, Self.cloudInventoryKey,
                    Self.cloudInventoryPayloadScanCompletedKey] {
            defaults.removeObject(forKey: key)
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
        clearInitialUploadCursors()
        clearSyncActivity()
        clearError()
    }

    @objc func shouldHandleRemoteNotification(_ userInfo: NSDictionary) -> Bool {
        guard let notification = userInfo as? [AnyHashable: Any] else { return false }
        return CKNotification(fromRemoteNotificationDictionary: notification) != nil
    }

    @objc func performBackgroundSyncWithCompletion(_ completion: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            guard !isDeletingAllICloudData else {
                completion(.noData)
                return
            }
            guard anySyncEnabled else {
                completion(.noData)
                return
            }
            await refreshAccountStatus()
            guard !isDeletingAllICloudData,
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
                self.initializeSyncEngineIfNeeded()
                self.hasUnresolvedSyncFailures = false
                let syncCycleGeneration = self.beginSyncCycle()
                defer {
                    self.endSyncCycle(syncCycleGeneration)
                    self.backgroundSyncTask = nil
                    if self.isICloudAccountIdentityVerified,
                       !self.hasUnresolvedSyncFailures,
                       self.hasPendingSyncChanges {
                        self.scheduleLowPrioritySync()
                    }
                }

                do {
                    if let syncEngine = self.syncEngine {
                        try await syncEngine.fetchChanges()
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
    }

    func runRequestedCloudInventoryRefresh() {
        guard requestedCloudInventoryRefreshReason != nil else { return }
        requestedCloudInventoryRefreshReason = nil
        refreshCloudInventory(reason: "settingsActionAfterSync")
    }

    func transitionalSubscriptionInventoryRecords() -> [String: String] {
        Self.syncMetadataValue(forKey: Self.transitionalSubscriptionInventoryRecordsKey) as? [String: String] ?? [:]
    }

    func refreshCloudInventory(reason: String) {
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
        guard !isFetchingCloudInventory else {
            // A refresh is already in flight; remember the reason so it re-runs afterwards.
            // No diagnostics line here — this "skipped" path fired 253× in one capture (pure noise).
            pendingCloudInventoryRefreshReason = reason
            return
        }
        let generation = cloudAccountGeneration
        pendingCloudInventoryRefreshReason = nil
        cloudInventoryRefreshErrorText = nil
        isFetchingCloudInventory = true
        postStateChanged()
        var metadata: [String: Any] = ["reason": reason]
        metadata.merge(syncDiagnosticsMetadata()) { current, _ in current }
        logSyncEvent("Cloud-Inventar-Abfrage gestartet", metadata: metadata)

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
            if case .success(let record) = result {
                box.record(record)
            }
        }
        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            box.remove(recordName: recordID.recordName)
        }
        operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.cloudAccountGeneration else { return }
                self.isFetchingCloudInventory = false
                switch result {
                case .success:
                    self.setSyncMetadata(box.transitionalSubscriptionRecords(),
                                         forKey: Self.transitionalSubscriptionInventoryRecordsKey)
                    if shouldInspectPayloads {
                        self.setSyncMetadata(true, forKey: Self.cloudInventoryPayloadScanCompletedKey)
                    }
                    self.storeCloudInventory(box.snapshot(), reason: reason)
                    self.fetchDeviceRecordsForInventory(box.deviceIDs(), generation: generation)
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .zoneNotFound || ckError.code == .userDeletedZone {
                        self.setSyncMetadata([String: String](),
                                             forKey: Self.transitionalSubscriptionInventoryRecordsKey)
                        self.setSyncMetadata(true, forKey: Self.cloudInventoryPayloadScanCompletedKey)
                        self.storeCloudInventory([:], reason: reason)
                    } else {
                        self.cloudInventoryRefreshErrorText = NSLocalizedString("iCloud data counts could not be updated.", comment: "")
                        var metadata = self.cloudKitErrorMetadata(error)
                        metadata["reason"] = reason
                        metadata.merge(self.syncDiagnosticsMetadata()) { current, _ in current }
                        self.logSyncEvent("Cloud-Inventar-Abfrage fehlgeschlagen", metadata: metadata)
                        self.postStateChanged()
                    }
                }
                self.runPendingCloudInventoryRefreshIfNeeded()
            }
        }
        database.add(operation)
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

        cancelLowPrioritySyncTask()
        resetSyncRetryBackoff()
        initializeSyncEngineIfNeeded()
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
            try await sendChangesAndApplyCallbackOutcomes(syncEngine, generation: generation)
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
            try await syncEngine.fetchChanges()
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified else { return }
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

    var deviceID: String {
        if let stored = defaults.string(forKey: Self.deviceIDKey), !stored.isEmpty {
            return stored
        }
        let newID = UUID().uuidString
        setSyncMetadata(newID, forKey: Self.deviceIDKey)
        return newID
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
                                      accountRecordName: defaults.string(forKey: Self.accountUserRecordNameKey))
    }

    func loadStateSerialization() -> CKSyncEngine.State.Serialization? {
        guard !isICloudAccountResetRequired else { return nil }
        guard let data = Self.syncMetadataValue(forKey: Self.engineStateKey) as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    func persistStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        if let data = try? JSONEncoder().encode(serialization) {
            setSyncMetadata(data, forKey: Self.engineStateKey)
        }
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
              !isICloudAccountSignedOut, isICloudAccountIdentityVerified else { return }
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
        let generation = cloudAccountGeneration
        guard anySyncEnabled, !isICloudAccountSignedOut, isICloudAccountIdentityVerified,
              !Task.isCancelled else {
            return
        }

        initializeSyncEngineIfNeeded()
        if hasInitialUploadBackfillWork {
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
            lowPrioritySyncTask = nil
            postStateChanged()
            return
        }
        let outboxReadSucceeded = await drainLocalOutbox()
        guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
              !Task.isCancelled, outboxReadSucceeded, !hasUnresolvedSyncFailures else {
            lowPrioritySyncTask = nil
            postStateChanged()
            return
        }
        let syncCycleGeneration = beginSyncCycle()
        defer { endSyncCycle(syncCycleGeneration) }
        logSyncEvent("iCloud Sync mit niedriger Priorität gestartet", metadata: syncDiagnosticsMetadata())
        postStateChanged()

        do {
            if let syncEngine = syncEngine {
                try await sendChangesAndApplyCallbackOutcomes(syncEngine, generation: generation)
                guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                      !Task.isCancelled else { return }
                // While the initial backfill still has pages to upload, only send — defer the
                // fetch until everything is up. The last page clears the cursor before it
                // syncs, so that run still fetches. This stops the status flipping up/down
                // every page and saves a network round-trip per page.
                if !hasInitialUploadBackfillWork || hasIncompletePendingSubscriptionFetch {
                    try await syncEngine.fetchChanges()
                    guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                          !Task.isCancelled else { return }
                }
            }
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  !Task.isCancelled else { return }
            lowPrioritySyncTask = nil
            if !hasUnresolvedSyncFailures {
                markSyncCompletedIfFinished(allowActiveSyncCycle: true)
            } else {
                postStateChanged()
            }
            if anySyncEnabled, !hasUnresolvedSyncFailures, hasPendingSyncChanges {
                scheduleLowPrioritySync()
            }
        } catch {
            guard generation == cloudAccountGeneration, isICloudAccountIdentityVerified,
                  !Task.isCancelled else { return }
            lowPrioritySyncTask = nil
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
        guard isStarted, anySyncEnabled || hasPendingFinalDeviceRecordUpdate else { return }
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
                      self.anySyncEnabled || self.hasPendingFinalDeviceRecordUpdate else { return }
                if shouldVerifyAccount {
                    await self.refreshAccountStatus()
                    if self.isICloudAccountIdentityVerified {
                        self.resumePendingFinalDeviceRecordUpdateIfNeeded()
                        guard self.anySyncEnabled else { return }
                        if self.hasInitialUploadBackfillWork, !self.hasPendingSyncChanges {
                            self.scheduleCurrentEnabledDataForUpload()
                        } else {
                            self.scheduleLowPrioritySync()
                        }
                    }
                } else {
                    self.resumePendingFinalDeviceRecordUpdateIfNeeded()
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
            cursorKey: Self.initialEpisodeBackfillCursorKey
        )
        let subscriptionState = initialBackfillState(
            enabled: subscriptionsSyncEnabled,
            offsetKey: Self.initialSubscriptionBackfillOffsetKey,
            cursorKey: Self.initialSubscriptionBackfillCursorKey
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
        cursorKey: String
    ) -> (offset: Int?, cursor: String?) {
        guard enabled, let storedOffset = (defaults.object(forKey: offsetKey) as? NSNumber)?.intValue else {
            return (nil, nil)
        }
        let offset = max(0, storedOffset)
        let cursor = defaults.string(forKey: cursorKey)
        if offset > 0, cursor == nil {
            // Legacy versions persisted only a mutable row offset. It cannot be mapped to
            // a stable identifier after offline inserts/deletes, so restart the idempotent
            // backfill instead of silently skipping records.
            defaults.set(0, forKey: offsetKey)
            defaults.removeObject(forKey: cursorKey)
            return (0, nil)
        }
        if offset == 0, cursor != nil {
            defaults.removeObject(forKey: cursorKey)
            return (0, nil)
        }
        return (offset, cursor)
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
        let hasEpisodeBackfill = snapshot.episodeBackfillOffset != nil
        let hasSubscriptionBackfill = snapshot.subscriptionBackfillOffset != nil
        guard hasEpisodeBackfill || hasSubscriptionBackfill else {
            return InitialUploadPlan(snapshot: snapshot,
                                     createdAt: createdAt,
                                     pages: [],
                                     episodeObjectHashes: [],
                                     subscribedFeedURLs: [],
                                     syncItemMetadataWrites: [],
                                     preparationSucceeded: true)
        }

        async let episodePage = hasEpisodeBackfill
            ? episodeObjectHashesForInitialUploadPlan(cursor: snapshot.episodeBackfillCursor)
            : InitialUploadPage(values: [], nextCursor: nil, succeeded: true)
        async let subscriptionPage = hasSubscriptionBackfill
            ? subscribedFeedURLsForInitialUploadPlan(cursor: snapshot.subscriptionBackfillCursor)
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
            : (snapshot.episodeBackfillOffset ?? 0) + episodes.values.count
        let nextSubscriptionOffset = subscriptions.nextCursor == nil
            ? nil
            : (snapshot.subscriptionBackfillOffset ?? 0) + subscriptions.values.count
        let page = InitialUploadPlanPage(
            episodeObjectHashes: episodes.values,
            subscribedFeedURLs: subscriptions.values,
            nextEpisodeBackfillOffset: nextEpisodeOffset,
            nextSubscriptionBackfillOffset: nextSubscriptionOffset,
            nextEpisodeBackfillCursor: episodes.nextCursor,
            nextSubscriptionBackfillCursor: subscriptions.nextCursor,
            hasEpisodeBackfill: hasEpisodeBackfill,
            hasSubscriptionBackfill: hasSubscriptionBackfill
        )

        var syncItemMetadataWrites: [ICCloudSyncItemMetadataWrite] = []
        syncItemMetadataWrites.reserveCapacity(episodes.values.count + subscriptions.values.count)
        for objectHash in episodes.values {
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
            syncItemMetadataWrites.append(ICCloudSyncItemMetadataWrite(
                category: localOutboxSubscriptionCategory,
                recordName: subscriptionRecordName(forFeedURL: feedURL),
                itemIdentifier: feedURL,
                localModifiedAt: createdAt,
                localState: true,
                payloadHash: subscriptions.payloadHashes[feedURL]
            ))
        }

        Self.logSyncEvent("Initialer iCloud Upload-Plan fertig", metadata: [
            "pageCount": 1,
            "episodeObjectHashCount": episodes.values.count,
            "subscribedFeedURLCount": subscriptions.values.count,
            "syncItemMetadataWriteCount": syncItemMetadataWrites.count,
            "preparationSucceeded": true,
        ])
        return InitialUploadPlan(snapshot: snapshot,
                                 createdAt: createdAt,
                                 pages: [page],
                                 episodeObjectHashes: episodes.values,
                                 subscribedFeedURLs: subscriptions.values,
                                 syncItemMetadataWrites: syncItemMetadataWrites,
                                 preparationSucceeded: true)
    }

    nonisolated static func episodeObjectHashesForInitialUploadPlan(cursor: String?) async -> InitialUploadPage {
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            return InitialUploadPage(values: [], nextCursor: nil, succeeded: false)
        }
        return await context.perform {
            let request = NSFetchRequest<NSDictionary>(entityName: "Episode")
            request.resultType = .dictionaryResultType
            request.includesSubentities = false
            request.fetchLimit = Self.pendingChangeQueueChunkSize + 1
            request.propertiesToFetch = ["objectHash"]
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
        guard let context = DatabaseManager.shared()?.newBackgroundContext() else {
            return InitialSubscriptionPage(values: [], payloadHashes: [:], nextCursor: nil, succeeded: false)
        }
        return await context.perform {
            let request = NSFetchRequest<CDFeed>(entityName: "Feed")
            request.includesSubentities = false
            request.fetchLimit = Self.pendingChangeQueueChunkSize + 1
            request.relationshipKeyPathsForPrefetching = ["properties"]
            request.sortDescriptors = [NSSortDescriptor(key: "sourceURL_", ascending: true)]
            let basePredicate = NSPredicate(format: "subscribed == YES AND sourceURL_ != nil")
            request.predicate = cursor.map {
                NSCompoundPredicate(andPredicateWithSubpredicates: [
                    basePredicate,
                    NSPredicate(format: "sourceURL_ > %@", $0),
                ])
            } ?? basePredicate
            let rows: [CDFeed]
            do {
                rows = try context.fetch(request)
            } catch {
                Self.logSyncEvent("Initialer iCloud Abo-Plan konnte lokale Daten nicht lesen", metadata: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": (error as NSError).code,
                ])
                return InitialSubscriptionPage(values: [], payloadHashes: [:], nextCursor: nil, succeeded: false)
            }
            var feedURLs: [String] = []
            var payloadHashes: [String: String] = [:]
            for feed in rows.prefix(Self.pendingChangeQueueChunkSize) {
                guard let feedURL = feed.value(forKey: "sourceURL_") as? String else { continue }
                feedURLs.append(feedURL)
                // Record the payload hash at queue time so the change-gate matches right away.
                // Without it the first refresh after enabling subscription sync saw every feed
                // as "changed" and re-uploaded the whole list once more.
                payloadHashes[feedURL] = subscriptionPayloadHash(for: feed)
            }
            let nextCursor = rows.count > Self.pendingChangeQueueChunkSize ? feedURLs.last : nil
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
        if scheduleSyncAfterQueue {
            addPendingSaves([deviceRecordID(for: deviceID)], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
        }
        var queuedUserData = false

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
                addPendingSaves([listScrollPositionsRecordID()], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
                queuedUserData = true
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
                setSyncMetadata(plan.createdAt, forKey: Self.subscriptionListSettingsLocalModifiedDateKey)
                setSyncMetadata(Self.subscriptionListSettingsFingerprint(), forKey: Self.subscriptionListSettingsBaselineKey)
                addPendingSaves([subscriptionListSettingsRecordID()], pendingKeys: &pendingKeys, stampDeviceRecordForUserData: false)
                queuedUserData = true
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
            recordInitialUploadBatchesQueued(plan.pages)
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
        (episodesSyncEnabled && defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) != nil)
        || (subscriptionsSyncEnabled && defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) != nil)
    }

    func recordInitialUploadBatchesQueued(_ pages: [InitialUploadPlanPage]) {
        pendingInitialUploadBatches = pages.map { page in
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
        ])
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
        for index in pendingInitialUploadBatches.indices {
            pendingInitialUploadBatches[index].episodeRecordNames.subtract(resolvedNames)
            pendingInitialUploadBatches[index].subscriptionRecordNames.subtract(resolvedNames)
        }
        advanceConfirmedInitialUploadBatches()
    }

    func advanceConfirmedInitialUploadBatches() {
        var confirmedPageCount = 0
        while let batch = pendingInitialUploadBatches.first,
              batch.episodeRecordNames.isEmpty,
              batch.subscriptionRecordNames.isEmpty {
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
        guard confirmedPageCount > 0 else { return }
        logSyncEvent("Initiale iCloud-Seiten von CloudKit bestätigt", metadata: [
            "confirmedPageCount": confirmedPageCount,
            "remainingPageCount": pendingInitialUploadBatches.count,
            "episodeBackfillOffset": (defaults.object(forKey: Self.initialEpisodeBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
            "subscriptionBackfillOffset": (defaults.object(forKey: Self.initialSubscriptionBackfillOffsetKey) as? NSNumber)?.intValue ?? -1,
        ])
    }

    func discardInitialUploadCheckpoints(episodes: Bool, subscriptions: Bool) {
        guard episodes || subscriptions else { return }
        for index in pendingInitialUploadBatches.indices {
            if episodes {
                pendingInitialUploadBatches[index].episodeRecordNames.removeAll()
                pendingInitialUploadBatches[index].hasEpisodeBackfill = false
            }
            if subscriptions {
                pendingInitialUploadBatches[index].subscriptionRecordNames.removeAll()
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

    func applySyncEngineCallbackOutcome(for syncEngine: CKSyncEngine, generation: Int) {
        let outcome = syncEngineCallbackGate.takeInitialUploadOutcome(
            generation: generation,
            for: syncEngine
        )
        recordInitialUploadRecordNamesResolved(outcome.resolvedRecordNames)
        if outcome.localReadFailed {
            handleLocalUploadReadFailure(reason: "recordMaterialization")
        }
    }

    func sendChangesAndApplyCallbackOutcomes(_ syncEngine: CKSyncEngine,
                                             generation: Int) async throws {
        while true {
            do {
                try await syncEngine.sendChanges()
            } catch {
                applySyncEngineCallbackOutcome(for: syncEngine, generation: generation)
                throw error
            }
            applySyncEngineCallbackOutcome(for: syncEngine, generation: generation)
            guard generation == cloudAccountGeneration,
                  !hasUnresolvedSyncFailures,
                  !Task.isCancelled else {
                return
            }

            if requiresImmediateFinalDeviceRecordResend {
                requiresImmediateFinalDeviceRecordResend = false
                guard hasPendingFinalDeviceRecordUpdate, hasPendingSyncChanges else { return }
                continue
            }

            await queueNextInitialUploadPageDuringActiveSend()
            guard hasInitialUploadBackfillWork, hasPendingSyncChanges else {
                return
            }
        }
    }

    func updateInitialEpisodeBackfillCursor(nextOffset: Int?, nextCursor: String?) {
        if let nextOffset, let nextCursor {
            defaults.set(nextOffset, forKey: Self.initialEpisodeBackfillOffsetKey)
            defaults.set(nextCursor, forKey: Self.initialEpisodeBackfillCursorKey)
        } else {
            clearInitialEpisodeBackfillCursor()
        }
    }

    func updateInitialSubscriptionBackfillCursor(nextOffset: Int?, nextCursor: String?) {
        if let nextOffset, let nextCursor {
            defaults.set(nextOffset, forKey: Self.initialSubscriptionBackfillOffsetKey)
            defaults.set(nextCursor, forKey: Self.initialSubscriptionBackfillCursorKey)
        } else {
            clearInitialSubscriptionBackfillCursor()
        }
    }

    func resetInitialEpisodeBackfillCursor() {
        defaults.set(0, forKey: Self.initialEpisodeBackfillOffsetKey)
        defaults.removeObject(forKey: Self.initialEpisodeBackfillCursorKey)
    }

    func clearInitialEpisodeBackfillCursor() {
        defaults.removeObject(forKey: Self.initialEpisodeBackfillOffsetKey)
        defaults.removeObject(forKey: Self.initialEpisodeBackfillCursorKey)
    }

    func resetInitialSubscriptionBackfillCursor() {
        defaults.set(0, forKey: Self.initialSubscriptionBackfillOffsetKey)
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillCursorKey)
    }

    func clearInitialSubscriptionBackfillCursor() {
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillOffsetKey)
        defaults.removeObject(forKey: Self.initialSubscriptionBackfillCursorKey)
    }

    func clearInitialUploadCursors() {
        clearInitialEpisodeBackfillCursor()
        clearInitialSubscriptionBackfillCursor()
        defaults.removeObject(forKey: Self.initialSettingsBackfillPendingKey)
    }

    func resetInitialBackfillCursorsForEnabledOptions() {
        if episodesSyncEnabled {
            resetInitialEpisodeBackfillCursor()
        }
        if subscriptionsSyncEnabled {
            resetInitialSubscriptionBackfillCursor()
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
        if stampLastSyncDate {
            deviceRecordShouldStampSyncDate = true
            setSyncMetadata(true, forKey: Self.deviceRecordShouldStampSyncDateKey)
        }
        var pendingKeys = pendingRecordZoneChangeKeys()
        addPendingSaves([deviceRecordID(for: deviceID)],
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
